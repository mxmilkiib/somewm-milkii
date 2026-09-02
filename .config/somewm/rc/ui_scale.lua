-- // MARK: UI SCALE MODULE
-- ################################################################################
-- ██╗   ██╗██╗███████╗██╗   ██╗ █████╗ ██╗
-- ██║   ██║██║╔══════╝██║   ██║██╔══██║██║
-- ██║   ██║██║███████╗██║   ██║███████║██║
-- ╚██╗ ██╔╝██║╚════██║██║   ██║██╔══██║██║
--  ╚████╔╝ ██║███████║╚██████╔╝██║  ██║███████╗
--   ╚═══╝  ╚═╝╚══════╝ ╚═════╝ ╚═╝  ╚═╝╚══════╝
-- ################################################################################
--
-- Persistent UI scale factor for dynamic zoom of the somewm interface.
-- Stored in ~/.config/somewm/.ui_scale as a plain number.
-- Applied at theme load time to dpi() values and font sizes.
-- Changed via keybindings; takes effect on awesome.restart().

local M = {}

local scale_file = os.getenv("HOME") .. "/.config/somewm/.ui_scale"
local MIN_SCALE = 0.75
local MAX_SCALE = 2.0
local STEP = 0.1
local DEFAULT = 1.0

-- Debounced restart: coalesce rapid zoom presses into a single awesome.restart()
-- to avoid hot-reload races that crash somewm when multiple reloads overlap
local restart_timer = nil
local RESTART_DELAY = 0.3  -- seconds

function M.debounced_restart()
    if restart_timer then
        restart_timer:again()
    else
        restart_timer = require("gears.timer").start_new(RESTART_DELAY, function()
            awesome.restart()
            return false  -- one-shot
        end)
    end
end

function M.get_scale()
    local f = io.open(scale_file, "r")
    if f then
        local val = tonumber(f:read("*l"))
        f:close()
        if val and val >= MIN_SCALE and val <= MAX_SCALE then
            return val
        end
    end
    return DEFAULT
end

function M.set_scale(val)
    val = math.max(MIN_SCALE, math.min(MAX_SCALE, val))
    local f = io.open(scale_file, "w")
    if f then
        f:write(string.format("%.2f\n", val))
        f:close()
    end
    return val
end

function M.adjust(delta)
    return M.set_scale(M.get_scale() + delta)
end

function M.zoom_in()
    return M.adjust(STEP)
end

function M.zoom_out()
    return M.adjust(-STEP)
end

function M.reset()
    return M.set_scale(DEFAULT)
end

return M
