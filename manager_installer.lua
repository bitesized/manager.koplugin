--[[--
Unpacking a downloaded release over a plugin.

A plugin is swapped in by renaming: the release is unpacked next to the target
into a directory whose name does not end in ".koplugin" (so PluginLoader never
picks it up), the old directory is renamed aside, and the new one renamed into
place. Only once that succeeded is the old one deleted; on any failure it is
renamed back.

New code only takes effect after KOReader restarts; nothing is reloaded live.

@module koplugin.manager.installer
--]]--

local DataStorage = require("datastorage")
local PluginLoader = require("pluginloader")
local ffiUtil = require("ffi/util")
local lfs = require("libs/libkoreader-lfs")
local util = require("util")
local _ = require("gettext")
local T = ffiUtil.template

local Installer = {}

local function isDir(path)
    return lfs.attributes(path, "mode") == "directory"
end

local function isFile(path)
    return lfs.attributes(path, "mode") == "file"
end

local function listDir(path)
    local entries = {}
    for entry in lfs.dir(path) do
        if entry ~= "." and entry ~= ".." and entry ~= "__MACOSX" then
            table.insert(entries, entry)
        end
    end
    return entries
end

local function isLink(path)
    return lfs.symlinkattributes(path, "mode") == "link"
end

local function purge(path)
    -- purgeDir follows links, and would empty whatever a link points to.
    if isLink(path) then
        os.remove(path)
    elseif isDir(path) then
        ffiUtil.purgeDir(path)
    elseif lfs.attributes(path, "mode") then
        os.remove(path)
    end
end

-- Versions --

--- Splits "v1.2.3-beta.1" into { 1, 2, 3 } and "beta.1".
local function parseVersion(v)
    if type(v) ~= "string" then return end
    local core, pre = v:match("^[vV]?%s*(%d+[%d%.]*)%-?([%w%.%-]*)")
    if not core then return end
    local parts = {}
    for n in core:gmatch("%d+") do
        table.insert(parts, tonumber(n))
    end
    return parts, pre ~= "" and pre or nil
end

