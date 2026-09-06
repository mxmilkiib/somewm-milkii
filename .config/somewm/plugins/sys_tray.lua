-- plugins/sys_tray.lua
-- System tray icon widgets for somewm: bluetooth, clipboard, media/mpris,
-- battery, and wifi. Each is a clickable SVG icon with status updates.
--
-- All icons use Adwaita symbolic SVGs from the system icon theme.
-- Status is polled via shell commands (bluetoothctl, nmcli, upower, etc.).
--
-- Click actions:
--   bluetooth   left-click: toggle bluetooth on/off
--   clipboard   left-click: rofi clipboard history (wl-paste + rofi)
--   media       left-click: rofi mpris player selector / play-pause
--   battery     left-click: show battery info notification
--   wifi        left-click: rofi network manager (nmcli)
--
-- All widgets are created via M.create_widgets() which returns a table of
-- widget containers to be placed in the wibar.

local awful = require("awful")
local beautiful = require("beautiful")
local wibox = require("wibox")
local gears = require("gears")
local naughty = require("naughty")
local guarded = require("error_guard")

local M = {}

local ICON_DIR = "/usr/share/icons/Adwaita/symbolic"

local function get_xresources()
    if beautiful.xresources then return beautiful.xresources end
    local ok, xr = pcall(require, "beautiful.xresources")
    if ok then return xr end
    return nil
end

local dpi = (get_xresources() and get_xresources().apply_dpi) or function(v) return v end

local COLOR_FG = beautiful.fg_normal or "#ffffff"
local COLOR_DIM = "#777777"
local ICON_SIZE = dpi(16)


-- MARK: ICON LOADING
-- // MARK --icons


local function load_svg_icon(name)
    local path = ICON_DIR .. "/" .. name
    if not gears.filesystem.file_readable(path) then return nil end
    local ok, surf = pcall(function()
        return gears.surface.load_uncached(path)
    end)
    return ok and surf or nil
end


local function make_icon_widget(symbolic_name, tooltip, onclick)
    local icon_surf = load_svg_icon(symbolic_name)
    local img = wibox.widget {
        image = icon_surf,
        forced_width = ICON_SIZE,
        forced_height = ICON_SIZE,
        resize = true,
        widget = wibox.widget.imagebox,
    }

    local container = wibox.widget {
        img,
        valign = "center",
        halign = "center",
        widget = wibox.container.place,
    }

    if onclick then
        container:connect_signal("button::press", guarded(function(_, _, _, button)
            if button == 1 then onclick() end
        end))
    end

    -- hover effect
    container:connect_signal("mouse::enter", guarded(function()
        img.opacity = 0.6
    end))
    container:connect_signal("mouse::leave", guarded(function()
        img.opacity = 1
    end))

    container.set_icon = function(surf)
        img:set_image(surf)
    end

    container.set_dim = function(dim)
        img.opacity = dim and 0.4 or 1
    end

    return container
end


-- MARK: BLUETOOTH
-- // MARK --bluetooth


local bt_widget
local function update_bluetooth()
    awful.spawn.easy_async("bluetoothctl show", function(stdout)
        local powered = stdout:match("Powered:%s*yes")
        local icon_name = powered and "devices/bluetooth-symbolic.svg"
            or "status/bluetooth-disabled-symbolic.svg"
        local surf = load_svg_icon(icon_name)
        if surf and bt_widget then bt_widget.set_icon(surf) end
        if bt_widget then bt_widget.set_dim(not powered) end
    end)
end

local function toggle_bluetooth()
    awful.spawn.easy_async("bluetoothctl show", function(stdout)
        local powered = stdout:match("Powered:%s*yes")
        if powered then
            awful.spawn("bluetoothctl power off")
        else
            awful.spawn("bluetoothctl power on")
        end
        gears.timer.start_new(0.5, guarded(function()
            update_bluetooth()
            return false
        end))
    end)
end


-- MARK: CLIPBOARD
-- // MARK --clipboard


local function show_clipboard_history()
    -- use wl-paste to get current clipboard, rofi for selection
    -- requires cliphist or a simple wl-paste history approach
    awful.spawn.easy_async("bash -c 'wl-paste --watch cliphist store 2>/dev/null; cliphist list 2>/dev/null | rofi -dmenu -p clipboard | cliphist decode | wl-copy 2>/dev/null || wl-paste'", function()
    end)
end


-- MARK: MEDIA / MPRIS
-- // MARK --mpris


local media_widget
local function update_media()
    -- check if any MPRIS player is running via dbus
    awful.spawn.easy_async("dbus-send --print-reply --dest=org.freedesktop.DBus /org/freedesktop/DBus org.freedesktop.DBus.ListNames 2>/dev/null", function(stdout)
        local has_mpris = stdout:match("org%.mpris%.MediaPlayer2")
        if media_widget then media_widget.set_dim(not has_mpris) end
    end)
