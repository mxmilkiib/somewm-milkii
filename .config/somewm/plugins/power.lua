-- plugins/power.lua
-- Unified laptop power management. Owns four concerns that were previously
-- scattered across rc.lua and this file:
--
--   1. Battery/AC monitoring  — upower --monitor-detail drives low/critical
--      warnings and a forced suspend at the empty threshold (unchanged from
--      the original power.lua).
--   2. Power-profile switching — power-profiles-daemon profile is flipped to
--      `profile_ac` on charger and `profile_batt` on battery, on every real
--      AC/battery transition and once on boot. A config reload does NOT switch
--      (detected via awesome.startup), so a manually-chosen profile survives
--      reloads.
--   3. Idle management        — swayidle is launched here with a dim -> lock
--      -> suspend timeout chain. The dim/undim stages signal back into this
--      module via `awesome-client` so brightness is saved and restored in Lua.
--      Timeouts adapt to the power source; swayidle is restarted on every
--      AC/battery transition to pick up the new chain.
--   4. Lid handling            — context-aware: suspend when undocked, lock
--      only when an external display is attached. Detected via udevadm (with a
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

local M = {
    -- battery thresholds (percent)
    warn_pct      = 15,
    critical_pct  = 7,
    suspend_pct   = 3,
    -- power-profiles-daemon profile per power source
    profile_ac   = "performance",
    profile_batt = "power-saver",
    -- idle timeouts in seconds; a nil stage disables it
    idle = {
        ac   = { dim = 300, lock = 600, suspend = nil },  -- no auto-suspend on AC
        batt = { dim = 120, lock = 240, suspend = 600 },
    },
    dim_pct = 5,                 -- screen brightness percent during idle dim
    internal_output_prefix = "eDP",  -- built-in panel name prefix
}

local state = {
    charging = nil,   -- tri-state: nil until first upower report
    pct = nil,
    warned = false,
    criticaled = false,
    lid_closed = nil, -- tri-state: nil until first lid read
    lid_file = nil,
    dimmed = false,
    dim_saved = nil,  -- brightness percent captured before dim
    profile = nil,    -- last power-profile set by this module
    is_boot = false,  -- true only on a real boot (awesome.startup), not a reload
}

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
    local argv = { "swayidle", "-w", "before-sleep", "swaylock -f" }
    local function add_timeout(secs, cmd, resume_cmd)
        if not secs then return end
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
        awful.spawn(build_swayidle_argv(), false)
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

local function on_lid_close()
    has_external_display(function(ext)
        if ext then
            -- docked: lock only, keep the external display running
            awful.spawn("swaylock -f")
        else
            -- undocked: suspend (swayidle before-sleep locks the screen)
            awful.spawn("systemctl suspend")
        end
    end)
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
        state.warned, state.criticaled = false, false
        notify("Power", "Charger connected" .. (state.pct and (" — " .. state.pct .. "%") or ""))
    else
        notify("Power", "On battery" .. (state.pct and (" — " .. state.pct .. "%") or ""))
    end
end


-- MARK: STARTUP

function M.start()
    -- true only during the initial startup phase, false on a config reload;
    -- captured synchronously here because the upower priming callback fires
    -- later, after awesome.startup has already gone false
    state.is_boot = awesome.startup and true or false

    -- idle dim/undim signals (fired by swayidle via awesome-client)
    awesome.connect_signal("power_idle_dim", guarded(dim))
    awesome.connect_signal("power_idle_resume", guarded(undim))

    -- locate the ACPI lid state file once, then prime lid state
    awful.spawn.easy_async("ls /proc/acpi/button/lid/*/state 2>/dev/null | head -1",
        guarded(function(out)
            state.lid_file = (out or ""):gmatch("[^\r\n]+")() or nil
            if state.lid_file then on_lid_check() end
        end))

    -- lid events: instant via udevadm, plus a 30s poll safety net in case the
    -- uevent stream misses a transition (cheap: one file read per tick)
    awful.spawn.with_line_callback("udevadm monitor --kernel --subsystem-match=acpi", {
        stdout = guarded(function() on_lid_check() end),
    })
    gears.timer.start_new(30, guarded(function() on_lid_check(); return true end))

    -- battery/AC monitor (event-driven, no polling)
    awful.spawn.with_line_callback("upower --monitor-detail", {
        stdout = guarded(function(line)
            local pct = line:match("^%s*percentage:%s*(%d+)%%")
            if pct then return on_percentage(tonumber(pct)) end
            local st = line:match("^%s*state:%s*([%w%-]+)")
            if st then return on_state(st) end
        end),
    })
    -- prime state so the first monitor event isn't treated as a change
    awful.spawn.easy_async_with_shell(
        "upower -i $(upower -e | grep -m1 BAT) 2>/dev/null | grep -E 'state|percentage'",
        guarded(function(out)
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
