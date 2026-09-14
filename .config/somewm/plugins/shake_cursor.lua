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
-- Inflate and deflate animate root.cursor_scale() with ease-in-out-cubic
-- easing (KWin uses QEasingCurve::InOutCubic) via awesome.start_animation,
-- which ticks on the compositor refresh cycle. root.cursor_scale() re-renders
-- a pre-loaded high-resolution cursor image at a new size — it never reloads
-- the xcursor theme — so the animation is smooth and crisp without the
-- per-step manager rebuild that root.cursor_size() would incur. The animated
-- size is quantised to whole pixels (sub-pixel scaling is invisible and would
-- otherwise re-render the cursor buffer ~1000x/sec). The cursor deflates
-- `deflate_delay` seconds after the last shake or direction-change while
-- oscillating, so it stays enlarged throughout a continuous shake.
--
-- somewm draws the cursor itself for clients using cursor-shape-v1 (GTK4,
-- Qt6, most modern toolkits) and for wibars/root; clients that upload their
-- own cursor surface keep their size until they next set it.
--
-- Usage in rc.lua:
--     require("plugins.shake_cursor").start()

local gears = require("gears")
local guarded = require("error_guard")

-- High-resolution monotonic clock for the history window and cooldown.
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
    max_scale = 4.0,             -- cap: hires image is 4x, beyond that it upscales blurry
    deflate_delay = 1.5,         -- seconds after last shake before deflating
    anim_duration = 0.2,         -- inflate animation duration (KDE: 200ms)
    deflate_duration = 1.0,      -- deflate animation duration
    anim_easing = "ease-in-out-cubic", -- KDE uses QEasingCurve::InOutCubic
}

local samples = {}               -- history of {x, y, t} (direction-change vertices only)
local base_size                  -- nominal cursor size, captured on first shake
local current_scale = 1          -- current magnification factor
local target_scale = 1           -- target magnification factor
local last_px                    -- last integer pixel size sent to C (throttle)
local deflate_timer, scale_animation
local cooldown_until = 0         -- monotonic time until which detection is suppressed
local connected = false
local on_motion_guarded

-- awesome.start_animation ticks on the compositor refresh cycle, which the
-- animation keepalive wakes at ~1ms; without throttling that would re-render
-- the cursor buffer ~1000x/sec. Quantise the displayed size to whole pixels
-- (a sub-pixel scale change is invisible anyway) and skip no-op sends.
local function set_scale(scale)
    current_scale = scale
    if not base_size then return end
    local px = math.floor(base_size * scale + 0.5)
    if px == last_px then return end
    last_px = px
    root.cursor_scale(px / base_size)
end

local function reset_scale()
    if scale_animation then
        pcall(function() scale_animation:cancel() end)
        scale_animation = nil
    end
    last_px = nil
    set_scale(1)
    target_scale = 1
end

-- Movements within `tolerance` pixels of zero count as either direction
-- (handles sub-pixel jitter). Mirrors KWin's sameSign() in shakedetector.cpp.
local function same_sign(a, b)
    local tolerance = 1
    if math.abs(a) <= tolerance and math.abs(b) <= tolerance then
        return true
    end
    return (a < 0 and b < 0) or (a > 0 and b > 0)
end

-- Animate to a target magnification, mirroring KWin's animateTo(). Drives
-- root.cursor_scale() on the frame clock; each frame re-renders the existing
-- high-res cursor image at a new size, so there are no xcursor theme reloads.
local function animate_to(target)
    if target_scale == target then return end
    if scale_animation then
        pcall(function() scale_animation:cancel() end)
    end
    local from = current_scale
    local duration = (target < from) and M.deflate_duration or M.anim_duration
    scale_animation = awesome.start_animation(duration, M.anim_easing,
        function(progress)
            set_scale(from + (target - from) * progress)
        end,
        function()
            scale_animation = nil
            if target == 1 then
                set_scale(1)
            end
        end)
    target_scale = target
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
    -- Clear residual motion samples so small movements after deflation do
    -- not combine with stale history to falsely re-trigger a shake.
    samples = {}
    cooldown_until = now() + 0.5
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
    local t = now()
    if t < cooldown_until then return end
    local before = #samples
    local shook = detect_shake(x, y, t)
    if shook then
        base_size = base_size or root.cursor_size()
        inflate()
        deflate_timer:again()
    elseif current_scale > 1 and #samples > before then
        -- A new direction-change vertex was added: the pointer is still
        -- oscillating, so keep the cursor enlarged even though a full shake
        -- has not (yet) been re-detected. This prevents the deflate timer
        -- from firing mid-shake when the detection interval (~1s after a
        -- history clear) approaches deflate_delay.
        deflate_timer:again()
    end
end

function M.start()
    if connected then return end
    -- Reset C-side cursor_scale: it persists across Lua reloads and may be
    -- stuck at a magnified value from before the reload. Defer to the next
    -- event loop iteration so some_apply_cursor() doesn't schedule output
    -- frames while the hot-reload is still in progress (that freezes the WM).
    gears.timer { timeout = 0, single_shot = true, callback = function()
        root.cursor_scale(1.0)
    end }
    current_scale = 1
    target_scale = 1
    last_px = nil
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
