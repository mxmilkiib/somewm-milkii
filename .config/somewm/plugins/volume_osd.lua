-- plugins/volume_osd.lua
-- Volume OSD matching plugins/brightness.lua: text progress bar in a
-- replaceable notification. Volume changes use wpctl directly in exact 3%
-- steps, then read the resulting default-sink volume back for display.

local awful = require("awful")
local naughty = require("naughty")
local guarded = require("error_guard")

local M = {}

local current_notification = nil

local function show_osd(pct, muted)
    local bar_len = 20
    local filled  = math.floor(math.min(pct, 100) / 100 * bar_len + 0.5)
    local bar     = string.rep("█", filled) .. string.rep("░", bar_len - filled)
    local text    = muted and ("muted  " .. pct .. "%")
        or string.format("%s  %d%%", bar, pct)

    if current_notification and not current_notification.is_expired then
        current_notification.message = text
        current_notification:emit_signal("property::message")
        current_notification:reset_timeout(1.5)
    else
        current_notification = naughty.notification {
            title    = "Volume",
            message  = text,
            timeout  = 1.5,
            position = "bottom_middle",
            app_name = "volume",
        }
    end
end

local function query_and_show()
    awful.spawn.easy_async("wpctl get-volume @DEFAULT_AUDIO_SINK@", guarded(function(out)
        -- "Volume: 0.45" or "Volume: 0.45 [MUTED]"
        local vol = out:match("Volume:%s*([%d%.]+)")
        if not vol then return end
        local pct = math.floor(tonumber(vol) * 100 + 0.5)
        local muted = out:find("MUTED") ~= nil
        show_osd(pct, muted)
        awesome.emit_signal("volume::updated", pct, muted)
    end))
end

local function run_then_show(cmd)
    awful.spawn.easy_async(cmd, guarded(query_and_show))
end

function M.increase()
    run_then_show({ "wpctl", "set-volume", "-l", "1.5", "@DEFAULT_AUDIO_SINK@", "3%+" })
end
function M.decrease()
    run_then_show({ "wpctl", "set-volume", "@DEFAULT_AUDIO_SINK@", "3%-" })
end
function M.toggle_mute()
    run_then_show({ "wpctl", "set-mute", "@DEFAULT_AUDIO_SINK@", "toggle" })
end

return M
