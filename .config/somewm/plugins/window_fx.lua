-- plugins/window_fx.lua
-- Hyprland-style window effects on somewm's declarative animation model:
--   * open fade: clients enter with "fade" over open_duration
--   * close fade: clients exit with "fade" over close_duration; the
--     compositor holds the last frame natively, so the old ghost-wibox
--     cover is gone
--   * focus dim: unfocused clients drop to dim_opacity instantly (opacity
--     is not an animated property); border colour eases over dim_duration
--     through the focus transition
--   * floating shadows: native compositor shadow on floating clients
--
-- No awesome.start_animation any more: effects are declared as words on
-- appear/disappear/tag and durations come from beautiful.animation_*.

local beautiful = require("beautiful")
local guarded = require("error_guard")
require("somewm.animation")

local M = {
    open_duration = 0.15,
    close_duration = 0.22,
    tag_duration = 0.45,
    dim_opacity = 0.94,
    dim_duration = 0.10,
    shadow = { enabled = true, radius = 24, offset_x = 0, offset_y = 6, opacity = 0.5 },
}

-- guard against duplicate signal connections on hot-reload (P11)
local signals_connected = false

local function apply_theme()
    beautiful.animation_appear = beautiful.animation_appear or "fade"
    beautiful.animation_disappear = beautiful.animation_disappear or "fade"
    beautiful.animation_appear_duration = M.open_duration
    beautiful.animation_disappear_duration = M.close_duration
    beautiful.animation_tag = "slide_right"
    beautiful.animation_tag_duration = M.tag_duration
    beautiful.animation_focus_duration = M.dim_duration
end


-- // MARK -- focus dim

local function dim(c)
    if not c.valid then return end
    c.border_color = beautiful.border_normal
    if c.fullscreen then return end  -- don't dim videos and games
    c.opacity = M.dim_opacity
end

local function undim(c)
    if not c.valid then return end
    c.border_color = beautiful.border_focus
    c.opacity = 1
end

if not signals_connected then
    client.connect_signal("focus", guarded(undim))
    client.connect_signal("unfocus", guarded(dim))
end


-- // MARK -- floating shadows

local function apply_shadow(c)
    if not c.valid then return end
    if c.floating and not c.fullscreen and not c.maximized then
        c.shadow = M.shadow
    else
        c.shadow = nil
    end
end

if not signals_connected then
    client.connect_signal("request::manage", guarded(apply_shadow))
    client.connect_signal("property::floating", guarded(apply_shadow))
    client.connect_signal("property::fullscreen", guarded(apply_shadow))
    client.connect_signal("property::maximized", guarded(apply_shadow))
    signals_connected = true
end

apply_theme()

return M
