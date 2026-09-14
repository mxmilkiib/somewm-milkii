-- Monkey-patches wibox.widget.systray_icon to cache icon surface loads and
-- icon-theme path lookups, eliminating disk I/O on every redraw.
--
-- SNI items that provide IconName without IconPixmap (e.g. Quassel) trigger
-- a full icon-theme directory scan + PNG decode on every widget::redraw_needed
-- (including hover), blocking the compositor main thread and causing display
-- stutter. Items with pixmaps (KeePassXC, qBittorrent) are unaffected because
-- the C draw_icon path succeeds without filesystem access.

local surface = require("gears.surface")
local icon_theme_mod = require("menubar.icon_theme")
local systray_icon_mod = require("wibox.widget.systray_icon")

-- Guard against double-patching on hot-reload
if systray_icon_mod._icon_cache_patched then return {} end
systray_icon_mod._icon_cache_patched = true

-- Cache icon-theme path lookups (theme:name:size -> path|nil).
-- The same icon name + size + theme always resolves to the same path
-- during a WM session, so this is safe to cache permanently.
local path_cache = {}
local original_find_icon_path = icon_theme_mod.find_icon_path
icon_theme_mod.find_icon_path = function(self, icon_name, icon_size)
    local key = (self.icon_theme_name or "hicolor") .. ":"
        .. (icon_name or "") .. ":" .. (icon_size or 16)
    if path_cache[key] ~= nil then
        return path_cache[key]
    end
    local path = original_find_icon_path(self, icon_name, icon_size)
    path_cache[key] = path
    return path
end

-- Cache decoded cairo surfaces (path -> surface) during systray icon draws.
-- The surface is used read-only (set_source_surface + paint), so caching
-- is safe. The in_systray_draw flag ensures the cache only affects systray
-- icon draws, not other surface.load_silently callers.
local surface_cache = {}
local original_load_silently = surface.load_silently
local in_systray_draw = false

surface.load_silently = function(path, ...)
    if in_systray_draw and surface_cache[path] then
        return surface_cache[path]
    end
    local s = original_load_silently(path, ...)
    if in_systray_draw and s then
        surface_cache[path] = s
    end
    return s
end

-- Wrap draw to enable surface caching only during systray icon draws
local original_draw = systray_icon_mod.draw
systray_icon_mod.draw = function(self, context, cr, width, height)
    in_systray_draw = true
    local ok, err = pcall(original_draw, self, context, cr, width, height)
    in_systray_draw = false
    if not ok then error(err) end
end

return {}
