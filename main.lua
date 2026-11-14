--[[--
Plugin manager: links installed plugins to GitHub repositories and installs or
updates them from those repositories' releases.

Each link is keyed by the plugin's name (its directory name without
".koplugin"). The latest release seen for each is cached, so the menu can show
which plugins have updates without going online.

Updated files are only picked up when KOReader restarts, so every install ends
by asking for a restart. Swapping plugins into a running KOReader is not
attempted: plugins patch KOReader's modules when they load, and those patches
cannot be undone safely.

@module koplugin.manager
--]]--

local ButtonDialog = require("ui/widget/buttondialog")
local ConfirmBox = require("ui/widget/confirmbox")
local DataStorage = require("datastorage")
local GitHub = require("manager_github")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local Installer = require("manager_installer")
local LuaSettings = require("luasettings")
local Menu = require("ui/widget/menu")
local MultiInputDialog = require("ui/widget/multiinputdialog")
local NetworkMgr = require("ui/network/manager")
local TextViewer = require("ui/widget/textviewer")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local util = require("util")
local _ = require("gettext")
local T = require("ffi/util").template

local SETTINGS_FILE = DataStorage:getSettingsDir() .. "/pluginmanager.lua"
local DOWNLOAD_DIR = DataStorage:getDataDir() .. "/cache/pluginmanager"

-- Shared by the file manager's and the reader's instances, so a link made in
-- one is not overwritten by the other's stale copy.
local settings

local function getSettings()
    if not settings then
        settings = LuaSettings:open(SETTINGS_FILE)
    end
    return settings
end

local function getLinks()
    return getSettings():readSetting("links", {})
end

local function getLatest()
    return getSettings():readSetting("latest", {})
end

local function saveSettings()
    getSettings():flush()
end

local function showInfo(text, timeout)
    UIManager:show(InfoMessage:new{ text = text, timeout = timeout })
end

--- Shows a message and paints it straight away, ahead of a blocking network call.
local function showProgress(text)
    local widget = InfoMessage:new{ text = text, dismissable = false }
    UIManager:show(widget)
    UIManager:forceRePaint()
    return widget
end

local function formatDate(iso)
    return type(iso) == "string" and iso:match("^(%d+%-%d+%-%d+)") or ""
end

local PluginManager = WidgetContainer:extend{
    name = "manager",
    is_doc_only = false,
    settings_file = SETTINGS_FILE,
}

function PluginManager:init()
    GitHub.token = getSettings():readSetting("token")
    self.ui.menu:registerToMainMenu(self)
end

-- State --

--- The version a plugin is at. When the manager installed it, that is the
-- release tag, as long as `_meta.lua` still says what it said then; if the
-- plugin was replaced by hand since, it is whatever `_meta.lua` says now.
function PluginManager:installedVersion(name, plugin)
    plugin = plugin or Installer.installedPlugins()[name]
    if not plugin then return end
    local meta_version = Installer.readMeta(plugin.path).version
    local link = getLinks()[name]
    if link and link.installed_tag and link.installed_meta_version == meta_version then
        return link.installed_tag
    end
    return meta_version
end

--- Whether the cached latest release is newer than what is installed.
-- @treturn string|nil "install", "update", "current", or nil when unknown
function PluginManager:status(name, plugin)
    local latest = getLatest()[name]
    if not latest then return end
    plugin = plugin or Installer.installedPlugins()[name]
    if not plugin then return "install" end
    local current = self:installedVersion(name, plugin)
    if current == latest.tag then return "current" end
    local cmp = Installer.compareVersions(current, latest.tag)
    if cmp == nil or cmp < 0 then return "update" end
    return "current"
end

--- Fetches and caches the release a plugin would update to.
function PluginManager:fetchLatest(name)
    local link = getLinks()[name]
    local release, err = GitHub:latestRelease(link.repo, link.prereleases)
    if not release then return nil, err end
    release.checked_at = os.time()
    getLatest()[name] = release
    saveSettings()
    return release
end

-- Installing --

