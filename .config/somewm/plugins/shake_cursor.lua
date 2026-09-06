-- plugins/shake_cursor.lua
-- Shake the pointer to temporarily enlarge it (Hyprland's shake_to_find).
--
-- Polls mouse.coords() at a low rate and keeps a short window of samples.
-- A shake is a lot of travel inside a small bounding box: when the path
-- length over the window exceeds `ratio` times the box diagonal (and a
-- minimum travel), the cursor grows via root.cursor_size() and shrinks back
-- `restore` seconds after the shaking stops.
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
    interval = 0.033,   -- poll period in seconds
    window = 0.45,      -- seconds of motion history considered
    ratio = 3.0,        -- path length / bounding box diagonal to count as a shake
    min_travel = 500,   -- pixels of path length needed inside the window
    scale = 2.5,        -- enlarged size = base size * scale
    restore = 0.8,      -- seconds after the last shake before shrinking back
}

local samples = {}
local base_size
local enlarged = false
local poll, restore_timer

local function set_size(size)
    root.cursor_size(math.floor(size + 0.5))
end

local function shrink()
    if enlarged and base_size then set_size(base_size) end
    enlarged = false
end

local function is_shaking()
    local path, minx, miny, maxx, maxy = 0, math.huge, math.huge, -math.huge, -math.huge
    local prev
    for _, s in ipairs(samples) do
        if prev then path = path + math.sqrt((s.x - prev.x)^2 + (s.y - prev.y)^2) end
        minx, maxx = math.min(minx, s.x), math.max(maxx, s.x)
        miny, maxy = math.min(miny, s.y), math.max(maxy, s.y)
        prev = s
    end
    local diag = math.sqrt((maxx - minx)^2 + (maxy - miny)^2)
    return path >= M.min_travel and path > M.ratio * math.max(diag, 1)
end

local function tick()
    local c = mouse.coords()
    samples[#samples + 1] = { x = c.x, y = c.y }
    -- samples arrive at a fixed rate, so the window is just a sample count
    while #samples > M.window / M.interval do table.remove(samples, 1) end
    if #samples > 3 and is_shaking() then
        if not enlarged then
            base_size = base_size or root.cursor_size()
            set_size(base_size * M.scale)
            enlarged = true
        end
        restore_timer:again()
    end
    return true
end

function M.start()
    if poll then return end
    restore_timer = gears.timer { timeout = M.restore, single_shot = true, callback = guarded(shrink) }
    poll = gears.timer { timeout = M.interval, autostart = true, callback = guarded(tick) }
    awesome.connect_signal("exit", guarded(shrink))
end

function M.stop()
    if poll then poll:stop(); poll = nil end
    shrink()
end

return M