end

local function show_media_controls()
    -- use dbus-send to toggle play/pause on the first available player
    awful.spawn.easy_async("dbus-send --print-reply --dest=org.freedesktop.DBus /org/freedesktop/DBus org.freedesktop.DBus.ListNames", function(stdout)
        -- find first mpris player
        local player = stdout:match("org%.mpris%.MediaPlayer2%.(%S+)")
        if player then
            awful.spawn("dbus-send --print-reply --dest=org.mpris.MediaPlayer2." .. player .. " /org/mpris/MediaPlayer2 org.mpris.MediaPlayer2.Player.PlayPause")
        else
            naughty.notify({ text = "No MPRIS player running", timeout = 2 })
        end
    end)
end


-- MARK: BATTERY
-- // MARK --battery


local battery_widget
local function update_battery()
    awful.spawn.easy_async("upower -e 2>/dev/null | grep -i battery | head -1", function(line)
        local bat_path = line:gsub("\n", "")
        if bat_path == "" then
            if battery_widget then battery_widget.set_dim(true) end
            return
        end
        awful.spawn.easy_async("upower -i " .. bat_path, function(info)
            local pct = info:match("percentage:%s*(%d+%%)")
            local charging = info:match("state:%s*charging")
            local icon_name
            if not pct then
                icon_name = "devices/battery-symbolic.svg"
            else
                local num = tonumber(pct:gsub("%%", ""))
                if charging then
                    icon_name = "status/battery-level-" .. math.min(100, math.floor(num/10)*10) .. "-charging-symbolic.svg"
                else
                    icon_name = "status/battery-level-" .. math.min(100, math.floor(num/10)*10) .. "-symbolic.svg"
                end
            end
            local surf = load_svg_icon(icon_name)
            if surf and battery_widget then battery_widget.set_icon(surf) end
            if battery_widget then battery_widget.set_dim(false) end
        end)
    end)
end

local function show_battery_info()
    awful.spawn.easy_async("upower -e 2>/dev/null | grep -i battery | head -1", function(line)
        local bat_path = line:gsub("\n", "")
        if bat_path == "" then
            naughty.notify({ text = "No battery found", timeout = 3 })
            return
        end
        awful.spawn.easy_async("upower -i " .. bat_path, function(info)
            local pct = info:match("percentage:%s*%S+")
            local state = info:match("state:%s*%S+")
            local time = info:match("time to (empty|full):%s*%S+%s*%S+")
            naughty.notify({
                text = string.format("Battery: %s\nState: %s\n%s", pct or "?", state or "?", time or ""),
                timeout = 5,
            })
        end)
    end)
end


-- MARK: WIFI
-- // MARK --wifi


local wifi_widget
local function update_wifi()
    awful.spawn.easy_async("nmcli -t -f DEVICE,STATE,TYPE con show --active 2>/dev/null | grep wireless", function(stdout)
        local connected = stdout ~= ""
        local icon_name = connected and "devices/network-wireless-symbolic.svg"
            or "status/network-wireless-disabled-symbolic.svg"
        local surf = load_svg_icon(icon_name)
        if surf and wifi_widget then wifi_widget.set_icon(surf) end
        if wifi_widget then wifi_widget.set_dim(not connected) end
    end)
end

local function show_wifi_menu()
    awful.spawn("nmcli -t -f NAME con show | rofi -dmenu -p 'WiFi network' | xargs -I{} nmcli con up '{}' 2>/dev/null")
end


-- MARK: CREATE ALL WIDGETS


function M.create_widgets()
    bt_widget = make_icon_widget("devices/bluetooth-symbolic.svg", "Bluetooth", toggle_bluetooth)
    local clip_widget = make_icon_widget("actions/edit-paste-symbolic.svg", "Clipboard", show_clipboard_history)
    media_widget = make_icon_widget("devices/audio-card-symbolic.svg", "Media", show_media_controls)
    battery_widget = make_icon_widget("devices/battery-symbolic.svg", "Battery", show_battery_info)
    wifi_widget = make_icon_widget("devices/network-wireless-symbolic.svg", "WiFi", show_wifi_menu)

    -- initial status updates
    update_bluetooth()
    update_media()
    update_battery()
    update_wifi()

    -- periodic updates
    gears.timer {
        timeout = 10,
        autostart = true,
        callback = guarded(function()
            update_bluetooth()
            update_media()
            update_wifi()
        end),
    }
    gears.timer {
        timeout = 30,
        autostart = true,
        callback = guarded(function() update_battery() end),
    }

    return {
        bluetooth = bt_widget,
        clipboard = clip_widget,
        media = media_widget,
        battery = battery_widget,
        wifi = wifi_widget,
    }
end


return M