--- Downloads and installs a release. Blocking; call it with the network up.
-- @string name the plugin to replace, or nil for a new install
-- @treturn string|nil the installed plugin's name
-- @treturn string error message
function PluginManager:installRelease(name, release)
    local link = name and getLinks()[name]
    local plugin = name and Installer.installedPlugins()[name]
    local asset = GitHub.pickAsset(release, name, link and link.asset)
    if not asset then
        return nil, _("No file in this release matches the release file pattern.")
    end

    local ok, err = util.makePath(DOWNLOAD_DIR)
    if not ok then return nil, err end
    local archive = DOWNLOAD_DIR .. "/download.zip"
    ok, err = GitHub:download(asset, archive)
    if not ok then return nil, err end

    local parent_dir, dirname
    if plugin then
        parent_dir, dirname = plugin.path:match("^(.*)/([^/]+)$")
    else
        -- New plugins go next to this one.
        parent_dir = self.path:match("^(.*)/[^/]+$")
    end
    local target
    target, err = Installer.install(archive, parent_dir, dirname, release.repo)
    if not target then return nil, err end

    local installed_name = target:match("([^/]+)%.koplugin$") or target:match("([^/]+)$")
    local links = getLinks()
    links[installed_name] = links[installed_name] or { repo = release.repo }
    links[installed_name].installed_tag = release.tag
    links[installed_name].installed_meta_version = Installer.readMeta(target).version
    saveSettings()
    return installed_name
end

function PluginManager:askForRestart(text)
    UIManager:askForRestart(text .. "\n\n" .. _("KOReader needs to restart to use it."))
end

--- Installs one release with progress and error messages, then asks to restart.
function PluginManager:installWithUI(name, release, label, touchmenu_instance)
    NetworkMgr:runWhenOnline(function()
        local progress = showProgress(T(_("Installing %1 %2…"), label, release.tag))
        local installed, err = self:installRelease(name, release)
        UIManager:close(progress)
        if not installed then
            showInfo(T(_("Could not install %1:\n\n%2"), label, err))
            return
        end
        self:refreshMenu(touchmenu_instance)
        if not name then
            local plugin = Installer.installedPlugins()[installed]
            label = plugin and plugin.fullname or installed
        end
        self:askForRestart(T(_("%1 %2 installed."), label, release.tag))
    end)
end

