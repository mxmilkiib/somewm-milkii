-- rc_xephyr.lua: wrapper to run user's rc.lua and force a preset for testing
local home = os.getenv("HOME") or "/home/milk"

dofile(home .. "/.config/awesome/rc.lua")

-- layout icons should now work properly with theme-relative paths
-- but add a fallback for Xephyr testing if needed
local beautiful = require("beautiful")
if not beautiful.layout_tile or beautiful.layout_tile:match("^~") then
    local icons_base = home .. "/.config/awesome/milktheme/icons/layouts/"
    beautiful.layout_tile = icons_base .. "tile_alt.svg"
    beautiful.layout_floating = icons_base .. "floating_alt.svg"
    beautiful.layout_max = icons_base .. "max_alt.svg"
    beautiful.layout_magnifier = icons_base .. "magnifier_alt.svg"
    beautiful.layout_tiletop = icons_base .. "tiletop_alt.svg"
    beautiful.layout_tilebottom = icons_base .. "tilebottom_alt.svg"
    beautiful.layout_tileleft = icons_base .. "tileleft_alt.svg"
    print("Xephyr: Applied fallback layout icon paths")
else
    print("Xephyr: Using theme-relative layout icon paths")
end

-- after the main config initializes, set shimmer preset explicitly
local ok, shimmer = pcall(require, "plugins.shimmer")
if ok and shimmer and shimmer.set_mode then
  shimmer.set_mode("bright_gold")  -- test new max_animated_chars feature
end
