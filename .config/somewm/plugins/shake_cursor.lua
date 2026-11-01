-- plugins/shake_cursor.lua
-- Shake the pointer to temporarily enlarge it (KDE's Shake Cursor effect).
--
-- Port of KWin's shake_cursor plugin:
--   ShakeDetector     — shakedetector.cpp  (SPDX-FileCopyrightText: 2023 Vlad Zahorodnii, GPL-2.0-or-later)
--   ShakeCursorEffect — shakecursor.cpp   (same author / license)
--
-- Driven by the compositor's pointer::motion signal (emitted from C on every
-- pointer motion event) rather than a polling timer, so there are zero
-- wakeups when the mouse is idle and no missed direction changes during fast
-- shakes. The detector mirrors KWin's algorithm: consecutive movements in
-- the same direction are collapsed into a single history entry (sameSign
-- deduplication), so the trail only records direction-change vertices. A
-- shake is detected when the path length exceeds `sensitivity` times the
-- bounding-box diagonal (minimum diagonal `min_diagonal`), at which point
-- the history is cleared — growth is discrete, one step per detected shake.
--
-- On the first shake the cursor is magnified by `magnification`; each
-- subsequent shake adds `over_magnification` (additive, matching KWin).
-- KWin has no magnification cap; it loads the cursor theme at
-- Magnification + 8*OverMagnification = 11x device pixels, so `max_scale`
-- caps growth at that same crisp range (the compositor's hires cursor is
-- loaded at CURSOR_HIRES_MULT = 11x for the same reason).
-- Inflate and deflate animate root._cursor_magnify() with the C-side ease
-- easing (KWin uses QEasingCurve::InOutCubic, 200ms in both directions)
-- via awesome.start_animation, which ticks on the compositor refresh cycle.
-- root._cursor_magnify() re-renders a pre-loaded high-resolution cursor image
-- at a new size — it never reloads the xcursor theme — so the animation is
-- smooth and crisp without the per-step manager rebuild that
-- root.cursor_size() would incur. The animated size is quantised to whole
-- pixels (sub-pixel scaling is invisible and would otherwise re-render the
-- cursor buffer ~1000x/sec). The cursor deflates `deflate_delay` seconds
-- (KDE: 2000ms) after the last detected shake; mere continued oscillation
-- does not defer it.
--
-- KWin resets the detector while any pointer button is held and on pointer
-- warps (event->buttons / event->warp in ShakeCursorEffect::pointerMotion).
-- Buttons are matched by polling mouse.coords().buttons on each event;
-- warps need no handling because wlr_cursor_warp does not emit
-- pointer::motion at all. KWin also skips detection while the pointer is
-- confined by a pointer-constraints region, which is not exposed to Lua.
--
-- somewm draws the cursor itself for clients using cursor-shape-v1 (GTK4,
-- Qt6, most modern toolkits) and for wibars/root; clients that upload their
-- own cursor surface keep their size until they next set it.
--
-- Usage in rc.lua:
--     require("plugins.shake_cursor").start()

local gears = require("gears")
local guarded = require("error_guard")

-- High-resolution monotonic clock for the history window.
local ffi = require("ffi")
ffi.cdef("struct timespec { long tv_sec; long tv_nsec; };")
ffi.cdef("int clock_gettime(int, struct timespec *);")
local ts = ffi.new("struct timespec")
local function now()
    ffi.C.clock_gettime(1, ts)  -- CLOCK_MONOTONIC
    return tonumber(ts.tv_sec) + tonumber(ts.tv_nsec) / 1e9
end

local M = {
    history_window = 1.0,        -- seconds of motion history (KDE TimeInterval: 1000ms)
    sensitivity = 4.0,           -- path length / bounding-box diagonal (KDE Sensitivity)
    min_diagonal = 100,          -- minimum bounding-box diagonal in pixels (KDE hardcoded)
    magnification = 3.0,         -- first-shake magnification (KDE Magnification)
    over_magnification = 1.0,    -- additive per subsequent shake (KDE OverMagnification)
    max_scale = 11.0,            -- KDE keeps growing unbounded; its hires prefetch is
                               -- Magnification + 8*OverMagnification = 11x (CURSOR_HIRES_MULT)
    deflate_delay = 2.0,         -- seconds after last detected shake (KDE: start(2000))
    anim_duration = 0.2,         -- inflate animation duration (KDE: 200ms)
    deflate_duration = 0.2,      -- deflate animation duration (KDE: same 200ms both ways)
    anim_easing = "ease-in-out-cubic", -- KDE uses QEasingCurve::InOutCubic
}

local samples = {}               -- history of {x, y, t} (direction-change vertices only)
local current_scale = 1          -- current magnification factor
local target_scale = 1           -- target magnification factor
local deflate_timer
local connected = false
local on_motion_guarded

