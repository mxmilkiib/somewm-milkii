-- Monkey-patches menubar.icon_theme.find_icon_path to cache icon-theme path
-- lookups, eliminating repeated directory scans for SNI items that provide
-- IconName without IconPixmap (e.g. Quassel).
--
-- The surface-load half of the old patch is gone: systray_icon is declared
-- through wibox.clay, which already caches one surface per icon path, and
-- assigning a :draw method here would mark the widget self-drawing and drop
-- it from the tree entirely.

local icon_theme_mod = require("menubar.icon_theme")

-- Guard against double-patching on hot-reload
if icon_theme_mod._icon_cache_patched then return {} end
icon_theme_mod._icon_cache_patched = true

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

return {}
