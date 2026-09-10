-- plugins/shake_cursor.lua
-- Shake the pointer to temporarily enlarge it (KDE's Shake Cursor effect).
--
-- Port of KWin's shake_cursor plugin:
--   ShakeDetector     — shakedetector.cpp  (SPDX-FileCopyrightText: 2023 Vlad Zahorodnii, GPL-2.0-or-later)
--   ShakeCursorEffect — shakecursor.cpp   (same author / license)
--
-- Polls mouse.coords() at a low rate and feeds each sample to a shake
-- detector that mirrors KWin's algorithm: consecutive movements in the same
-- direction are collapsed into a single history entry (sameSign
-- deduplication), so the trail only records direction-change vertices. A
-- shake is detected when the path length exceeds `sensitivity` times the
-- bounding-box diagonal (minimum diagonal `min_diagonal`), at which point
-- the history is cleared — growth is discrete, one step per detected shake.
--
-- On the first shake the cursor is magnified by `magnification`; each
-- subsequent shake adds `over_magnification` (additive, matching KWin).
-- Both inflate and deflate are animated over `anim_duration` with
-- ease-in-out-cubic easing (KWin uses QEasingCurve::InOutCubic). The cursor
-- deflates `deflate_delay` seconds after the last detected shake.
--
-- somewm draws the cursor itself for clients using cursor-shape-v1 (GTK4,
-- Qt6, most modern toolkits) and for wibars/root; clients that upload their
-- own cursor surface keep their size until they next set it.
--
-- Usage in rc.lua:
--     require("plugins.shake_cursor").start()

local gears = require("gears")
local guarded = require("error_guard")

local M = {
    poll_interval = 0.033,       -- poll period in seconds
    history_window = 1.0,        -- seconds of motion history (KDE TimeInterval: 1000ms)
    sensitivity = 4.0,           -- path length / bounding-box diagonal (KDE Sensitivity)
    min_diagonal = 100,         -- minimum bounding-box diagonal in pixels (KDE hardcoded)
    magnification = 3.0,        -- first-shake magnification (KDE Magnification)
    over_magnification = 1.0,   -- additive per subsequent shake (KDE OverMagnification)
    deflate_delay = 2.0,        -- seconds after last shake before deflating (KDE: 2000ms)
    anim_duration = 0.2,        -- inflate/deflate animation duration (KDE: 200ms)
    anim_easing = "ease-in-out-cubic", -- KDE uses QEasingCurve::InOutCubic
}

local samples = {}              -- history of {x, y, t} (direction-change vertices only)
local base_size
local current_scale = 1         -- current magnification factor
local target_scale = 1          -- target magnification factor
local poll, deflate_timer, scale_animation
local tick_count = 0

-- root.cursor_size() rebuilds the xcursor manager, so skip no-op sets
local last_set
local function set_size(size)
    size = math.floor(size + 0.5)
    if size == last_set then return end
    last_set = size
    root.cursor_size(size)
end

local function reset_size()
    if base_size then set_size(base_size) end
    target_scale = 1
    current_scale = 1
    scale_animation = nil
end

-- Movements within `tolerance` pixels count as either direction (handles
-- sub-pixel jitter). Mirrors KWin's sameSign() in shakedetector.cpp.
local function same_sign(a, b)
    local tolerance = 1
    return (a >= -tolerance and b >= -tolerance) or (a <= tolerance and b <= tolerance)
end

-- Animate to a target magnification, mirroring KWin's animateTo().
local function animate_to(target)
    if target_scale == target then return end
    if scale_animation then pcall(function() scale_animation:cancel() end) end
    local from = current_scale
    scale_animation = awesome.start_animation(M.anim_duration, M.anim_easing,
        function(progress)
            current_scale = from + (target - from) * progress
            if base_size then set_size(base_size * current_scale) end
        end,
        function()
            scale_animation = nil
        end)
    target_scale = target
end

local function inflate()
    if target_scale == 1 then
        animate_to(M.magnification)
    else
        animate_to(target_scale + M.over_magnification)
    end
end

local function deflate()
    animate_to(1)
end

-- Feed a position sample to the shake detector. Returns true if a shake
-- was detected. Mirrors KWin's ShakeDetector::update() in shakedetector.cpp.
local function detect_shake(x, y, now)
    local window_ticks = M.history_window / M.poll_interval

    -- Prune entries older than the history window
    while samples[1] and now - samples[1].t >= window_ticks do
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
            last.t = now
            return false
        end
    end

    samples[#samples + 1] = { x = x, y = y, t = now }

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

local function tick()
    tick_count = tick_count + 1
    local c = mouse.coords()
    if detect_shake(c.x, c.y, tick_count) then
        base_size = base_size or root.cursor_size()
        inflate()
        deflate_timer:again()
    end
    return true
end

function M.start()
    if poll then return end
    deflate_timer = gears.timer { timeout = M.deflate_delay, single_shot = true, callback = guarded(deflate) }
    poll = gears.timer { timeout = M.poll_interval, autostart = true, callback = guarded(tick) }
    awesome.connect_signal("exit", guarded(reset_size))
end

function M.stop()
    if poll then poll:stop(); poll = nil end
    if scale_animation then pcall(function() scale_animation:cancel() end) end
    reset_size()
end

return M
