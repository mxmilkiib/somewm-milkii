-- brightness - screen brightness control with KDE-style OSD
-- Uses brightnessctl (works with /sys/class/backlight on Wayland).
-- Shows a transient notification with a progress bar on every change,
-- matching the KDE Plasma brightness OSD behaviour.


local awful   = require("awful")
local naughty = require("naughty")

local M = {}

local STEP = 5  -- percent change per key press

-- cached notification object so rapid presses replace the same popup
local current_notification

-- read current brightness as a percentage (0-100)
local function get_percent()
    local f = io.popen("brightnessctl -m info 2>/dev/null")
    if not f then return nil end
    local line = f:read("*l")
    f:close()
    if not line then return nil end
    -- brightnessctl -m output: device,class,brightness/max,percent,icon
    -- e.g. amdgpu_bl1,backlight,400000/400000,100%,display-brightness-symbolic
    local pct = line:match(",(%d+)%%")
    return pct and tonumber(pct)
end

-- show or replace the OSD notification with a text progress bar
local function show_osd(pct)
    local bar_len = 20
    local filled  = math.floor(pct / 100 * bar_len + 0.5)
    local bar     = string.rep("█", filled) .. string.rep("░", bar_len - filled)
    local text    = string.format("%s  %d%%", bar, pct)

    if current_notification and not current_notification.is_expired then
        current_notification.message = text
        current_notification:emit_signal("property::message")
    else
        current_notification = naughty.notification {
            title    = "Brightness",
            message  = text,
            timeout  = 1.5,
            position = "bottom_middle",
            app_name = "brightness",
        }
    end
end

-- change brightness by delta percent (positive or negative) and show OSD
function M.adjust(delta)
    -- brightnessctl syntax: +10% to increase, 10%- to decrease
    local arg = delta > 0 and ("+" .. delta .. "%") or (math.abs(delta) .. "%-")
    awful.spawn.easy_async("brightnessctl set " .. arg, function()
        local pct = get_percent()
        if pct then show_osd(pct) end
    end)
end

function M.increase()
    M.adjust(STEP)
end

function M.decrease()
    M.adjust(-STEP)
end

-- set an absolute percentage
function M.set(pct)
    pct = math.max(1, math.min(100, pct))
    awful.spawn.easy_async("brightnessctl set " .. pct .. "%", function()
        show_osd(pct)
    end)
end

return M
