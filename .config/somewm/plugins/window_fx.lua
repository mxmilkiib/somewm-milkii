-- plugins/window_fx.lua
-- Hyprland-style window effects on somewm's native animation clock:
--   * open fade: new clients fade in over open_duration
--   * close animation: a ghost wibox showing the client's last frame
--     (c.content is still readable during request::unmanage) covers the
--     vacated tile during reflow, then fades out
--   * focus dim: unfocused clients drop to dim_opacity, animated
--   * floating shadows: native compositor shadow on floating clients
--
-- All animations run through awesome.start_animation (C frame clock,
-- vsync-paced), not Lua timers.

local gears = require("gears")
local wibox = require("wibox")
local beautiful = require("beautiful")
local guarded = require("error_guard")

local M = {
    open_duration = 0.15,
    close_duration = 0.22,
    close_fade_delay = 0.68, -- keep the old frame opaque while the layout closes its gap
    dim_opacity = 0.90,
    dim_duration = 0.10,
    shadow = { enabled = true, radius = 24, offset_x = 0, offset_y = 6, opacity = 0.5 },
}

-- per-client running animation handles, weak keys so clients can be collected
local anims = setmetatable({}, { __mode = "k" })

local function cancel(c)
    if anims[c] then
        pcall(function() anims[c]:cancel() end)
        anims[c] = nil
    end
end

local function animate_opacity(c, target, duration)
    if not c.valid then return end
    cancel(c)
    local from = c.opacity or 1
    if math.abs(from - target) < 0.01 then return end
    anims[c] = awesome.start_animation(duration, "ease-out-cubic",
        function(p)
            if c.valid then c.opacity = from + (target - from) * p end
        end,
        function()
            if c.valid then c.opacity = (target >= 1) and nil or target end
            anims[c] = nil
        end)
end


-- // MARK -- open fade

client.connect_signal("request::manage", guarded(function(c)
    if awesome.startup then return end
    c.opacity = 0
    animate_opacity(c, 1, M.open_duration)
end))


-- // MARK -- close animation

client.connect_signal("request::unmanage", guarded(function(c)
    if awesome.startup then return end
    local geo = c:geometry()
    if geo.width < 40 or geo.height < 40 then return end
    local ok, content = pcall(function() return c.content end)
    if not ok or not content then return end
    local ok2, surf = pcall(gears.surface.load_uncached, content)
    if not ok2 or not surf then return end

    local ghost = wibox({
        ontop = true,
        visible = true,
        x = geo.x, y = geo.y, width = geo.width, height = geo.height,
        bg = "#00000000",
        type = "utility",
    })
    ghost:setup { image = surf, resize = true, widget = wibox.widget.imagebox }

    awesome.start_animation(M.close_duration, "ease-out-cubic",
        function(p)
            if not ghost.valid then return end
            -- Keep the last frame covering the vacated tile while
            -- layout_animation moves its neighbour underneath. Fading only
            -- after that reflow removes the distracting wallpaper flash.
            local fade = math.max(0, (p - M.close_fade_delay) / (1 - M.close_fade_delay))
            ghost.opacity = 1 - fade
        end,
        function()
            if ghost.valid then ghost.visible = false end
            ghost = nil
        end)
end))


-- // MARK -- focus dim

client.connect_signal("focus", guarded(function(c)
    c.border_color = beautiful.border_focus
    animate_opacity(c, 1, M.dim_duration)
end))

client.connect_signal("unfocus", guarded(function(c)
    c.border_color = beautiful.border_normal
    if c.fullscreen then return end  -- don't dim videos and games
    animate_opacity(c, M.dim_opacity, M.dim_duration)
end))


-- // MARK -- floating shadows

local function apply_shadow(c)
    if not c.valid then return end
    if c.floating and not c.fullscreen and not c.maximized then
        c.shadow = M.shadow
    else
        c.shadow = nil
    end
end

client.connect_signal("request::manage", guarded(apply_shadow))
client.connect_signal("property::floating", guarded(apply_shadow))
client.connect_signal("property::fullscreen", guarded(apply_shadow))
client.connect_signal("property::maximized", guarded(apply_shadow))

return M