--- Compares two version strings.
-- @treturn int|nil -1, 0 or 1; nil when either does not look like a version
function Installer.compareVersions(a, b)
    local pa, prea = parseVersion(a)
    local pb, preb = parseVersion(b)
    if not pa or not pb then return end
    for i = 1, math.max(#pa, #pb) do
        local x, y = pa[i] or 0, pb[i] or 0
        if x ~= y then return x < y and -1 or 1 end
    end
    -- 1.0.0-beta comes before 1.0.0.
    if prea and not preb then return -1 end
    if preb and not prea then return 1 end
    if prea and preb and prea ~= preb then return prea < preb and -1 or 1 end
    return 0
end

--- Reads a plugin's `_meta.lua` straight from disk, so it reflects what is
-- installed now rather than what was loaded at startup.
function Installer.readMeta(plugin_root)
    local file = plugin_root .. "/_meta.lua"
    if not isFile(file) then return {} end
    local ok, meta = pcall(dofile, file)
    return ok and type(meta) == "table" and meta or {}
end

-- Installed plugins --

--- The plugins KOReader ships, up to v2026.07, for versions that do not
-- keep a list of their own.
local BUNDLED_PLUGINS = {
    "SSH", "archiveviewer", "autodim", "autostandby", "autosuspend", "autoturn",
    "autowarmth", "batterystat", "bookshortcuts", "calibre", "cloudstorage",
    "coverbrowser", "coverimage", "docsettingtweak", "exporter", "externalkeyboard",
    "gestures", "hello", "hotkeys", "httpinspector", "japanese", "keepalive",
    "kosync", "movetoarchive", "newsdownloader", "opds", "perceptionexpander",
    "profiles", "qrclipboard", "readtimer", "statistics", "systemstat", "terminal",
    "texteditor", "timesync", "vocabbuilder", "wallabag",
}

--- KOReader's own plugins live in the same directory as user plugins on most
-- devices. Newer versions list them in PluginLoader, as a local; read it off
-- the upvalue of the function that uses it.
local builtin_plugins = (function()
    local ok, list = pcall(function()
        local index = 1
        while true do
            local name, value = debug.getupvalue(PluginLoader.genPluginManagerSubItem, index)
            if not name then return nil end
            if name == "BUILTIN_PLUGINS" then return value end
            index = index + 1
        end
    end)
    if ok and type(list) == "table" then return list end
    list = {}
    for __, name in ipairs(BUNDLED_PLUGINS) do list[name] = true end
    return list
end)()

function Installer.isBuiltin(name)
    return builtin_plugins[name] == true
end

--- The directories PluginLoader looks in, the same way it works them out.
local function pluginDirs()
    local dirs = { "plugins" }
    local extra = G_reader_settings:readSetting("extra_plugin_paths")
    if type(extra) == "string" then extra = { extra } end
    if type(extra) ~= "table" then
        extra = { DataStorage:getDataDir() .. "/plugins" }
    end
    for __, dir in ipairs(extra) do
        if isDir(dir) and dir ~= "plugins" then table.insert(dirs, dir) end
    end
    return dirs
end

--- Plugins on disk, enabled or not, keyed by name (the directory name without
-- ".koplugin", which is what KOReader keys disabled plugins by).
-- This scans the disk rather than asking PluginLoader, whose list is fixed at
-- startup and so misses plugins installed since.
-- @treturn table name -> { name, path, fullname, enabled }
function Installer.installedPlugins()
    local disabled = G_reader_settings:readSetting("plugins_disabled")
    if type(disabled) ~= "table" then disabled = {} end
    local plugins = {}
    for __, dir in ipairs(pluginDirs()) do
        for __, entry in ipairs(listDir(dir)) do
            local path = dir .. "/" .. entry
            local name = entry:match("^(.+)%.koplugin$")
            -- The first one found wins, as it does in PluginLoader.
            if name and not plugins[name] and isDir(path) then
                local meta = Installer.readMeta(path)
                plugins[name] = {
                    name = name,
                    path = path,
                    fullname = type(meta.fullname) == "string" and meta.fullname or name,
                    enabled = not disabled[name],
                }
            end
        end
    end
    return plugins
end

-- Unpacking --

local function extractWithArchiver(archive, dest)
    local ok, Archiver = pcall(require, "ffi/archiver")
    if not ok then return nil, "no archiver" end
    local arc = Archiver.Reader:new()
    if not arc:open(archive) then
        return false, arc.err or _("Could not open the archive.")
    end
    local err
    for entry in arc:iterate() do
        if not arc:extractToPath(entry.path, dest .. "/" .. entry.path) then
            err = arc.err or entry.path
            break
        end
    end
    err = err or arc.err
    arc:close()
    if err then return false, err end
    return true
end

local function extract(archive, dest)
    local ok, err = extractWithArchiver(archive, dest)
    if ok ~= nil then return ok, err end
    -- KOReader older than libarchive support: fall back to the system unzip.
    if os.execute(string.format("unzip -qo %q -d %q", archive, dest)) == 0 then
        return true
    end
    return false, _("Could not unpack the archive.")
end

--- Finds the plugin inside an unpacked archive. Releases are zipped either
-- with the `name.koplugin` directory at the top, with the files at the top,
-- or (GitHub's source archives) inside an `owner-repo-sha` directory.
local function findPluginRoot(dir, preferred_dirname, depth)
    if isFile(dir .. "/main.lua") then return dir end
    if depth >= 3 then return end
    local found = {}
    for __, entry in ipairs(listDir(dir)) do
        local path = dir .. "/" .. entry
        if isDir(path) then
            if entry == preferred_dirname and isFile(path .. "/main.lua") then
                return path
            end
            local root = findPluginRoot(path, preferred_dirname, depth + 1)
            if root then table.insert(found, root) end
        end
    end
    if #found == 1 then return found[1] end
    for __, root in ipairs(found) do
        if root:match("%.koplugin$") then return root end
    end
end

--- Works out what directory name a release should be installed under, when
-- it is not replacing a plugin that is already there.
function Installer.dirnameFor(repo, unpacked_root)
    local base = unpacked_root:match("([^/]+)$")
    if base and base:match("%.koplugin$") then return base end
    local repo_name = repo:match("/(.+)$")
    if repo_name:match("%.koplugin$") then return repo_name end
    return repo_name .. ".koplugin"
end

--- Unpacks `archive` and installs it as `parent_dir/<dirname>`.
-- @string archive path to the downloaded zip
-- @string parent_dir directory the plugin goes in
-- @string dirname the ".koplugin" directory to replace, or nil for a new
-- install, whose name is worked out from the release and which must not exist
-- @string repo "owner/repo", used to work out a directory name
-- @treturn string|nil installed path
-- @treturn string error message
function Installer.install(archive, parent_dir, dirname, repo)
    local replacing = dirname ~= nil
    if replacing and isLink(parent_dir .. "/" .. dirname) then
        -- Usually a development checkout linked into place; leave it to git.
        os.remove(archive)
        return nil, T(_("%1 is a link to another folder, so it was not replaced."), parent_dir .. "/" .. dirname)
    end
    local staging = string.format("%s/.pluginmanager-staging-%d", parent_dir, os.time())
    purge(staging)
    local ok, err = util.makePath(staging)
    if not ok then return nil, err end

    ok, err = extract(archive, staging)
    os.remove(archive)
    if not ok then
        purge(staging)
        return nil, T(_("Could not unpack the release:\n%1"), err)
    end

    local root = findPluginRoot(staging, dirname, 0)
    if not root then
        purge(staging)
        return nil, _("The release does not contain a KOReader plugin (no main.lua found).")
    end
    dirname = dirname or Installer.dirnameFor(repo, root)

    local target = parent_dir .. "/" .. dirname
    if not replacing and isDir(target) then
        purge(staging)
        return nil, T(_("A plugin is already installed at %1. Link it to this repository and update it from its entry instead."), target)
    end
    local backup = parent_dir .. "/." .. dirname .. ".old"
    purge(backup)
    local had_old = isDir(target)
    if had_old then
        ok, err = os.rename(target, backup)
        if not ok then
            purge(staging)
            return nil, T(_("Could not move the old version aside:\n%1"), err)
        end
    end
    ok, err = os.rename(root, target)
    if not ok then
        if had_old then os.rename(backup, target) end
        purge(staging)
        return nil, T(_("Could not install the new version:\n%1"), err)
    end
    purge(staging)
    if had_old then purge(backup) end
    return target
end

return Installer
