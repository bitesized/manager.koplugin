--[[--
GitHub releases API and downloads.

Requests are made by hand with `redirect = false` and the redirects followed
here, because release assets are served from a different host than the API and
the `Authorization` header must not follow them there: the storage backend
rejects requests that carry a second set of credentials.

@module koplugin.manager.github
--]]--

local http = require("socket.http")
local json = require("json")
local logger = require("logger")
local socket = require("socket")
local socket_url = require("socket.url")
local socketutil = require("socketutil")
local _ = require("gettext")
local T = require("ffi/util").template

local API = "https://api.github.com"
local MAX_REDIRECTS = 5

local GitHub = {
    token = nil,
}

local REDIRECT_CODES = { [301] = true, [302] = true, [303] = true, [307] = true, [308] = true }

--- Accepts "owner/repo", a github.com URL, or either with a trailing ".git".
-- @treturn string|nil "owner/repo"
function GitHub.normalizeRepo(text)
    if type(text) ~= "string" then return end
    text = text:gsub("^%s+", ""):gsub("%s+$", "")
    text = text:gsub("^https?://", ""):gsub("^www%.", ""):gsub("^github%.com/", "")
    local owner, repo = text:match("^([%w%-_%.]+)/([%w%-_%.]+)")
    if not owner then return end
    repo = repo:gsub("%.git$", "")
    return owner .. "/" .. repo
end

local function copyHeaders(headers)
    local t = {}
    for k, v in pairs(headers) do t[k] = v end
    return t
end