-- root._cursor_magnify(scale, duration) animates the declared cursor leaf in
-- C on the frame clock (upstream's ease is fixed); no per-frame Lua calls or
-- buffer throttling needed. Instant when duration is 0.
local function reset_scale()
    current_scale = 1
    target_scale = 1
    root._cursor_magnify(1, 0)
end

-- Movements within `tolerance` pixels of zero count as either direction
-- (handles sub-pixel jitter). Mirrors KWin's sameSign() in shakedetector.cpp:
--   (a >= -tolerance && b >= -tolerance) || (a <= tolerance && b <= tolerance)
-- so a large delta followed by sub-tolerance jitter still counts as the same
-- direction (no vertex is recorded for it).
local function same_sign(a, b)
    local tolerance = 1
    return (a >= -tolerance and b >= -tolerance) or (a <= tolerance and b <= tolerance)
end

-- Animate to a target magnification, mirroring KWin's animateTo(). The C
-- side eases the leaf on the frame clock; a client-owned cursor image is
-- left alone (root._cursor_magnify resets to 1 for it).
local function animate_to(target)
    if target_scale == target then return end
    local duration = (target < current_scale) and M.deflate_duration or M.anim_duration
    current_scale = target
    target_scale = target
    root._cursor_magnify(target, duration)
end

local function inflate()
    if target_scale == 1 then
        animate_to(M.magnification)
    else
        animate_to(math.min(target_scale + M.over_magnification, M.max_scale))
    end
end

local function deflate()
    animate_to(1)
    -- Deliberate deviation from KWin, which does not reset the detector here:
    -- the deflate fires while the user may still be moving, and surviving
    -- pre-deflate motion can immediately re-satisfy the shake criterion,
    -- producing an inflate/deflate ping-pong. Fresh history after deflation
    -- requires a genuinely new shake.
    samples = {}
end

-- Feed a position sample to the shake detector. Returns true if a shake
-- was detected. Mirrors KWin's ShakeDetector::update() in shakedetector.cpp.
local function detect_shake(x, y, t)
    -- Prune entries older than the history window
    while samples[1] and t - samples[1].t >= M.history_window do
        table.remove(samples, 1)
    end

    -- sameSign deduplication: if movement from prev->last and last->current
    -- have the same sign in both axes, replace last with current (collapse
    -- consecutive same-direction movement into one segment).
    local n = #samples
    if n >= 2 then
        local last = samples[n]
        local prev = samples[n - 1]
        if same_sign(last.x - prev.x, x - last.x)
           and same_sign(last.y - prev.y, y - last.y) then
            last.x = x
            last.y = y
            last.t = t
            return false
        end
    end

    samples[#samples + 1] = { x = x, y = y, t = t }

    -- Compute path length and bounding-box diagonal
    local distance = 0
    local left, top = samples[1].x, samples[1].y
    local right, bottom = left, top
    for i = 2, #samples do
        local dx = samples[i].x - samples[i - 1].x
        local dy = samples[i].y - samples[i - 1].y
        distance = distance + math.sqrt(dx * dx + dy * dy)
        left = math.min(left, samples[i].x)
        top = math.min(top, samples[i].y)
        right = math.max(right, samples[i].x)
        bottom = math.max(bottom, samples[i].y)
    end

    local diagonal = math.sqrt((right - left)^2 + (bottom - top)^2)
    if diagonal < M.min_diagonal then
        return false
    end

    if distance / diagonal > M.sensitivity then
        -- Clear history on shake (KWin behaviour)
        samples = {}
        return true
    end

    return false
end

local function on_motion(x, y)
    -- KWin resets the detector while any pointer button is held
    -- (event->buttons != Qt::NoButton) so dragging never counts as shaking.
    -- buttons[4]/[5] are scroll up/down, never held (somewm_api.c), so only
    -- buttons 1-3 need checking.
    local b = mouse.coords().buttons
    if b[1] or b[2] or b[3] then
        samples = {}
        return
    end
    if detect_shake(x, y, now()) then

        inflate()
        -- KWin restarts the deflate timer only on a detected shake, not on
        -- mere continued oscillation.
        deflate_timer:again()
    end
end

function M.start()
    if connected then return end
    -- root._cursor_magnify and pointer::motion live only in the combined
    -- tree; on upstream the whole plugin is inert, so bail now rather than
    -- erroring inside the first timer callback
    if not root._cursor_magnify then return end
    -- Reset C-side cursor_scale: it persists across Lua reloads and may be
    -- stuck at a magnified value from before the reload. Defer to the next
    -- event loop iteration so some_apply_cursor() doesn't schedule output
    -- frames while the hot-reload is still in progress (that freezes the WM).
    gears.timer { timeout = 0, single_shot = true, callback = function()
        root._cursor_magnify(1, 0)
    end }
    current_scale = 1
    target_scale = 1
    samples = {}
    deflate_timer = gears.timer { timeout = M.deflate_delay, single_shot = true, callback = guarded(deflate) }
    on_motion_guarded = guarded(on_motion)
    awesome.connect_signal("pointer::motion", on_motion_guarded)
    awesome.connect_signal("exit", guarded(reset_scale))
    connected = true
end

function M.stop()
    if not connected then return end
    awesome.disconnect_signal("pointer::motion", on_motion_guarded)
    on_motion_guarded = nil
    connected = false
    reset_scale()
end

return M
