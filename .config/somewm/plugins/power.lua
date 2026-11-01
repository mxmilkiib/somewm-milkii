-- plugins/power.lua
-- Unified laptop power management. Owns four concerns that were previously
-- scattered across rc.lua and this file:
--
--   1. Battery/AC monitoring  — upower --monitor-detail feeds
--      plugins/alertd.lua, which owns all level thresholds, warnings and the
--      emergency suspend. Thresholds fire on *measured* level/trend, not
--      reported state: firmware that drains the battery while claiming
--      "charging" (e.g. HP Adaptive Battery Optimizer) is caught by the
--      drain_on_ac stage and can no longer bypass the suspend floor.
--   2. Power-profile switching — power-profiles-daemon profile is flipped to
--      `profile_ac` on charger and `profile_batt` on battery, on every real
--      AC/battery transition and once on boot. A config reload does NOT switch
--      (detected via awesome.startup), so a manually-chosen profile survives
--      reloads.
--   3. Idle management        — swayidle is launched here only when at least
--      one stage (dim/lock/suspend) is configured in M.idle; with all stages
--      nil no swayidle is spawned. Idle handling has moved to the native
--      screensaver module (plugins/screensaver.lua). The dim/undim signal
--      plumbing below is kept for when a stage is re-enabled.
--   4. Lid handling            — suspend when undocked, no action while an
--      external display is attached. Detected via udevadm (with a
--      slow poll safety net), reading the authoritative ACPI lid state file.
--
-- The wibar battery widget keeps its own /sys display; nothing visible is
-- replaced. Thresholds and idle timeouts fire once per discharge cycle
-- (re-armed when charging).
--
-- Replaces the inline `swayidle` launch that used to live in rc.lua. That line
-- also had a latent bug: it parsed `wlopm -j` with `.[].name` but the JSON
-- field is `output`, so DPMS-off-on-idle never actually fired. This module
-- uses the correct field.

local awful   = require("awful")
local gears   = require("gears")
local naughty = require("naughty")
local guarded = require("error_guard")
local alertd  = require("plugins.alertd")
local screensaver = require("plugins.screensaver")

local M = {
    -- battery thresholds (percent)
    warn_pct      = 15,
    critical_pct  = 7,
    suspend_pct   = 3,
    -- power-profiles-daemon profile per power source
    profile_ac   = "balanced",
    profile_batt = "balanced",
    -- idle timeouts in seconds; a nil stage disables it.
    -- All stages currently nil: swayidle/swaylock replaced by the native
    -- screensaver module (plugins/screensaver.lua + awesome idle timers).
    -- Previous values: ac dim=300 lock=600, batt dim=120 lock=240 suspend=600
    idle = {
        ac   = { dim = nil, lock = nil, suspend = nil },
        batt = { dim = nil, lock = nil, suspend = nil },
    },
    dim_pct = 5,                 -- screen brightness percent during idle dim
    internal_output_prefix = "eDP",  -- built-in panel name prefix
    -- lid-close action; one of M.lid_options keys, overridable at runtime
    -- from the battery popup (persisted to LID_STATE_FILE below)
    lid_action = "suspend",
}

-- lid-close actions selectable from the battery popup. The choice persists
-- across config reloads/restarts via a one-line state file (plain text —
-- it stores a single key; same dir convention as floating_rules_data.lua)
local LID_STATE_FILE = (os.getenv("HOME") or "") .. "/.config/somewm/lid_action"
M.lid_options = {
    { key = "suspend",        label = "Suspend (Undocked)" },
    { key = "suspend_always", label = "Suspend (Always)" },
    { key = "screensaver",    label = "Screensaver" },
    { key = "dpms_off",       label = "Screen Off" },
    { key = "ignore",         label = "Nothing" },
}

local state = {
    charging = nil,   -- tri-state: nil until first upower report
    pct = nil,
    lid_closed = nil, -- tri-state: nil until first lid read
    lid_file = nil,
    dimmed = false,
    dim_saved = nil,  -- brightness percent captured before dim
    profile = nil,    -- last power-profile set by this module
    is_boot = false,  -- true only on a real boot (awesome.startup), not a reload
}

-- tracked resources for hot-reload cleanup (B20)
local tracked = { timers = {}, pids = {}, signals = {} }