--- Performs a GET, following redirects.
-- With `outfile`, the body is written there (truncated on every hop, so a
-- redirect's own body never ends up in the file); otherwise it is returned.
-- @treturn int|nil HTTP status code, nil on a network error
-- @treturn string body, or the error message
-- @treturn table response headers
local function get(url, headers, outfile)
    headers = copyHeaders(headers or {})
    headers["user-agent"] = "KOReader-PluginManager"
    for __ = 0, MAX_REDIRECTS do
        local body = {}
        local sink
        if outfile then
            local handle, err = io.open(outfile, "wb")
            if not handle then return nil, err end
            sink = socketutil.file_sink(handle)
            socketutil:set_timeout(socketutil.FILE_BLOCK_TIMEOUT, socketutil.FILE_TOTAL_TIMEOUT)
        else
            sink = socketutil.table_sink(body)
            socketutil:set_timeout(socketutil.LARGE_BLOCK_TIMEOUT, socketutil.LARGE_TOTAL_TIMEOUT)
        end
        local code, resp_headers, status = socket.skip(1, http.request{
            url = url,
            method = "GET",
            headers = headers,
            sink = sink,
            redirect = false,
        })
        socketutil:reset_timeout()
        if type(code) ~= "number" then
            logger.warn("PluginManager: request failed", url, code)
            return nil, tostring(code or status)
        end
        local location = resp_headers and resp_headers.location
        if REDIRECT_CODES[code] and location then
            local next_url = socket_url.absolute(url, location)
            if socket_url.parse(next_url).host ~= socket_url.parse(url).host then
                headers.authorization = nil
            end
            url = next_url
        else
            return code, table.concat(body), resp_headers or {}
        end
    end
    return nil, _("Too many redirects")
end

function GitHub:apiHeaders(accept)
    local headers = {
        accept = accept or "application/vnd.github+json",
        ["x-github-api-version"] = "2022-11-28",
    }
    if self.token and self.token ~= "" then
        headers.authorization = "Bearer " .. self.token
    end
    return headers
end

local function describeError(code, body, headers)
    if code == 404 then
        return _("Not found. Check the repository name, or set a token if it is private.")
    end
    if (code == 403 or code == 429) and headers["x-ratelimit-remaining"] == "0" then
        local reset = tonumber(headers["x-ratelimit-reset"])
        local wait = reset and math.max(1, math.ceil((reset - os.time()) / 60))
        return T(_("GitHub rate limit reached. Try again in %1 minutes, or set a token."), wait or "?")
    end
    if code == 401 then
        return _("GitHub rejected the token.")
    end
    local ok, data = pcall(json.decode, body)
    local message = ok and type(data) == "table" and type(data.message) == "string" and data.message
    return message or T(_("HTTP %1"), code)
end

--- GETs an API path and decodes the JSON body.
-- @treturn table|nil decoded body
-- @treturn string error message
function GitHub:api(path)
    local code, body, headers = get(API .. path, self:apiHeaders())
    if not code then
        return nil, T(_("Network error: %1"), body)
    end
    if code ~= 200 then
        return nil, describeError(code, body, headers), code
    end
    local ok, data = pcall(json.decode, body)
    if not ok or type(data) ~= "table" then
        return nil, _("Invalid response from GitHub.")
    end
    return data
end

--- Trims a release down to the fields we keep, so it can be cached in settings.
local function simplifyRelease(r, repo)
    local assets = {}
    for __, a in ipairs(type(r.assets) == "table" and r.assets or {}) do
        if type(a.name) == "string" then
            table.insert(assets, {
                name = a.name,
                size = a.size,
                api_url = a.url,
                download_url = a.browser_download_url,
            })
        end
    end
    return {
        repo = repo,
        tag = r.tag_name,
        name = type(r.name) == "string" and r.name ~= "" and r.name or r.tag_name,
        body = type(r.body) == "string" and r.body or "",
        published_at = type(r.published_at) == "string" and r.published_at or nil,
        prerelease = r.prerelease == true,
        zipball_url = r.zipball_url,
        assets = assets,
    }
end

--- Releases of a repository, newest first. Drafts are skipped.
function GitHub:releases(repo, limit)
    local data, err = self:api(string.format("/repos/%s/releases?per_page=%d", repo, limit or 30))
    if not data then return nil, err end
    local releases = {}
    for __, r in ipairs(data) do
        if not r.draft and type(r.tag_name) == "string" then
            table.insert(releases, simplifyRelease(r, repo))
        end
    end
    return releases
end

--- The release an update should go to: the latest stable one, or the newest
-- of all when pre-releases are wanted.
function GitHub:latestRelease(repo, include_prereleases)
    if include_prereleases then
        local releases, err = self:releases(repo, 10)
        if not releases then return nil, err end
        if not releases[1] then return nil, _("This repository has no releases.") end
        return releases[1]
    end
    local data, err, code = self:api(string.format("/repos/%s/releases/latest", repo))
    if not data then
        if code == 404 then
            -- Also what GitHub answers when there are only pre-releases; tell
            -- that apart from a wrong repository name.
            if self:api("/repos/" .. repo) then
                return nil, _("This repository has no stable releases.")
            end
        end
        return nil, err
    end
    return simplifyRelease(data, repo)
end

function GitHub:repoExists(repo)
    local data, err = self:api("/repos/" .. repo)
    return data ~= nil, err
end

--- Picks what to download from a release: the .zip asset matching `pattern`
-- if one is given, else one named after the plugin, else the only .zip, else
-- the source archive GitHub generates for the tag.
-- @treturn table { name, url, accept, size }
function GitHub.pickAsset(release, plugin_name, pattern)
    local zips = {}
    for __, a in ipairs(release.assets or {}) do
        if pattern and pattern ~= "" then
            local ok, matched = pcall(string.find, a.name, pattern)
            if ok and matched then return a end
        elseif a.name:lower():match("%.zip$") then
            table.insert(zips, a)
        end
    end
    if pattern and pattern ~= "" then return end
    if plugin_name then
        for __, a in ipairs(zips) do
            if a.name:lower():find(plugin_name:lower(), 1, true) then return a end
        end
    end
    if zips[1] then return zips[1] end
    if release.zipball_url then
        return { name = _("source code (zip)"), source = true, api_url = release.zipball_url }
    end
end

--- Downloads an asset picked by `pickAsset` to `outfile`.
-- With a token, assets are fetched through the API, which is what makes
-- private repositories work; without one, from the public download URL,
-- which does not count against the API rate limit.
function GitHub:download(asset, outfile)
    local url, headers
    if asset.source then
        url, headers = asset.api_url, self:apiHeaders()
    elseif self.token and self.token ~= "" and asset.api_url then
        url, headers = asset.api_url, self:apiHeaders("application/octet-stream")
    else
        url, headers = asset.download_url, {}
    end
    local code, body, resp_headers = get(url, headers, outfile)
    if not code then
        os.remove(outfile)
        return nil, T(_("Network error: %1"), body)
    end
    if code ~= 200 then
        os.remove(outfile)
        return nil, describeError(code, "", resp_headers)
    end
    return true
end

return GitHub