function PluginManager:updateAll(names)
    NetworkMgr:runWhenOnline(function()
        local done, failed = {}, {}
        for i, name in ipairs(names) do
            local release = getLatest()[name]
            local progress = showProgress(T(_("Updating %1 (%2/%3)…"), name, i, #names))
            local installed, err = self:installRelease(name, release)
            UIManager:close(progress)
            if installed then
                table.insert(done, T("%1 %2", name, release.tag))
            else
                table.insert(failed, T("%1: %2", name, err))
            end
        end
        local text = ""
        if #done > 0 then
            text = _("Updated:") .. "\n" .. table.concat(done, "\n")
        end
        if #failed > 0 then
            text = text .. (text ~= "" and "\n\n" or "") .. _("Failed:") .. "\n" .. table.concat(failed, "\n")
        end
        if #done > 0 then
            self:askForRestart(text)
        else
            showInfo(text)
        end
    end)
end

-- Checking --

function PluginManager:checkAll(touchmenu_instance)
    local names = {}
    for name in pairs(getLinks()) do table.insert(names, name) end
    if #names == 0 then
        showInfo(_("No plugins are linked to a repository yet."))
        return
    end
    table.sort(names)
    NetworkMgr:runWhenOnline(function()
        local progress = showProgress(_("Checking for updates…"))
        local errors = {}
        for __, name in ipairs(names) do
            local ok, err = self:fetchLatest(name)
            if not ok then table.insert(errors, T("%1: %2", name, err)) end
        end
        UIManager:close(progress)
        if touchmenu_instance then touchmenu_instance:updateItems() end

        local plugins = Installer.installedPlugins()
        local updates, lines = {}, {}
        for __, name in ipairs(names) do
            local status = self:status(name, plugins[name])
            if status == "update" then
                table.insert(updates, name)
                table.insert(lines, T("%1: %2 → %3", name,
                    self:installedVersion(name, plugins[name]) or "?", getLatest()[name].tag))
            end
        end
        local error_text = #errors > 0
            and "\n\n" .. _("Could not check:") .. "\n" .. table.concat(errors, "\n") or ""
        if #updates == 0 then
            showInfo(_("All linked plugins are up to date.") .. error_text)
            return
        end
        UIManager:show(ConfirmBox:new{
            text = _("Updates available:") .. "\n" .. table.concat(lines, "\n") .. error_text,
            ok_text = _("Update all"),
            ok_callback = function() self:updateAll(updates) end,
        })
    end)
end

-- Linking --

function PluginManager:defaultRepoFor(name)
    local owner = getSettings():readSetting("default_owner")
    if owner and owner ~= "" then
        return owner .. "/" .. name .. ".koplugin"
    end
    return ""
end

function PluginManager:editLink(name, on_done)
    local link = getLinks()[name]
    local dialog
    dialog = InputDialog:new{
        title = T(_("GitHub repository for %1"), name),
        input = link and link.repo or self:defaultRepoFor(name),
        input_hint = "owner/repository",
        description = _("The repository whose releases this plugin is installed from. A github.com link works too."),
        buttons = { {
            {
                text = _("Cancel"),
                id = "close",
                callback = function() UIManager:close(dialog) end,
            },
            {
                text = _("Save"),
                is_enter_default = true,
                callback = function()
                    local repo = GitHub.normalizeRepo(dialog:getInputText())
                    if not repo then
                        showInfo(_("Enter the repository as owner/repository."))
                        return
                    end
                    UIManager:close(dialog)
                    local links = getLinks()
                    if links[name] and links[name].repo ~= repo then
                        -- The recorded tag belonged to the old repository.
                        links[name].installed_tag = nil
                        links[name].installed_meta_version = nil
                    end
                    links[name] = links[name] or {}
                    links[name].repo = repo
                    getLatest()[name] = nil
                    saveSettings()
                    if on_done then on_done() end
                end,
            },
        } },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function PluginManager:editAssetPattern(name, on_done)
    local link = getLinks()[name]
    local dialog
    dialog = InputDialog:new{
        title = _("Release file"),
        input = link.asset or "",
        input_hint = "%.zip$",
        description = _("A Lua pattern matched against the names of a release's files. Leave empty to pick the .zip named after the plugin, or the only .zip, or else the source code archive."),
        buttons = { {
            {
                text = _("Cancel"),
                id = "close",
                callback = function() UIManager:close(dialog) end,
            },
            {
                text = _("Save"),
                is_enter_default = true,
                callback = function()
                    local pattern = dialog:getInputText()
                    if pattern ~= "" and not pcall(string.find, "", pattern) then
                        showInfo(_("That is not a valid Lua pattern."))
                        return
                    end
                    UIManager:close(dialog)
                    link.asset = pattern ~= "" and pattern or nil
                    saveSettings()
                    if on_done then on_done() end
                end,
            },
        } },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

--- Links every unlinked plugin that has an `owner/<name>.koplugin` repository.
function PluginManager:linkFromOwner(touchmenu_instance)
    local dialog
    dialog = InputDialog:new{
        title = _("Link plugins from a GitHub account"),
        input = getSettings():readSetting("default_owner") or "",
        input_hint = _("GitHub user or organisation"),
        description = _("Each plugin that is not linked yet is linked to <account>/<plugin>.koplugin, if that repository exists."),
        buttons = { {
            {
                text = _("Cancel"),
                id = "close",
                callback = function() UIManager:close(dialog) end,
            },
            {
                text = _("Link"),
                is_enter_default = true,
                callback = function()
                    local owner = dialog:getInputText():gsub("^%s+", ""):gsub("%s+$", "")
                    if owner == "" then return end
                    UIManager:close(dialog)
                    getSettings():saveSetting("default_owner", owner)
                    saveSettings()
                    NetworkMgr:runWhenOnline(function()
                        self:doLinkFromOwner(owner, touchmenu_instance)
                    end)
                end,
            },
        } },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function PluginManager:doLinkFromOwner(owner, touchmenu_instance)
    local links = getLinks()
    local candidates = {}
    for name in pairs(Installer.installedPlugins()) do
        if not links[name] and not Installer.isBuiltin(name) then
            table.insert(candidates, name)
        end
    end
    table.sort(candidates)
    if #candidates == 0 then
        showInfo(_("Every plugin is already linked."))
        return
    end
    local progress = showProgress(T(_("Looking for %1 repositories…"), #candidates))
    local linked, missing = {}, {}
    for __, name in ipairs(candidates) do
        local repo = owner .. "/" .. name .. ".koplugin"
        local exists, err = GitHub:repoExists(repo)
        if exists then
            links[name] = { repo = repo }
            table.insert(linked, name)
        else
            table.insert(missing, name)
            if err and not err:find(_("Not found"), 1, true) then
                -- A real failure (rate limit, network), not just no such repo.
                UIManager:close(progress)
                saveSettings()
                showInfo(T(_("Stopped looking:\n\n%1"), err))
                return
            end
        end
    end
    saveSettings()
    UIManager:close(progress)
    self:refreshMenu(touchmenu_instance)
    local text = #linked > 0 and (_("Linked:") .. "\n" .. table.concat(linked, "\n"))
        or _("No matching repositories found.")
    if #linked > 0 and #missing > 0 then
        text = text .. "\n\n" .. _("No repository for:") .. "\n" .. table.concat(missing, "\n")
    end
    showInfo(text)
end

-- Installing new plugins --

local function trim(text)
    return (text:gsub("^%s+", ""):gsub("%s+$", ""))
end

function PluginManager:installFromGitHub(touchmenu_instance)
    local dialog
    dialog = MultiInputDialog:new{
        title = _("Install plugin from GitHub"),
        fields = {
            {
                description = _("GitHub username"),
                text = getSettings():readSetting("default_owner") or "",
                hint = _("user or organisation"),
            },
            {
                description = _("Repository name"),
                text = "",
                hint = "example.koplugin",
            },
        },
        buttons = { {
            {
                text = _("Cancel"),
                id = "close",
                callback = function() UIManager:close(dialog) end,
            },
            {
                text = _("Find"),
                is_enter_default = true,
                callback = function()
                    local fields = dialog:getFields()
                    local owner, name = trim(fields[1]), trim(fields[2])
                    -- A pasted owner/repository or github.com link works in either field.
                    local repo
                    if name:find("/") then
                        repo = GitHub.normalizeRepo(name)
                    elseif owner:find("/") then
                        repo = GitHub.normalizeRepo(owner)
                    elseif owner ~= "" and name ~= "" then
                        repo = GitHub.normalizeRepo(owner .. "/" .. name)
                    end
                    if not repo then
                        showInfo(_("Enter a GitHub username and a repository name."))
                        return
                    end
                    UIManager:close(dialog)
                    getSettings():saveSetting("default_owner", repo:match("^([^/]+)"))
                    saveSettings()
                    NetworkMgr:runWhenOnline(function() self:offerInstall(repo, touchmenu_instance) end)
                end,
            },
        } },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

--- The release a new install should use: the latest stable one, or the
-- latest pre-release for repositories that only publish those.
local function findRelease(repo)
    local release, err = GitHub:latestRelease(repo, false)
    if release then return release end
    return GitHub:latestRelease(repo, true) or nil, err
end

function PluginManager:offerInstall(repo, touchmenu_instance)
    -- Already installed under the repository's name: link it and treat it as an update.
    local guess = (repo:match("/(.+)$"):gsub("%.koplugin$", ""))
    if Installer.installedPlugins()[guess] then
        local links = getLinks()
        links[guess] = links[guess] or {}
        links[guess].repo = repo
        saveSettings()
        self:refreshMenu(touchmenu_instance)
        showInfo(T(_("%1 is already installed. It is now linked to %2; update it from its entry in the plugin list."), guess, repo))
        return
    end

    local progress = showProgress(T(_("Looking up %1…"), repo))
    local release, err = findRelease(repo)
    if not release and not repo:match("%.koplugin$") then
        -- Plugin repositories are usually named after their directory.
        local alt_release = findRelease(repo .. ".koplugin")
        if alt_release then
            repo, release = repo .. ".koplugin", alt_release
        end
    end
    UIManager:close(progress)
    if not release then
        showInfo(T(_("Could not find a release of %1:\n\n%2"), repo, err))
        return
    end
    UIManager:show(ConfirmBox:new{
        text = T(_("Install %1 %2%3, published %4?"), repo, release.tag,
            release.prerelease and " " .. _("(pre-release)") or "", formatDate(release.published_at)),
        ok_text = _("Install"),
        ok_callback = function() self:installWithUI(nil, release, repo, touchmenu_instance) end,
    })
end

-- Per-plugin dialog --

function PluginManager:showReleases(name, label, touchmenu_instance)
    local link = getLinks()[name]
    NetworkMgr:runWhenOnline(function()
        local progress = showProgress(_("Fetching releases…"))
        local releases, err = GitHub:releases(link.repo)
        UIManager:close(progress)
        if not releases then
            showInfo(T(_("Could not fetch releases:\n\n%1"), err))
            return
        end
        if #releases == 0 then
            showInfo(_("This repository has no releases."))
            return
        end
        local current = self:installedVersion(name)
        local menu
        local items = {}
        for __, release in ipairs(releases) do
            local tags = {}
            if release.tag == current then table.insert(tags, _("installed")) end
            if release.prerelease then table.insert(tags, _("pre-release")) end
            table.insert(items, {
                text = release.tag .. (#tags > 0 and "  (" .. table.concat(tags, ", ") .. ")" or ""),
                mandatory = formatDate(release.published_at),
                callback = function()
                    self:showReleaseDialog(name, label, release, touchmenu_instance)
                end,
            })
        end
        menu = Menu:new{
            title = T(_("Releases of %1"), link.repo),
            item_table = items,
            covers_fullscreen = true,
            is_borderless = true,
            is_popout = false,
        }
        menu.close_callback = function() UIManager:close(menu) end
        UIManager:show(menu)
    end)
end

function PluginManager:showNotes(release)
    UIManager:show(TextViewer:new{
        title = T("%1 %2", release.repo, release.tag),
        text = release.body ~= "" and release.body or _("No release notes."),
    })
end

function PluginManager:showReleaseDialog(name, label, release, touchmenu_instance)
    local dialog
    dialog = ButtonDialog:new{
        title = T(_("%1 %2\nPublished %3"), label, release.tag, formatDate(release.published_at)),
        title_align = "center",
        buttons = {
            { {
                text = _("Release notes"),
                callback = function() self:showNotes(release) end,
            } },
            { {
                text = T(_("Install %1"), release.tag),
                callback = function()
                    UIManager:close(dialog)
                    self:installWithUI(name, release, label, touchmenu_instance)
                end,
            } },
        },
    }
    UIManager:show(dialog)
end

function PluginManager:showPluginDialog(name, touchmenu_instance)
    local plugin = Installer.installedPlugins()[name]
    local link = getLinks()[name]
    local latest = getLatest()[name]
    local label = plugin and plugin.fullname or name
    local reopen = function()
        self:refreshMenu(touchmenu_instance)
        self:showPluginDialog(name, touchmenu_instance)
    end

    local lines = { label }
    table.insert(lines, link and link.repo or _("Not linked to a repository"))
    table.insert(lines, T(_("Installed: %1"), plugin and (self:installedVersion(name, plugin) or _("unknown version")) or _("no")))
    if latest then
        table.insert(lines, T(_("Latest: %1 (%2)"), latest.tag, formatDate(latest.published_at)))
    end

    local dialog
    local function close() UIManager:close(dialog) end
    local buttons = {}
    if link then
        local status = self:status(name, plugin)
        local install_text = status == "install" and _("Install")
            or status == "update" and T(_("Update to %1"), latest.tag)
            or _("Reinstall")
        table.insert(buttons, {
            {
                text = _("Check for update"),
                callback = function()
                    close()
                    NetworkMgr:runWhenOnline(function()
                        local progress = showProgress(_("Checking for updates…"))
                        local ok, err = self:fetchLatest(name)
                        UIManager:close(progress)
                        if not ok then
                            showInfo(T(_("Could not check for updates:\n\n%1"), err))
                        end
                        reopen()
                    end)
                end,
            },
            {
                text = install_text,
                enabled = latest ~= nil,
                callback = function()
                    close()
                    self:installWithUI(name, latest, label, touchmenu_instance)
                end,
            },
        })
        table.insert(buttons, {
            {
                text = _("Other versions"),
                callback = function()
                    close()
                    self:showReleases(name, label, touchmenu_instance)
                end,
            },
            {
                text = _("Release notes"),
                enabled = latest ~= nil,
                callback = function() self:showNotes(latest) end,
            },
        })
        table.insert(buttons, {
            {
                text = link.prereleases and _("Pre-releases: on") or _("Pre-releases: off"),
                callback = function()
                    close()
                    link.prereleases = not link.prereleases or nil
                    getLatest()[name] = nil
                    saveSettings()
                    reopen()
                end,
            },
            {
                text = _("Release file"),
                callback = function()
                    close()
                    self:editAssetPattern(name, reopen)
                end,
            },
        })
        table.insert(buttons, {
            {
                text = _("Change repository"),
                callback = function()
                    close()
                    self:editLink(name, reopen)
                end,
            },
            {
                text = _("Unlink"),
                callback = function()
                    close()
                    getLinks()[name] = nil
                    getLatest()[name] = nil
                    saveSettings()
                    self:refreshMenu(touchmenu_instance)
                end,
            },
        })
    else
        table.insert(buttons, { {
            text = _("Link to GitHub repository"),
            callback = function()
                close()
                self:editLink(name, reopen)
            end,
        } })
    end

    dialog = ButtonDialog:new{
        title = table.concat(lines, "\n"),
        title_align = "center",
        buttons = buttons,
    }
    UIManager:show(dialog)
end

-- Menu --

function PluginManager:pluginMenuText(name, plugin)
    local label = plugin and plugin.fullname or name
    if not getLinks()[name] then
        return label
    end
    local status = self:status(name, plugin)
    if status == "update" then
        return T(_("%1 (%2 → %3)"), label, self:installedVersion(name, plugin) or "?", getLatest()[name].tag)
    elseif status == "install" then
        return T(_("%1 (not installed)"), label)
    end
    local version = self:installedVersion(name, plugin)
    return version and T("%1 (%2)", label, version) or label
end

function PluginManager:buildMenu()
    local items = {
        {
            text = _("Check for updates"),
            keep_menu_open = true,
            callback = function(touchmenu_instance) self:checkAll(touchmenu_instance) end,
        },
        {
            text = _("Install plugin from GitHub…"),
            keep_menu_open = true,
            callback = function(touchmenu_instance) self:installFromGitHub(touchmenu_instance) end,
        },
        {
            text = _("Link plugins from a GitHub account…"),
            keep_menu_open = true,
            callback = function(touchmenu_instance) self:linkFromOwner(touchmenu_instance) end,
        },
        {
            text = _("GitHub token"),
            keep_menu_open = true,
            callback = function() self:editToken() end,
            separator = true,
        },
    }

    local plugins = Installer.installedPlugins()
    local names = {}
    for name in pairs(plugins) do
        if not Installer.isBuiltin(name) then table.insert(names, name) end
    end
    -- Linked plugins that were deleted, so they can be reinstalled.
    for name in pairs(getLinks()) do
        if not plugins[name] then table.insert(names, name) end
    end
    table.sort(names, function(a, b)
        local la = plugins[a] and plugins[a].fullname or a
        local lb = plugins[b] and plugins[b].fullname or b
        return la:lower() < lb:lower()
    end)
    for __, name in ipairs(names) do
        table.insert(items, {
            text_func = function() return self:pluginMenuText(name, plugins[name]) end,
            keep_menu_open = true,
            callback = function(touchmenu_instance) self:showPluginDialog(name, touchmenu_instance) end,
        })
    end
    return items
end

--- Rebuilds the open menu page in place, after links have changed.
function PluginManager:refreshMenu(touchmenu_instance)
    if not touchmenu_instance or not touchmenu_instance.item_table then return end
    local item_table = touchmenu_instance.item_table
    if not item_table.plugin_manager then
        touchmenu_instance:updateItems()
        return
    end
    for i = #item_table, 1, -1 do item_table[i] = nil end
    for i, item in ipairs(self:buildMenu()) do item_table[i] = item end
    touchmenu_instance:updateItems()
end

function PluginManager:editToken()
    local dialog
    dialog = InputDialog:new{
        title = _("GitHub token"),
        input = getSettings():readSetting("token") or "",
        text_type = "password",
        description = _("Optional. Needed for private repositories, and raises GitHub's limit of 60 requests an hour. A fine-grained token with read access to the repositories' contents is enough."),
        buttons = { {
            {
                text = _("Cancel"),
                id = "close",
                callback = function() UIManager:close(dialog) end,
            },
            {
                text = _("Save"),
                is_enter_default = true,
                callback = function()
                    local token = dialog:getInputText():gsub("%s", "")
                    UIManager:close(dialog)
                    if token == "" then
                        getSettings():delSetting("token")
                        GitHub.token = nil
                    else
                        getSettings():saveSetting("token", token)
                        GitHub.token = token
                    end
                    saveSettings()
                end,
            },
        } },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function PluginManager:addToMainMenu(menu_items)
    menu_items.plugin_manager = {
        text = _("Plugin manager"),
        sorting_hint = "tools",
        sub_item_table_func = function()
            local items = self:buildMenu()
            -- Marks the table so refreshMenu knows it is ours.
            items.plugin_manager = true
            return items
        end,
    }
end

return PluginManager
