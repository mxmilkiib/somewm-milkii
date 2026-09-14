-- plugins/volume_osd.lua
-- Volume OSD matching plugins/brightness.lua: text progress bar in a
-- replaceable notification. Volume changes use wpctl in 3% steps, snapping
-- to exactly 100% when a step would cross it so 100 is always reachable,
-- then read the resulting default-sink volume back for display.

local awful = require("awful")
local naughty = require("naughty")
local guarded = require("error_guard")
local volume_popup = require("plugins.volume_popup")

local M = {}

local current_notification = nil

local function show_osd(pct, muted)
    local bar_len = 20
    local filled  = math.floor(math.min(pct, 100) / 100 * bar_len + 0.5)
    local bar     = string.rep("█", filled) .. string.rep("░", bar_len - filled)
    local text    = muted and ("muted  " .. pct .. "%")
        or string.format("%s  %d%%", bar, pct)

    if current_notification then
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
        current_notification:connect_signal("destroyed", function()
            current_notification = nil
        end)
    end
end

local function query_and_show()
    awful.spawn.easy_async("wpctl get-volume @DEFAULT_AUDIO_SINK@", guarded(function(out)
        -- "Volume: 0.45" or "Volume: 0.45 [MUTED]"
        local vol = out:match("Volume:%s*([%d%.]+)")
        if not vol then return end
        local pct = math.floor(tonumber(vol) * 100 + 0.5)
        local muted = out:find("MUTED") ~= nil
        -- suppress the OSD while the volume popup is open; the popup already
        -- shows the default-sink level, so the floating notification is redundant
        if not volume_popup.is_visible() then
            show_osd(pct, muted)
        end
        awesome.emit_signal("volume::updated", pct, muted)
    end))
end

local function run_then_show(cmd)
    awful.spawn.easy_async(cmd, guarded(query_and_show))
end

local STEP = 3
local VOL_MAX = 150  -- wpctl -l ceiling

-- read current volume, compute the target after a delta, and snap to 100
-- when the step would cross it so 100% is always a reachable value
local function adjust_volume(delta)
    awful.spawn.easy_async("wpctl get-volume @DEFAULT_AUDIO_SINK@", guarded(function(out)
        local vol = out:match("Volume:%s*([%d%.]+)")
        if not vol then return end
        local current = tonumber(vol) * 100
        local target = current + delta
        if delta > 0 and current < 100 and target > 100 then
            target = 100
        elseif delta < 0 and current > 100 and target < 100 then
            target = 100
        end
        target = math.max(0, math.min(VOL_MAX, target))
        run_then_show({ "wpctl", "set-volume", "-l", "1.5",
            "@DEFAULT_AUDIO_SINK@", string.format("%.4f", target / 100) })
    end))
end

function M.increase()
    adjust_volume(STEP)
end
function M.decrease()
    adjust_volume(-STEP)
end
function M.toggle_mute()
    run_then_show({ "wpctl", "set-mute", "@DEFAULT_AUDIO_SINK@", "toggle" })
end

return M
