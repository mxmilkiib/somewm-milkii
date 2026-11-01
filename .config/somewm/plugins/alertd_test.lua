-- plugins/alertd_test.lua
-- Standalone stub harness for plugins/alertd.lua. Stubs the awesome runtime
-- (gears / naughty / awful / error_guard / the `awesome` global) via
-- package.preload and drives the framework with scripted, backdated samples.
--
-- Run from the config dir:
--   lua plugins/alertd_test.lua
-- Exits non-zero if any check fails. Journal output goes to a fake HOME
-- under /tmp, not the real alertd.log.

local SRC = debug.getinfo(1, "S").source:gsub("^@", "")
local CFG = SRC:match("^(.*)/plugins/alertd_test%.lua$")
        or SRC:match("^(.-)plugins/alertd_test%.lua$")
assert(CFG, "harness must live at <config>/plugins/alertd_test.lua")
if CFG == "" then CFG = "." end
package.path = CFG .. "/?.lua;" .. package.path

local FAKE_HOME = "/tmp/alertd_test_home"
local LOG = FAKE_HOME .. "/.local/share/somewm/alertd.log"
os.execute("mkdir -p " .. FAKE_HOME .. "/.local/share/somewm")
os.remove(LOG)

-- alertd reads os.getenv("HOME") for its journal dir at load time
local real_getenv = os.getenv
os.getenv = function(k)
    if k == "HOME" then return FAKE_HOME end
    return real_getenv(k)
end

-- controllable wall clock: samples and can_fire/grace all key on os.time
local NOW = 1000000
os.time = function() return NOW end

-- deny sysfs reads so the AC-discovery path is deterministic on any machine
-- (a real Mains adapter would short-circuit the re-probe test)
local real_open = io.open
io.open = function(path, mode)
    if type(path) == "string" and path:find("^/sys/") then return nil end
    return real_open(path, mode)
end

-- MARK: STUBS

local TIMERS = {}      -- every gears.timer created, in order
local NOTIFS = {}      -- every naughty.notification created
local SIGNALS = {}     -- { name, ... } per awesome.emit_signal
local SPAWNED = {}     -- commands via awful.spawn*
local GUARD_ERRS = {}  -- errors swallowed by the error_guard stub
local ASYNC_PROBES = 0 -- easy_async invocations (AC glob probes)
local NO_ACTIONS = false -- make naughty.notification drop spec.actions

