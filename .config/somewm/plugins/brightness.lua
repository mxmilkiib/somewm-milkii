-- brightness - screen brightness control with KDE-style OSD
-- Uses brightnessctl for hardware backlights (internal panels) and
-- wlr-brightnessd for software gamma dimming on monitors without
-- hardware backlight (e.g. external HDMI/DP panels lacking DDC/CI).
-- Both are adjusted together so all screens change at once, matching
-- KDE Plasma's per-display brightness OSD behaviour.
--
-- Color temperature is handled entirely by wlr-brightnessd, which
-- replaces wlsunset and applies the night-light gamma ramp to all
-- outputs. Brightness dimming is only applied to outputs that lack
-- a hardware backlight (marked via --no-brightness on the daemon).


local awful   = require("awful")
local naughty = require("naughty")
local gears   = require("gears")
local brightness_popup = require("plugins.brightness_popup")

local M = {}

local STEP = 5  -- percent change per key press
local OSD_TIMEOUT = 1.5

-- socket path for wlr-brightnessd (software brightness + color temperature)
local function get_brightnessd_sock()
    local f = io.popen("id -u 2>/dev/null")
    local uid = f and f:read("*l") or "1000"
    if f then f:close() end
    return "/tmp/wlr-brightnessd-" .. uid .. ".sock"
end
local BRIGHTNESSD_SOCK = get_brightnessd_sock()

-- cached notification object so rapid presses replace the same popup
local current_notification
-- expiry is driven by our own timer so each change resets the display
-- window instead of the first press's timer closing a later notification
local osd_timer

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
    -- when the brightness popup is open, skip the OSD notification and let
    -- the popup refresh itself so it stays in sync with the new value
    if brightness_popup.is_visible() then
        brightness_popup.refresh()
        return
    end
    local bar_len = 20
    local filled  = math.floor(pct / 100 * bar_len + 0.5)
    local bar     = string.rep("█", filled) .. string.rep("░", bar_len - filled)
    local text    = string.format("%s  %d%%", bar, pct)

    if not osd_timer then
        osd_timer = gears.timer {
            timeout     = OSD_TIMEOUT,
            single_shot = true,
            autostart   = false,
            callback    = function()
                if current_notification then
                    current_notification:destroy()
                    current_notification = nil
                end
            end,
        }
    end

    if current_notification and not current_notification.is_expired then
        current_notification.message = text
        current_notification:emit_signal("property::message")
    else
        current_notification = naughty.notification {
            title    = "Brightness",
            message  = text,
            timeout  = 0,  -- expiry handled by osd_timer
            position = "bottom_middle",
            app_name = "brightness",
        }
        current_notification:connect_signal("destroyed", function()
            current_notification = nil
            if osd_timer then osd_timer:stop() end
        end)
    end
    -- always reset the display window so it closes OSD_TIMEOUT after the
    -- last change, not after the first
    osd_timer:stop()
    osd_timer:start()
end

-- send an absolute brightness percentage to wlr-brightnessd for software dimming
-- of monitors without hardware backlight
local function set_brightnessd(pct)
    awful.spawn.with_shell(
        string.format("echo 'set_brightness %d' | socat - UNIX-CONNECT:%s 2>/dev/null",
            pct, BRIGHTNESSD_SOCK)
    )
end

-- apply a brightnessctl set argument to every backlight device,
-- and send the same percentage to wlr-brightnessd for software-dimmed monitors
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
                        if pct then
                            set_brightnessd(pct)
                            show_osd(pct)
                        end
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
    set_brightnessd(pct)
end

return M