local function cleanup()
    for _, t in ipairs(tracked.timers) do t:stop() end
    tracked.timers = {}
    for _, pid in ipairs(tracked.pids) do
        awful.spawn.with_shell("kill " .. pid .. " 2>/dev/null")
    end
    tracked.pids = {}
    for _, sig in ipairs(tracked.signals) do
        awesome.disconnect_signal(sig.name, sig.handler)
    end
    tracked.signals = {}
end

local function track_signal(name, handler)
    awesome.connect_signal(name, handler)
    tracked.signals[#tracked.signals + 1] = { name = name, handler = handler }
end

local function track_timer(t)
    tracked.timers[#tracked.timers + 1] = t
    return t
end

-- swayidle runs each command through a shell, so these pipe into awesome-client
-- to emit signals that the dim/undim handlers below catch with full Lua state.
local DIM_CMD   = [[echo "awesome.emit_signal('power_idle_dim')" | awesome-client]]
local UNDIM_CMD = [[echo "awesome.emit_signal('power_idle_resume')" | awesome-client]]


-- MARK: NOTIFICATIONS

local function notify(title, text, urgency)
    naughty.notification {
        title = title,
        message = text,
        urgency = urgency or "normal",
        app_name = "power",
        timeout = urgency == "critical" and 0 or 5,
    }
end


-- MARK: BATTERY

-- Threshold enforcement moved to alertd rules (see M.start). This only keeps
-- state.pct fresh for the AC-transition notifications below and feeds the
-- trend history early on real battery events — level warnings and the
-- suspend floor now apply regardless of what ACPI claims.
local function on_percentage(pct)
    state.pct = pct
    alertd.sample_now("battery")
end


-- MARK: POWER PROFILES

local function set_profile(profile)
    if not profile or state.profile == profile then return end
    awful.spawn.easy_async("powerprofilesctl set " .. profile, guarded(function()
        state.profile = profile
    end))
end


-- MARK: IDLE DIM

-- Save the current backlight percent, then dim to dim_pct. Signalled by
-- swayidle's dim timeout via awesome-client.
local function dim()
    if state.dimmed then return end
    awful.spawn.easy_async("brightnessctl -m info 2>/dev/null", guarded(function(out)
        local pct = out and out:match(",(%d+)%%")
        state.dim_saved = pct and tonumber(pct)
        state.dimmed = true
        awful.spawn("brightnessctl set " .. M.dim_pct .. "%")
    end))
end

-- Restore the pre-dim brightness. Signalled by swayidle's resume event.
local function undim()
    if not state.dimmed then return end
    state.dimmed = false
    local restore = state.dim_saved or 100
    state.dim_saved = nil
    awful.spawn("brightnessctl set " .. restore .. "%")
end


-- MARK: SWAYIDLE

local function idle_conf()
    return state.charging and M.idle.ac or M.idle.batt
end

-- Build the swayidle argv. Each command is a single string that swayidle runs
-- through a shell, so pipes (dim/undim) work without outer-shell quoting.
local function build_swayidle_argv()
    local c = idle_conf()
    local argv = { "swayidle", "-w" }
    local n = 0
    local function add_timeout(secs, cmd, resume_cmd)
        if not secs then return end
        n = n + 1
        table.insert(argv, "timeout")
        table.insert(argv, tostring(secs))
        table.insert(argv, cmd)
        if resume_cmd then
            table.insert(argv, "resume")
            table.insert(argv, resume_cmd)
        end
    end
    add_timeout(c.dim, DIM_CMD, UNDIM_CMD)
    add_timeout(c.lock, "swaylock -f")
    add_timeout(c.suspend, "systemctl suspend")
    if n == 0 then return nil end  -- no stages configured: don't launch
    return argv
end

-- Kill any prior swayidle (orphans from a previous session included) and spawn
-- a fresh instance with the timeouts for the current power source. A short
-- delay lets the old process exit before the new one registers idle timers,
-- avoiding a brief window of double-fire.
local function launch_swayidle()
    undim()
    awful.spawn.with_shell("pkill -u $USER -x swayidle 2>/dev/null")
    gears.timer.start_new(0.3, guarded(function()
        local argv = build_swayidle_argv()
        if argv then awful.spawn(argv, false) end
        return false  -- one-shot
    end))
end


-- MARK: LID

-- True if any non-internal output is attached (i.e. docked). Parses wlopm -j in
-- Lua to avoid a jq dependency in the hot path.
local function has_external_display(cb)
    awful.spawn.easy_async("wlopm -j 2>/dev/null", guarded(function(out)
        local found = false
        for name in (out or ""):gmatch('"output"%s*:%s*"([^"]-)"') do
            if not name:match("^" .. M.internal_output_prefix) then
                found = true
                break
            end
        end
        cb(found)
    end))
end

-- persist + expose the lid-close action for the battery popup
local function save_lid_action()
    local f = io.open(LID_STATE_FILE, "w")
    if not f then return end
    f:write(M.lid_action .. "\n")
    f:close()
end

local function load_lid_action()
    local f = io.open(LID_STATE_FILE, "r")
    if not f then return end
    local a = f:read("*l")
    f:close()
    for _, opt in ipairs(M.lid_options) do
        if opt.key == a then M.lid_action = a; return end
    end
end

function M.set_lid_action(key)
    if key == M.lid_action then return end
    M.lid_action = key
    save_lid_action()
end

local function on_lid_close()
    local act = M.lid_action
    if act == "ignore" then return end
    if act == "screensaver" then
        screensaver.preview()
    elseif act == "dpms_off" then
        awesome.dpms_off()
    else
        -- suspend modes: a docked laptop stays up unless "always" is chosen
        has_external_display(function(ext)
            if act == "suspend_always" or not ext then
                awful.spawn("systemctl suspend")
            end
        end)
    end
end

local function on_lid_open()
    -- ensure outputs are powered on in case DPMS had them off
    awful.spawn.with_shell("wlopm -j 2>/dev/null | jq -r '.[].output' 2>/dev/null | xargs -I{} wlopm --on {}")
end

-- Read the authoritative ACPI lid state and act on open/closed transitions.
-- Called by both the udevadm event stream and the safety poll below, so it must
-- be idempotent on a steady state.
local function on_lid_check()
    if not state.lid_file then return end
    local f = io.open(state.lid_file, "r")
    if not f then return end
    local s = f:read("*a")
    f:close()
    local st = s:match("state:%s*(%w+)")
    if not st then return end
    local closed = (st == "closed")
    if state.lid_closed == closed then return end  -- no transition
    state.lid_closed = closed
    if closed then on_lid_close() else on_lid_open() end
end


-- MARK: AC STATE

local function on_state(s)
    local charging = (s == "charging" or s == "fully-charged" or s == "pending-charge")
    if state.charging == charging then return end
    local first = state.charging == nil
    state.charging = charging
    -- (re)launch swayidle with timeouts for this source
    launch_swayidle()
    if first then
        -- priming report: auto-switch only on a real boot. On a reload this
        -- is skipped so a manually-chosen profile (or one left from a previous
        -- session) survives.
        if state.is_boot then
            set_profile(charging and M.profile_ac or M.profile_batt)
        end
        return
    end
    set_profile(charging and M.profile_ac or M.profile_batt)
    if charging then
        notify("Power", "Charger connected" .. (state.pct and (" — " .. state.pct .. "%") or ""))
    else
        notify("Power", "On battery" .. (state.pct and (" — " .. state.pct .. "%") or ""))
    end
end


-- MARK: STARTUP

function M.start()
    -- clean up any resources from a previous hot-reload (B20)
    cleanup()
    -- a reload creates a fresh Lua state with an empty `tracked` table, so the
    -- old state's resources can only be released from its own "exit" handler
    awesome.connect_signal("exit", guarded(cleanup))

    -- true only during the initial startup phase, false on a config reload;
    -- captured synchronously here because the upower priming callback fires
    -- later, after awesome.startup has already gone false
    state.is_boot = awesome.startup and true or false

    -- restore the popup-chosen lid action (survives reloads and restarts)
    load_lid_action()

    -- idle dim/undim signals (fired by swayidle via awesome-client)
    track_signal("power_idle_dim", guarded(dim))
    track_signal("power_idle_resume", guarded(undim))

    -- locate the ACPI lid state file once, then prime lid state
    awful.spawn.easy_async("ls /proc/acpi/button/lid/*/state 2>/dev/null | head -1",
        guarded(function(out)
            state.lid_file = (out or ""):gmatch("[^\r\n]+")() or nil
            if state.lid_file then on_lid_check() end
        end))

    -- lid events: instant via udevadm, plus a 30s poll safety net in case the
    -- uevent stream misses a transition (cheap: one file read per tick)
    local udev_pid = awful.spawn.with_line_callback("udevadm monitor --kernel --subsystem-match=acpi", {
        stdout = guarded(function() on_lid_check() end),
    })
    if type(udev_pid) == "number" then tracked.pids[#tracked.pids + 1] = udev_pid end
    track_timer(gears.timer.start_new(30, guarded(function() on_lid_check(); return true end)))

    -- battery metric + staged rules; all thresholds fire on measured level
    -- and trend, immune to a lying "charging" status
    alertd.unregister("power")
    alertd.metric {
        name     = "battery",
        interval = 60,
        journal  = true,
        source   = alertd.source.sysfs_battery(),  -- auto-finds BAT*
    }
    alertd.rule {
        metric = "battery",
        id     = "power",
        stages = {
            { name  = "drain_on_ac",
              title = "Battery drain",
              level = "warn",
              -- escalating: tighten as the drain continues (10m, 5m, then 2m)
              renotify = { 600, 300, 120 },
              when = function(h)
                  local s = h.newest()
                  return s ~= nil and s.ac == true
                      and s.status ~= "Discharging"
                      and h:draining("pct", 1200, 4)
              end,
              msg  = function(h)
                  local d = -h:delta("pct", 1200)
                  return ("draining while plugged in — %d%%, -%d in 20 min (charger not delivering?)")
                      :format(h.newest().pct or -1, d)
              end },
            { name  = "low",
              title = "Battery low",
              level = "warn",
              when = function(h)
                  local s = h.newest()
                  return s ~= nil and (s.pct or 100) <= M.warn_pct
              end,
              -- hysteresis: fires at <=warn_pct, re-arms at >=warn_pct+2 so a
              -- pct oscillating across the threshold can't re-notify
              rearm_when = function(h)
                  local s = h.newest()
                  return s ~= nil and (s.pct or 100) < M.warn_pct + 2
              end,
              msg  = function(h)
                  return (h.newest().pct or 0) .. "% remaining"
              end },
            { name  = "critical",
              title = "Battery critical",
              level = "critical",
              when = function(h)
                  local s = h.newest()
                  return s ~= nil and (s.pct or 100) <= M.critical_pct
              end,
              rearm_when = function(h)
                  local s = h.newest()
                  return s ~= nil and (s.pct or 100) < M.critical_pct + 2
              end,
              msg  = function(h)
                  return (h.newest().pct or 0) .. "% remaining — suspending at " .. M.suspend_pct .. "%"
              end },
            { name  = "emergency",
              title = "Battery empty",
              level = "action",
              grace = 30,
              snooze = 1800,
              run   = "systemctl suspend",
              msg   = function(h)
                  return (h.newest().pct or 0) .. "% — suspending"
              end,
              when = function(h)
                  local s = h.newest()
                  if not s or (s.pct or 100) > M.suspend_pct then return false end
                  -- on AC and genuinely recovering, stay put; draining or on
                  -- battery, suspend before the hard cutoff kills the session
                  return s.ac ~= true or h:draining("pct", 600, 1)
              end,
              rearm_when = function(h)
                  local s = h.newest()
                  return s ~= nil and (s.pct or 100) < M.suspend_pct + 2
              end },
        },
    }

    -- battery/AC monitor (event-driven, no polling)
    local upower_pid = awful.spawn.with_line_callback("upower --monitor-detail", {
        stdout = guarded(function(line)
            local pct = line:match("^%s*percentage:%s*(%d+)%%")
            if pct then return on_percentage(tonumber(pct)) end
            local st = line:match("^%s*state:%s*([%w%-]+)")
            if st then return on_state(st) end
        end),
    })
    if type(upower_pid) == "number" then tracked.pids[#tracked.pids + 1] = upower_pid end
    -- prime state so the first monitor event isn't treated as a change
    awful.spawn.easy_async_with_shell(
        "upower -i $(upower -e | grep -m1 BAT) 2>/dev/null | grep -E 'state|percentage'",
        guarded(function(out)
            if not out or out == "" then return end
            local st = out:match("state:%s*([%w%-]+)")
            local pct = out:match("percentage:%s*(%d+)%%")
            if st then on_state(st) end
            if pct then state.pct = tonumber(pct) end
        end))
    -- prime the current power profile so set_profile skips a redundant set
    awful.spawn.easy_async("powerprofilesctl get", guarded(function(out)
        state.profile = (out or ""):gmatch("[^\r\n]+")() or nil
    end))
end

return M