local function new_timer(spec)
    local t = { timeout = spec.timeout, single_shot = spec.single_shot,
                callback = spec.callback, started = spec.autostart or false,
                stopped = false }
    function t:start() self.started = true; self.stopped = false end
    function t:stop() self.stopped = true; self.started = false end
    function t:emit() if not self.stopped then self.callback() end end
    TIMERS[#TIMERS + 1] = t
    return t
end

local gears = {
    timer = setmetatable({
        start_new = function(timeout, cb)
            return new_timer { timeout = timeout, single_shot = true,
                               autostart = true, callback = cb }
        end,
    }, { __call = function(_, spec) return new_timer(spec) end }),
    filesystem = {
        make_parent_directories = function(path)
            os.execute("mkdir -p " .. path:match("^(.*)/[^/]+$"))
        end,
        file_readable = function(p)
            local f = io.open(p)
            if f then f:close() return true end
            return false
        end,
    },
    debug = { print_error = function(msg) print("  [gears.debug] " .. msg) end },
}

local naughty = {}
function naughty.notification(spec)
    local n = { spec = spec }
    if spec.actions and not NO_ACTIONS then
        n.actions = {}
        for i, a in ipairs(spec.actions) do n.actions[i] = a end
    end
    NOTIFS[#NOTIFS + 1] = n
    return n
end
function naughty.action(spec)
    return { name = spec.name,
        connect_signal = function(self, sig, fn) self._cb = fn end,
        invoke = function(self) if self._cb then self._cb() end end }
end

local awful = { spawn = {} }
function awful.spawn.with_shell(cmd) SPAWNED[#SPAWNED + 1] = cmd end
function awful.spawn.easy_async(cmd, cb)
    ASYNC_PROBES = ASYNC_PROBES + 1
    cb(awful._async_out or "")  -- default: glob finds no Mains adapter
end
function awful.spawn.easy_async_with_shell(cmd, cb) cb("") end
function awful.spawn.with_line_callback(cmd, cbs) return 4242 end
setmetatable(awful.spawn, { __call = function(_, c) SPAWNED[#SPAWNED + 1] = c end })

package.preload["gears"] = function() return gears end
package.preload["naughty"] = function() return naughty end
package.preload["awful"] = function() return awful end
package.preload["error_guard"] = function()
    return function(fn)
        if not fn then return nil end
        return function(...)
            local ok, err = pcall(fn, ...)
            if not ok then GUARD_ERRS[#GUARD_ERRS + 1] = tostring(err) end
        end
    end
end

awesome = {
    emit_signal = function(...) SIGNALS[#SIGNALS + 1] = { ... } end,
    connect_signal = function() end,
    disconnect_signal = function() end,
    startup = false,
}

local alertd = require("plugins.alertd")
os.getenv = real_getenv  -- LOG_FILE is already captured; restore for the rest

-- MARK: HELPERS

local test_n, failed = 0, 0
local function check(cond, msg)
    test_n = test_n + 1
    if cond then
        print(("ok %d - %s"):format(test_n, msg))
    else
        failed = failed + 1
        print(("FAIL %d - %s"):format(test_n, msg))
    end
end

local function log_contains(pat)
    local f = io.open(LOG)
    if not f then return false end
    local s = f:read("*a")
    f:close()
    return s:find(pat, 1, true) ~= nil
end

local function sig_count(name, stage, level)
    local n = 0
    for _, s in ipairs(SIGNALS) do
        if s[1] == name and (not stage or s[2] == stage)
           and (not level or s[3] == level) then n = n + 1 end
    end
    return n
end

-- a metric whose source pops from a shared queue; feed() pushes + samples
local function queue_source(queue)
    return function()
        local s = table.remove(queue, 1)
        return s
    end
end

local function feed(metric, queue, s)
    queue[#queue + 1] = s
    alertd.sample_now(metric)
end

local function reset()
    alertd.stop()
    SIGNALS, NOTIFS, TIMERS, SPAWNED, GUARD_ERRS = {}, {}, {}, {}, {}
end

-- MARK: TESTS

print("-- duplicate metric registration")
reset()
do
    local calls1, calls2 = 0, 0
    alertd.metric { name = "dup", interval = 60,
                    source = function() calls1 = calls1 + 1 return { t = NOW } end }
    local t1 = TIMERS[#TIMERS]
    alertd.metric { name = "dup", interval = 60,
                    source = function() calls2 = calls2 + 1 return { t = NOW } end }
    local t2 = TIMERS[#TIMERS]
    check(t1 ~= t2, "re-registration creates a new timer")
    check(t1.stopped, "old timer stopped on re-registration")
    check(log_contains("OVERWRITE dup"), "re-registration journaled")
    t1:emit()  -- stopped: must not feed
    check(calls1 == 1, "dead timer no longer feeds sample_now")
    t2:emit()
    check(calls2 == 2, "live timer feeds the new source")
end

print("-- erroring source")
reset()
do
    local timer
    alertd.metric { name = "badsrc", interval = 60,
                    source = function() error("boom") end }
    timer = TIMERS[#TIMERS]
    -- registration already sampled once (error 1); four more reach the cap
    for _ = 1, 4 do alertd.sample_now("badsrc") end
    check(log_contains("ERR badsrc source()"), "source error journaled")
    check(log_contains("source disabled"), "loud disable after 5 failures")
    check(timer.stopped, "metric timer stopped after source disabled")
    -- and it must not propagate through arbitrary callers
    local ok = pcall(alertd.sample_now, "badsrc")
    check(ok, "erroring source never propagates")
end

print("-- erroring when()")
reset()
do
    local q = {}
    alertd.metric { name = "m1", source = queue_source(q) }
    alertd.rule { metric = "m1", id = "t", stages = {
        { name = "broken", level = "warn",
          when = function() error("when boom") end },
        { name = "fine", level = "warn",
          when = function(h) return h.newest().v == 1 end },
    } }
    feed("m1", q, { t = NOW, v = 1 })
    check(log_contains("ERR m1.broken when()"), "when() error journaled")
    check(sig_count("alertd::m1", "fine", "warn") == 1,
          "sibling stage still evaluates after when() error")
end

print("-- rearm_when hysteresis")
reset()
do
    local q = {}
    alertd.metric { name = "bat", source = queue_source(q) }
    alertd.rule { metric = "bat", id = "t", stages = {
        { name = "low", level = "warn",
          when = function(h) return h.newest().pct <= 15 end,
          rearm_when = function(h) return h.newest().pct < 17 end },
    } }
    -- oscillate 14/15/16/14: without hysteresis 16 would re-arm and 14 refire
    for _, p in ipairs({ 14, 15, 16, 14, 15 }) do
        NOW = NOW + 60
        feed("bat", q, { t = NOW, pct = p })
    end
    check(sig_count("alertd::bat", "low", "warn") == 1,
          "flapping across when() fires once with rearm_when")
    check(sig_count("alertd::bat", "low", "clear") == 0,
          "no spurious clear inside the rearm band")
    NOW = NOW + 60
    feed("bat", q, { t = NOW, pct = 18 })
    check(sig_count("alertd::bat", "low", "clear") == 1,
          "crossing the rearm threshold emits clear")
    NOW = NOW + 60
    feed("bat", q, { t = NOW, pct = 14 })
    check(sig_count("alertd::bat", "low", "warn") == 2,
          "stage refires after a genuine re-arm")
end

print("-- flap without rearm_when (control)")
reset()
do
    local q = {}
    alertd.metric { name = "bat2", source = queue_source(q) }
    alertd.rule { metric = "bat2", id = "t", stages = {
        { name = "low", level = "warn",
          when = function(h) return h.newest().pct <= 15 end },
    } }
    for _, p in ipairs({ 14, 16, 14 }) do
        NOW = NOW + 60
        feed("bat2", q, { t = NOW, pct = p })
    end
    check(sig_count("alertd::bat2", "low", "warn") == 2,
          "without rearm_when the same sequence refires (documents the fix)")
end

print("-- snooze / cancel / nil-actions on a pending grace run")
reset()
do
    local ran = 0
    local function mk(metric)
        local q = {}
        alertd.metric { name = metric, source = queue_source(q) }
        alertd.rule { metric = metric, id = "t", stages = {
            { name = "em", level = "action", grace = 30, snooze = 60,
              run = function() ran = ran + 1 end,
              when = function(h) return h.newest().pct <= 3 end },
        } }
        return q
    end

    -- M.snooze cancels the pending run
    local q1 = mk("s1")
    feed("s1", q1, { t = NOW, pct = 2 })
    local grace_t = TIMERS[#TIMERS]
    check(alertd.state("s1").em.pending == true, "grace run pending after fire")
    check(alertd.snooze("s1", "em", 300), "M.snooze finds the stage")
    check(grace_t.stopped, "snooze stops the grace timer")
    grace_t:emit()
    check(ran == 0, "snoozed grace run does not execute")
    check(alertd.state("s1").em.snoozed_until == NOW + 300,
          "M.state reports snoozed_until")

    -- notification action button takes the same path
    local q2 = mk("s2")
    feed("s2", q2, { t = NOW, pct = 2 })
    local n = NOTIFS[#NOTIFS]
    check(n.actions and n.actions[1] ~= nil, "action notif carries a button")
    n.actions[1]:invoke()
    check(TIMERS[#TIMERS].stopped, "Snooze button stops the grace timer")
    TIMERS[#TIMERS]:emit()
    check(ran == 0, "button-snoozed run does not execute")

    -- M.cancel kills the pending run without clearing fired state
    local q3 = mk("s3")
    feed("s3", q3, { t = NOW, pct = 2 })
    check(alertd.cancel("s3", "em"), "M.cancel on a pending stage")
    TIMERS[#TIMERS]:emit()
    check(ran == 0, "cancelled grace run does not execute")
    check(alertd.state("s3").em.fired == true, "cancel keeps fired state")

    -- no actions on the notification: no snooze path, run still proceeds
    local q4 = mk("s4")
    NO_ACTIONS = true
    feed("s4", q4, { t = NOW, pct = 2 })
    NO_ACTIONS = false
    check(#GUARD_ERRS == 0, "nil actions does not crash fire()")
    TIMERS[#TIMERS]:emit()
    check(ran == 1, "grace run still proceeds with no actions")
end

print("-- out-of-order samples")
reset()
do
    local q = {}
    alertd.metric { name = "ooo", source = queue_source(q) }
    feed("ooo", q, { t = 5000, pct = 50 })
    feed("ooo", q, { t = 4990, pct = 49 })
    feed("ooo", q, { t = 5000, pct = 48 })  -- equal t is fine
    local h = alertd.history("ooo")
    check(#h.samples == 2, "out-of-order sample rejected")
    check(h.newest().pct == 48, "non-decreasing sample accepted")
    check(log_contains("OOO ooo rejected t=4990"), "rejection journaled")
end

print("-- escalating renotify")
reset()
do
    local q = {}
    alertd.metric { name = "rn", source = queue_source(q) }
    alertd.rule { metric = "rn", id = "t", stages = {
        { name = "d", level = "warn", renotify = { 5, 2 },
          when = function() return true end },
    } }
    feed("rn", q, { t = NOW })                      -- fire 1
    NOW = NOW + 4; feed("rn", q, { t = NOW })
    check(sig_count("alertd::rn", "d") == 1, "no refire before rn[1]")
    NOW = NOW + 1; feed("rn", q, { t = NOW })       -- +5: refire 2
    check(sig_count("alertd::rn", "d") == 2, "refire after rn[1]=5")
    NOW = NOW + 1; feed("rn", q, { t = NOW })
    check(sig_count("alertd::rn", "d") == 2, "no refire before rn[2]")
    NOW = NOW + 1; feed("rn", q, { t = NOW })       -- +2: refire 3
    check(sig_count("alertd::rn", "d") == 3, "refire after rn[2]=2")
    NOW = NOW + 2; feed("rn", q, { t = NOW })       -- clamped to last entry
    check(sig_count("alertd::rn", "d") == 4, "subsequent refires clamp to last interval")
end

print("-- AC re-probe cadence")
reset()
do
    -- easy_async stub returns "" so mains_path never lands; first sample
    -- probes, calls within AC_REPROBE don't, calls after do
    local before = ASYNC_PROBES
    local q = {}
    alertd.metric { name = "acm", source = alertd.source.sysfs_battery("NONEXIST") }
    check(ASYNC_PROBES == before + 1, "first sample kicks off an AC probe")
    NOW = NOW + 60
    feed("acm", q, { t = NOW })
    check(ASYNC_PROBES == before + 1, "no re-probe inside the cadence window")
    check(log_contains("retrying"), "empty glob journaled")
    NOW = NOW + 301
    feed("acm", q, { t = NOW })
    check(ASYNC_PROBES == before + 2, "re-probe after AC_REPROBE seconds")
    -- and ac stays the documented tri-state nil until an adapter is found
    check(alertd.history("acm").newest().ac == nil, "ac is nil (unknown), not false")
end

print(("-- %d checks, %d failed"):format(test_n, failed))
os.exit(failed == 0 and 0 or 1)
