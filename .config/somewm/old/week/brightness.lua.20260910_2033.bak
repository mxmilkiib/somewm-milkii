-- brightness - screen brightness control with KDE-style OSD
-- Uses brightnessctl (works with /sys/class/backlight on Wayland).
-- Adjusts every backlight device (not LEDs) so multi-backlight systems
-- change all screens together; the percentage shown is the first
-- backlight's value. Shows a transient notification with a progress bar
-- on every change, matching the KDE Plasma brightness OSD behaviour.
--
-- Monitors without a software-controllable backlight (e.g. HDMI/DP panels
-- that lack DDC/CI) cannot be changed from the compositor at all; those
-- keep their OSD setting.


local awful   = require("awful")
local naughty = require("naughty")

local M = {}

local STEP = 5  -- percent change per key press

-- cached notification object so rapid presses replace the same popup
local current_notification

-- list backlight device names (class "backlight" only, LEDs excluded)
local function backlight_devices(callback)
    awful.spawn.easy_async("brightnessctl -l -m 2>/dev/null", function(out)
        local devices = {}
        for line in (out or ""):gmatch("[^\r\n]+") do
            local device, class = line:match("^([^,]+),([^,]+),")
            if device and class == "backlight" then
                devices[#devices + 1] = device
            end
        end
        callback(devices)
    end)
end

-- read current brightness as a percentage (0-100) from the first backlight
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
    awesome.emit_signal("brightness::updated", pct)
    local bar_len = 20
    local filled  = math.floor(pct / 100 * bar_len + 0.5)
    local bar     = string.rep("█", filled) .. string.rep("░", bar_len - filled)
    local text    = string.format("%s  %d%%", bar, pct)

    if current_notification and not current_notification.is_expired then
        current_notification.message = text
        current_notification:emit_signal("property::message")
        current_notification:reset_timeout(1.5)
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

-- apply a brightnessctl set argument to every backlight device
local function set_all(arg, show_pct)
    backlight_devices(function(devices)
        if #devices == 0 then
            local pct = get_percent()
            if pct then show_osd(show_pct or pct) end
            return
        end
        local pending = #devices
        for _, device in ipairs(devices) do
            awful.spawn.easy_async(
                { "brightnessctl", "-d", device, "set", arg },
                function()
                    pending = pending - 1
                    if pending == 0 then
                        local pct = get_percent()
                        if pct then show_osd(pct) end
                    end
                end)
        end
    end)
end

-- change brightness by delta percent (positive or negative) and show OSD
function M.adjust(delta)
    -- brightnessctl syntax: +10% to increase, 10%- to decrease
    local arg = delta > 0 and ("+" .. delta .. "%") or (math.abs(delta) .. "%-")
    set_all(arg)
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
    set_all(pct .. "%", pct)
end

return M
