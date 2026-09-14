-- plugins/power.lua
-- Battery and power-supply events without polling: a single long-running
-- `upower --monitor-detail` stream drives notifications and, at the
-- critical threshold, a suspend. Replaces nothing visible; the wibar
-- battery widget keeps its own display.
--
-- Thresholds fire once per discharge cycle (re-armed when charging).

local awful = require("awful")
local naughty = require("naughty")
local guarded = require("error_guard")

local M = {
    warn_pct = 15,
    critical_pct = 7,
    suspend_pct = 3,
}

local state = {
    charging = nil,   -- tri-state: nil until first report
    pct = nil,
    warned = false,
    criticaled = false,
}

local function notify(title, text, urgency)
    naughty.notification {
        title = title,
        message = text,
        urgency = urgency or "normal",
        app_name = "power",
        timeout = urgency == "critical" and 0 or 5,
    }
end

local function on_percentage(pct)
    state.pct = pct
    if state.charging ~= false then return end
    if pct <= M.suspend_pct then
        notify("Battery empty", "Suspending now", "critical")
        awful.spawn.with_shell("sleep 2 && systemctl suspend")
    elseif pct <= M.critical_pct and not state.criticaled then
        state.criticaled = true
        notify("Battery critical", pct .. "% remaining — suspending at " .. M.suspend_pct .. "%", "critical")
    elseif pct <= M.warn_pct and not state.warned then
        state.warned = true
        notify("Battery low", pct .. "% remaining")
    end
end

local function on_state(s)
    local charging = (s == "charging" or s == "fully-charged" or s == "pending-charge")
    if state.charging == charging then return end
    local first = state.charging == nil
    state.charging = charging
    if charging then
        state.warned, state.criticaled = false, false
        if not first then
            notify("Power", "Charger connected" .. (state.pct and (" — " .. state.pct .. "%") or ""))
        end
    elseif not first then
        notify("Power", "On battery" .. (state.pct and (" — " .. state.pct .. "%") or ""))
    end
end

function M.start()
    awful.spawn.with_line_callback("upower --monitor-detail", {
        stdout = guarded(function(line)
            local pct = line:match("^%s*percentage:%s*(%d+)%%")
            if pct then return on_percentage(tonumber(pct)) end
            local st = line:match("^%s*state:%s*([%w%-]+)")
            if st then return on_state(st) end
        end),
    })
    -- prime the state so the first monitor event isn't treated as a change
    awful.spawn.easy_async_with_shell(
        "upower -i $(upower -e | grep -m1 BAT) 2>/dev/null | grep -E 'state|percentage'",
        guarded(function(out)
            local pct = out:match("percentage:%s*(%d+)%%")
            local st = out:match("state:%s*([%w%-]+)")
            if st then on_state(st) end
            if pct then state.pct = tonumber(pct) end
        end))
end

return M
