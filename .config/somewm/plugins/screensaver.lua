-- plugins/screensaver.lua
-- Idle screensaver + staged screen-off, built entirely on somewm's native
-- idle API (awesome.set_idle_timeout / idle::start / idle::stop) so no
-- compositor patch or external swayidle/swaylock is needed.
--
-- Stages (all suppressed automatically while anything inhibits idle —
-- wayland protocol inhibitors such as video players, or a manual
-- awesome.idle_inhibit = true toggle):
--
--   1. saver_timeout  -> animated saver: a warp starfield in the classic
--                        Windows style — stars spawning anywhere on screen
--                        and accelerating outward until they exit — with
--                        subtle chromatic
--                        aberration fringes toward the edges, plus a clock
--                        wandering a slow Lissajous path. Luminance is
--                        capped low so almost no pixels are lit; nothing
--                        stays static long enough to burn.
--   2. dpms_timeout   -> awesome.dpms_off() (hard off; any input wakes the
--                        outputs via the compositor's activity handler).
--
-- Activity fires idle::stop, which hides the saver instantly.
--
-- M.start() is called once from rc.lua. somewm clears all idle timeouts on
-- config hot-reload, so re-registering here on each load is correct.

local awful   = require("awful")
local gears   = require("gears")
local wibox   = require("wibox")
local naughty = require("naughty")
local lgi     = require("lgi")
local GLib    = lgi.GLib
local cairo   = lgi.cairo
local math    = math
local os      = os

-- monotonic wall-clock seconds for animation (os.clock is CPU time and
-- would make the drift speed depend on WM load)
local function now()
    return GLib.get_monotonic_time() / 1e6
end

local M = {
    saver_timeout = 300,     -- idle seconds before the saver appears
    dpms_timeout  = 1800,    -- idle seconds before outputs power off (nil = never)
    star_density  = 1/16000, -- stars per square pixel of screen
    max_luminance = 0.34,    -- peak alpha of any drawn element (0-1)
    aberration    = 3.0,     -- chromatic aberration: max fringe offset in px (at screen edge)
    streak        = true,    -- draw a short motion trail behind each star
    show_clock    = true,
    fps           = 24,
}

local savers = {}        -- array of saver wiboxes (one per screen)
local anim_timer
local start_epoch = 0
-- forward declarations: draw_saver references both, hide is called from it
local draw_saver_inner
local hide


-- MARK: DRAWING


-- deterministic per-star parameters from an index, so every frame is a pure
-- function of time and no per-star state table needs updating.
-- A star's trip is one exponential fly-out: it spawns at a point hashed from
-- (index, cycle) — uniformly over the screen plus margin, so there is no
-- bordered spawn region — then travels outward along its radial at speed
-- proportional to its distance, exiting past the screen edge exactly at the
-- cycle's end and wrapping to a fresh spawn point.
local function star_params(i)
    -- cheap hash -> reproducible pseudo-randoms in [0,1)
    local function h(n)
        local x = math.sin(i * 127.1 + n * 311.7) * 43758.5453
        return x - math.floor(x)
    end
    return {
        v     = 0.10 + h(3) * 0.22,      -- cycles/sec: full trip ~3-10s
        phase = h(4),                    -- cycle offset
        r0    = 0.45 + h(5) * 0.6,       -- base radius
        lum   = 0.55 + h(6) * 0.45,      -- per-star brightness variance
        -- subtle tint: mostly white, some warm, some cool
        tr    = 1.0,
        tg    = 0.92 + h(7) * 0.08,
        tb    = 0.88 + h(8) * 0.12,
    }
end

-- hash keyed on star index AND trip number, for per-cycle respawn points
local function star_spawn(i, cyc, n)
    local x = math.sin(i * 127.1 + cyc * 74.7 + n * 311.7) * 43758.5453
    return x - math.floor(x)
end

local draw_failed = false
local function draw_saver(self, context, cr, width, height)
    local ok, err = pcall(draw_saver_inner, self, context, cr, width, height)
    if ok or draw_failed then return end
    draw_failed = true
    -- defer hide() out of the paint path, then report once
    gears.timer.delayed_call(hide)
    naughty.notification {
        title = "Screensaver draw failed",
        message = tostring(err),
        urgency = "critical",
    }
end

function draw_saver_inner(self, context, cr, width, height)
    local t = now() - start_epoch
    local maxlum = M.max_luminance

    -- warp starfield: each star spawns somewhere on screen and accelerates
    -- outward along its radial until it leaves the frame; chromatic
    -- aberration fringes grow with radius like a lens, so the effect is
    -- invisible at center and subtle at the edges
    local cx, cy = width / 2, height / 2
    local mindim = math.min(width, height)
    local rnorm_scale = 2 / mindim
    local count = math.max(24, math.floor(width * height * M.star_density))

    for i = 1, count do
        local p = star_params(i)
        local tt = t * p.v + p.phase
        local cyc = math.floor(tt)
        local u = tt - cyc               -- trip progress 0 -> 1

        -- this trip's spawn point: uniform over the screen plus a small
        -- margin, re-hashed per cycle so wrapping is a teleport, not a rewind
        local sx = star_spawn(i, cyc, 1) * (width + 40) - 20
        local sy = star_spawn(i, cyc, 2) * (height + 40) - 20
        local ox, oy = sx - cx, sy - cy
        local od = math.sqrt(ox * ox + oy * oy)
        if od < 8 then ox, oy, od = 6, 6, 8.5 end  -- centre spawn: nudge off the singularity
        local ux, uy = ox / od, oy / od

        -- distance from centre to the screen boundary (plus margin) along
        -- the star's radial — the trip exits the frame at u = 1
        local rx = ux > 0 and (width + 40 - cx) / ux
            or (ux < 0 and (cx + 40) / -ux or math.huge)
        local ry = uy > 0 and (height + 40 - cy) / uy
            or (uy < 0 and (cy + 40) / -uy or math.huge)
        local R = math.min(rx, ry)
        if od >= R then
            -- a spawn beyond its own exit boundary would travel inward;
            -- pull it inside along the same radial instead
            local s = (R * 0.9) / od
            ox, oy, od = ox * s, oy * s, R * 0.9
        end

        -- exponential travel: r = od * (R/od)^u — speed ∝ radius, so stars
        -- creep off their spawn and whip out of the frame like warp
        local r = od * ((R / od) ^ u)
        local x, y = cx + ux * r, cy + uy * r
        if x > -40 and x < width + 40 and y > -40 and y < height + 40 then
            local a = math.min(1, u / 0.12) * maxlum * p.lum
            local rr = math.min(4, p.r0 * (0.5 + 3 * u))

            local ca = M.aberration * math.min(1, r * rnorm_scale)

            -- motion streak: line back toward where the star was a few
            -- frames ago on this same trip
            if M.streak and a > 0.08 then
                local pu = u - p.v * 4 / M.fps
                if pu > 0 then
                    local pr = od * ((R / od) ^ pu)
                    cr:set_source_rgba(1, 1, 1, a * 0.4)
                    cr:set_line_width(rr * 0.8)
                    cr:move_to(x, y)
                    cr:line_to(cx + ux * pr, cy + uy * pr)
                    cr:stroke()
                end
            end

            -- chromatic fringes: red pushed outward, blue pulled inward
            if ca > 0.5 and a > 0.06 then
                local fr = rr * 0.9
                cr:set_source_rgba(1, 0.3, 0.35, a * 0.5)
                cr:arc(x + ux * ca, y + uy * ca, fr, 0, math.pi * 2)
                cr:fill()
                cr:set_source_rgba(0.35, 0.55, 1, a * 0.5)
                cr:arc(x - ux * ca, y - uy * ca, fr, 0, math.pi * 2)
                cr:fill()
            end

            cr:set_source_rgba(p.tr, p.tg, p.tb, a)
            cr:arc(x, y, rr, 0, math.pi * 2)
            cr:fill()
        end
    end

    -- wandering clock (slow Lissajous path over the middle 70% of the screen)
    if M.show_clock then
        local tt = os.date("*t")
        local text = string.format("%02d:%02d", tt.hour, tt.min)
        local cx = width  * (0.5 + 0.35 * math.sin(t * 0.021))
        local cy = height * (0.5 + 0.30 * math.sin(t * 0.013 + 1.3))
        local fs = math.max(28, height / 14)
        cr:select_font_face("sans", cairo.FontSlant.NORMAL, cairo.FontWeight.NORMAL)
        cr:set_font_size(fs)
        local ext = cr:text_extents(text)
        cr:set_source_rgba(0.85, 0.85, 0.9, maxlum * 0.55)
        cr:move_to(cx - ext.width / 2, cy + ext.height / 2)
        cr:show_text(text)
    end
end


-- MARK: SAVER WINDOWS


local function make_saver(s)
    local g = s.geometry
    local canvas = wibox.widget.base.make_widget()
    canvas.draw = draw_saver

    local w = wibox {
        x       = g.x,
        y       = g.y,
        width   = g.width,
        height  = g.height,
        visible = true,
        ontop   = true,
        bg      = "#000000",
        widget  = canvas,
    }
    -- let pointer input fall through to whatever is underneath; activity is
    -- what dismisses the saver, so the saver itself should not eat it
    pcall(function() w.input_passthrough = true end)
    return w
end

local function show()
    if #savers > 0 then return end
    start_epoch = now()
    for s in screen do
        savers[#savers + 1] = make_saver(s)
    end
    if not anim_timer then
        anim_timer = gears.timer {
            timeout   = 1 / M.fps,
            autostart = false,
            callback  = function()
                -- an empty list means hide() ran but a tick was already
                -- queued; stop rather than spin on nothing
                if #savers == 0 then
                    anim_timer:stop()
                    return
                end
                -- a throwing tick must never become an error flood: kill the
                -- timer and drop the saver rather than spam every frame
                local ok, err = pcall(function()
                    for _, sv in ipairs(savers) do
                        sv.widget:emit_signal("widget::redraw_needed")
                    end
                end)
                if not ok then
                    hide()
                    naughty.notification {
                        title = "Screensaver disabled",
                        message = tostring(err),
                        urgency = "critical",
                    }
                end
            end,
        }
    end
    anim_timer:start()
end

function hide()
    for _, sv in ipairs(savers) do
        sv.visible = false
    end
    savers = {}
    if anim_timer then anim_timer:stop() end
end


-- MARK: CONTROL


-- manual inhibit toggle (caffeine-style): awesome.idle_inhibit suppresses
-- every idle timeout while set, independent of protocol inhibitors
function M.set_inhibit(on)
    awesome.idle_inhibit = on and true or false
end

function M.toggle_inhibit()
    awesome.idle_inhibit = not awesome.idle_inhibit
    return awesome.idle_inhibit
end

function M.inhibited()
    return awesome.idle_inhibited
end

-- preview the saver immediately (testing / keybind)
function M.preview()
    show()
end


-- MARK: START


function M.start()
    -- native idle timeouts; cleared by somewm on config hot-reload and
    -- re-registered here each load
    awesome.set_idle_timeout("screensaver", M.saver_timeout, show)
    if M.dpms_timeout then
        awesome.set_idle_timeout("screensaver_dpms", M.dpms_timeout,
            function() awesome.dpms_off() end)
    end

    -- activity hides the saver; screen-off also stops the animation
    awesome.connect_signal("idle::stop", hide)
    awesome.connect_signal("dpms::off", hide)
end

return M
