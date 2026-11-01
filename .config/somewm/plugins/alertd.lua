-- plugins/alertd.lua
-- Staged alerting framework. Watches metric *trends* instead of trusting
-- reported status — built after an HP firmware-managed discharge drained the
-- battery to zero while ACPI kept reporting "charging", so every state-gated
-- warning path (power.lua, UPower, every DE equivalent) was bypassed and the
-- machine hard-powered-off.
--
-- Concepts:
--   Metric  — a named sample source polled on a timer (and/or fed by events).
--             Samples are flat tables appended to a ring-buffer History.
--   Rule    — a set of Stages evaluated against a metric's History.
--   Stage   — { name, when(h), rearm_when(h), level, msg, run, grace, snooze,
--               renotify, cooldown }. Fires once per excursion; re-arms when
--             `rearm_when` goes false (defaults to `when` — set it looser for
--             hysteresis so a value oscillating across a threshold doesn't
--             re-notify every crossing). Levels: "info" | "warn" | "critical"
--             | "action". "action" runs `run` after `grace` seconds unless
--             snoozed or cancelled.
--
-- Stage field reference:
--   name        string, unique within the rule
--   title       notification title (default "alertd")
--   when(h)     predicate evaluated every sample while the stage is armed
--   rearm_when(h) optional predicate evaluated while the stage is fired; the
--               stage stays "in excursion" while it returns true and re-arms
--               (emitting "clear") when it goes false. Defaults to `when`.
--   level       "info" | "warn" | "critical" | "action"
--   msg         string, or msg(h) -> string
--   run         string (spawn.with_shell) or function; level "action" only,
--               executed after `grace` unless snoozed/cancelled
--   grace       seconds before `run` for level "action" (nil/0 = immediate)
--   snooze      seconds a snooze silences the stage (default 1800)
--   renotify    seconds between refires while the stage stays active, or a
--               table {600, 300, 120} of escalating intervals — the k-th
--               refire waits renotify[min(k, #t)], clamped to the last entry
--   cooldown    minimum seconds between fires even across a re-arm
--
-- Sample schema contract: a source returns a flat table of scalars; `t`
-- (epoch seconds) is filled in when absent. Keys are source-defined; the
-- journal line and the helpers below understand the battery convention
-- { t, pct, energy, status, ac } where `ac` is TRI-STATE:
--   true = mains online, false = on battery, nil = adapter not located yet
--   (exotic sysfs names are found by an async glob, re-probed every
--   AC_REPROBE seconds until found). Rules must treat nil as "unknown",
--   never as "on battery" — that is precisely the case drain_on_ac exists
--   for.
--
-- Samples key on os.time() (wall clock). push() REJECTS a sample whose t is
-- older than the newest sample (journaled as OOO) so windows stay monotonic.
-- A window spanning a suspend just yields a longer effective span — e.g. a
-- 20-min window crossing a 3-hour suspend still needs real post-resume
-- samples before draining() can fire. Deliberate: trend rules prefer
-- late-but-certain over early-but-wrong. The secs*0.6 coverage floor in
-- draining() means ~12-20 min from drain start to detection at a 60s
-- interval — that latency is the price of trend-based detection, not a bug.
--
-- Duplicate registration: M.metric replaces an existing metric of the same
-- name — the old timer is stopped and a fresh history started (journaled as
-- OVERWRITE). Re-registering is the supported way to swap a source; the old
-- timer must never keep feeding samples or the history forks.
--
-- History helpers available to when(h)/rearm_when(h)/msg(h):
--   h.newest()           latest sample table (nil if empty)
--   h:delta(field, secs) net change of field over the last `secs`
--   h:draining(field, secs, drop)
--                        true if field fell >= drop over `secs` and the last
--                        sample is still near the window low (no recovery)
--
-- Fired stages emit awesome.emit_signal("alertd::<metric>", stage, level);
-- re-arms emit level "clear" — widgets can recolour on anomalies. Events and
-- (optionally) every sample append to ~/.local/share/somewm/alertd.log so a
-- post-mortem is one file instead of three commands.
--
-- Programmatic control (somewm-client eval, widgets, TTY rescue):
--   M.snooze(metric, stage, secs)  silence a stage; cancels a pending run
--   M.cancel(metric, stage)        cancel a pending grace run without
--                                  clearing the fired state
--   M.state(metric)                { stage -> { fired, fired_at, pending,
--                                               snoozed_until } }
--
-- Example:
--   local alertd = require("plugins.alertd")
--   alertd.metric { name = "battery", interval = 60, journal = true,
--                   source = alertd.source.sysfs_battery("BAT0") }
--   alertd.rule { metric = "battery", id = "power", stages = {
--       { name = "low", level = "warn",
--         when = function(h) return h.newest().pct <= 15 end,
--         rearm_when = function(h) return h.newest().pct < 17 end },
--   }}

local awful   = require("awful")
local gears   = require("gears")
local naughty = require("naughty")
local guarded = require("error_guard")

local M = {}


-- MARK: CONFIG

local LOG_DIR  = (os.getenv("HOME") or "") .. "/.local/share/somewm"
local LOG_FILE = LOG_DIR .. "/alertd.log"
local LOG_MAX  = 1024 * 1024    -- rotate to .1 past this size

local SOURCE_MAX_ERRS = 5    -- consecutive source() failures before disable
local AC_REPROBE      = 300  -- seconds between Mains adapter re-probes

local URGENCY = {
    info     = "low",
    warn     = "normal",
    critical = "critical",
    action   = "critical",
}

local metrics = {}   -- name -> { interval, window, journal, source, hist, timer }
local rules   = {}   -- array of { id, metric, stages }


-- MARK: JOURNAL

local function journal(line)
    local f = io.open(LOG_FILE, "r")
    if f then
        local sz = f:seek("end")
        f:close()
        if sz and sz > LOG_MAX then os.rename(LOG_FILE, LOG_FILE .. ".1") end
    end
    f = io.open(LOG_FILE, "a")
    if not f then return end
    f:write(os.date("%Y-%m-%d %H:%M:%S") .. " " .. line .. "\n")
    f:close()
end

local function journal_sample(name, s)
    local parts = {}
    for _, k in ipairs({ "pct", "energy", "status", "ac" }) do
        local v = s[k]
        if v ~= nil then parts[#parts + 1] = k .. "=" .. tostring(v) end
    end
    -- any extra numeric fields not covered above
    for k, v in pairs(s) do
        if k ~= "t" and k ~= "pct" and k ~= "energy" and k ~= "status" and k ~= "ac"
           and type(v) == "number" then
            parts[#parts + 1] = k .. "=" .. tostring(v)
        end
    end
    journal("S " .. name .. " " .. table.concat(parts, " "))
end


-- MARK: HISTORY

local history_mt = {}
history_mt.__index = history_mt

local function new_history(window)
    local h = setmetatable({ samples = {}, window = window or 3600 }, history_mt)
    -- bound as a plain function so rule authors can write h.newest()
    h.newest = function() return h.samples[#h.samples] end
    return h
end

-- Append a sample. Samples must be non-decreasing in t; a sample older than
-- the newest is rejected (returns false) rather than silently forking the
-- window ordering that in_window/draining rely on.
function history_mt:push(s)
    local last = self.samples[#self.samples]
    if last and s.t < last.t then return false end
    self.samples[#self.samples + 1] = s
    local cutoff = s.t - self.window
    while self.samples[1] and self.samples[1].t < cutoff do
        table.remove(self.samples, 1)
    end
    return true
end

function history_mt:in_window(secs)
    local out = {}
    local last = self.samples[#self.samples]
    local cutoff = (last and last.t or os.time()) - secs
    for _, s in ipairs(self.samples) do
        if s.t >= cutoff then out[#out + 1] = s end
    end
    return out
end

function history_mt:delta(field, secs)
    local w = self:in_window(secs)
    if #w < 2 then return 0 end
    return (w[#w][field] or 0) - (w[1][field] or 0), w[#w].t - w[1].t
end

-- Net drop of `field` >= `drop` over `secs`, with the newest sample still at
-- the window low (a bounce-back to rising = not draining). Needs the window
-- to be reasonably covered so a lone stale pair can't trip it.
function history_mt:draining(field, secs, drop)
    local w = self:in_window(secs)
    if #w < 2 then return false end
    local first, last = w[1], w[#w]
    if last.t - first.t < secs * 0.6 then return false end
    if (first[field] or 0) - (last[field] or 0) < drop then return false end
    local low = math.huge
    for _, s in ipairs(w) do low = math.min(low, s[field] or 0) end
    return (last[field] or 0) - low <= math.max(1, drop * 0.25)
end


-- MARK: NOTIFICATIONS / ACTIONS

local function notify(st, text)
    local urgency = URGENCY[st.level] or "normal"
    local n = naughty.notification {
        title    = st.title or "alertd",
        message  = text,
        urgency  = urgency,
        app_name = "alertd",
        timeout  = (urgency == "critical") and 0 or 8,
    }
    return n
end

local function run_stage(st)
    if type(st.run) == "string" then
        awful.spawn.with_shell(st.run)
    elseif type(st.run) == "function" then
        guarded(st.run)()
    end
end

-- Shared by the notification Snooze button and M.snooze: silences the stage
-- and cancels any pending grace run.
local function snooze_stage(rule, st, secs)
    st._snoozed_until = os.time() + (secs or st.snooze or 1800)
    st._pending = false
    if st._timer then st._timer:stop() end
    journal(("SNOOZE %s.%s until %s"):format(rule.metric, st.name,
        os.date("%H:%M:%S", st._snoozed_until)))
end

-- renotify may be a number (fixed interval) or a table of escalating
-- intervals; _fires counts notifications so the k-th refire waits
-- renotify[min(k, #t)].
local function renotify_interval(st)
    local rn = st.renotify
    if type(rn) == "table" then
        return rn[math.min(st._fires or 1, #rn)]
    end
    return rn
end

local function can_fire(st, now)
    if st._snoozed_until and now < st._snoozed_until then return false end
    if st.cooldown and st._fired_at and now - st._fired_at < st.cooldown then
        return false
    end
    if not st._fired then return true end
    local rn = renotify_interval(st)
    if rn and now - st._fired_at >= rn then return true end
    return false
end

local function fire(rule, st, h)
    local now = os.time()
    st._fired = true
    st._fired_at = now
    st._fires = (st._fires or 0) + 1
    local msg = type(st.msg) == "function" and guarded(st.msg)(h) or st.msg
    journal(("FIRE %s.%s level=%s %s"):format(rule.metric, st.name, st.level, msg or ""))
    awesome.emit_signal("alertd::" .. rule.metric, st.name, st.level, h.newest())

    if st.level == "action" and st.grace and st.grace > 0 then
        -- countdown notification with a cancel affordance; the pending timer
        -- is cancelled if the stage re-arms or the user snoozes
        st._pending = true
        local n = naughty.notification {
            title    = st.title or "alertd",
            message  = (msg or "") .. (" — acting in %ds"):format(st.grace),
            urgency  = "critical",
            app_name = "alertd",
            timeout  = 0,
            actions  = {
                naughty.action {
                    name = "Snooze",
                },
            },
        }
        -- a deduped/disabled/destroyed notification may carry no actions;
        -- no button means no snooze affordance — the grace run still proceeds
        local act = n and n.actions and n.actions[1]
        if act then
            act:connect_signal("invoked", guarded(function()
                snooze_stage(rule, st)
            end))
        end
        st._timer = gears.timer {
            timeout     = st.grace,
            single_shot = true,
            autostart   = true,
            callback    = guarded(function()
                if st._pending then run_stage(st) end
            end),
        }
    else
        notify(st, msg or "")
        if st.level == "action" then run_stage(st) end
    end
end

local function eval_rule(rule, h)
    for _, st in ipairs(rule.stages) do
        -- while fired, rearm_when (default: when) decides whether the
        -- excursion continues — a looser rearm threshold gives hysteresis
        local pred = st._fired and (st.rearm_when or st.when) or st.when
        local ok, active = pcall(pred, h)
        if not ok then
            -- a broken predicate must not silently never fire (or re-arm)
            journal(("ERR %s.%s when(): %s"):format(rule.metric, st.name, tostring(active)))
            if gears.debug and gears.debug.print_error then
                gears.debug.print_error(("alertd %s.%s when(): %s")
                    :format(rule.metric, st.name, tostring(active)))
            end
            active = false
        end
        if ok and active then
            if can_fire(st, os.time()) then fire(rule, st, h) end
        else
            if st._fired then
                awesome.emit_signal("alertd::" .. rule.metric, st.name, "clear")
            end
            st._fired = false
            st._fires = nil
            st._pending = false
        end
    end
end


-- MARK: SOURCES

local function read_file(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local s = f:read("*l")
    f:close()
    return s
end

local function read_num(path)
    return tonumber(read_file(path))
end

-- No io.popen in somewm: probe the common Mains names synchronously, and if
-- none match, kick off an async directory listing via easy_async (returns
-- nil for "unknown" until it lands — tri-state, rules treat nil as "not
-- confirmed on AC"). If the glob also comes back empty (exotic adapter name,
-- or sysfs not populated yet), re-probe every AC_REPROBE seconds until found
-- — a one-shot miss used to leave ac=nil forever and disarm drain_on_ac.
local mains_path, last_probe
local function ac_online()
    if not mains_path then
        local now = os.time()
        if last_probe and now - last_probe < AC_REPROBE then return nil end
        local first = not last_probe
        last_probe = now
        for _, name in ipairs({ "AC", "AC0", "AC1", "ACAD", "ADP0", "ADP1",
                                "acpi_acad", "ac", "Mains" }) do
            local p = "/sys/class/power_supply/" .. name
            if read_file(p .. "/type") == "Mains" then
                mains_path = p
                break
            end
        end
        if not mains_path then
            if first then
                journal("AC no common Mains name matched; probing via glob")
            end
            awful.spawn.easy_async(
                "for d in /sys/class/power_supply/*/; do " ..
                "[ \"$(cat $d/type 2>/dev/null)\" = Mains ] && echo $d; done | head -1",
                guarded(function(out)
                    local p = (out or ""):gmatch("[^\r\n]+")()
                    if p and p ~= "" then
                        mains_path = p
                    else
                        journal("AC glob found no Mains adapter; retrying in "
                            .. AC_REPROBE .. "s")
                    end
                end))
        end
    end
    if not mains_path then return nil end
    return read_num(mains_path .. "/online") == 1
end

M.source = {}

-- /sys/class/power_supply sampler: pct, energy (uWh/uAh raw), status, ac.
-- No name: probe the usual battery names (same policy as battery_popup).
function M.source.sysfs_battery(name)
    local bat
    if name then
        bat = "/sys/class/power_supply/" .. name
    else
        for _, n in ipairs({ "BAT0", "BAT1", "BATT", "BAT" }) do
            local p = "/sys/class/power_supply/" .. n
            if gears.filesystem.file_readable(p .. "/capacity") then
                bat = p
                break
            end
        end
        bat = bat or "/sys/class/power_supply/BAT0"  -- legacy fallback
    end
    return function()
        return {
            t      = os.time(),
            pct    = read_num(bat .. "/capacity"),
            energy = read_num(bat .. "/energy_now") or read_num(bat .. "/charge_now"),
            status = read_file(bat .. "/status"),
            ac     = ac_online(),
        }
    end
end


-- MARK: API

-- Register a sample source. `source` is a function returning a flat table;
-- `interval` polls it, `sample_now(name)` lets event streams push a sample
-- early (e.g. upower --monitor-detail callbacks). Re-registering an existing
-- name stops the old timer and resets the history — the old timer must not
-- keep feeding samples or the history forks.
function M.metric(spec)
    local old = metrics[spec.name]
    if old then
        if old.timer then old.timer:stop() end
        journal(("OVERWRITE %s re-registered; old timer stopped, history reset")
            :format(spec.name))
    end
    local m = {
        name     = spec.name,
        interval = spec.interval or 60,
        window   = spec.window or 3600,
        journal  = spec.journal,
        source   = spec.source,
        hist     = new_history(spec.window),
    }
    metrics[m.name] = m
    m.timer = gears.timer {
        timeout   = m.interval,
        autostart = true,
        callback  = guarded(function() M.sample_now(m.name) end),
    }
    M.sample_now(m.name)
    return m
end

function M.sample_now(name)
    local m = metrics[name]
    if not m or not m.source then return end
    -- a source may be called from arbitrary contexts (incl. event callbacks);
    -- it must never propagate. Consecutive failures beyond SOURCE_MAX_ERRS
    -- disable the metric rather than spamming the journal forever.
    local ok, s = pcall(m.source)
    if not ok then
        m._src_errs = (m._src_errs or 0) + 1
        journal(("ERR %s source(): %s (consecutive=%d)")
            :format(name, tostring(s), m._src_errs))
        if m._src_errs >= SOURCE_MAX_ERRS then
            journal(("ERR %s source disabled after %d consecutive failures")
                :format(name, m._src_errs))
            if m.timer then m.timer:stop() end
            m.source = nil
        end
        return
    end
    m._src_errs = 0
    if not s then return end
    s.t = s.t or os.time()
    if not m.hist:push(s) then
        journal(("OOO %s rejected t=%d (newest=%d)")
            :format(name, s.t, m.hist.newest() and m.hist.newest().t or -1))
        return
    end
    if m.journal then journal_sample(name, s) end
    for _, r in ipairs(rules) do
        if r.metric == name then eval_rule(r, m.hist) end
    end
end

-- spec: { metric = "name", id = "consumer", stages = { ... } }
function M.rule(spec)
    rules[#rules + 1] = spec
end

-- Drop all rules registered under an id (consumers reloading cleanly)
function M.unregister(id)
    for i = #rules, 1, -1 do
        if rules[i].id == id then table.remove(rules, i) end
    end
end

local function find_stage(metric, stage)
    for _, r in ipairs(rules) do
        if r.metric == metric then
            for _, st in ipairs(r.stages) do
                if st.name == stage then return r, st end
            end
        end
    end
end

-- Silence a stage for `secs` (default: its snooze field, else 1800); cancels
-- a pending grace run. Same code path as the notification Snooze button.
function M.snooze(metric, stage, secs)
    local r, st = find_stage(metric, stage)
    if not st then return false end
    snooze_stage(r, st, secs)
    return true
end

-- Cancel a pending grace run (e.g. head off an emergency suspend from a TTY
-- via somewm-client eval) without clearing the fired state.
function M.cancel(metric, stage)
    local _, st = find_stage(metric, stage)
    if not st or not st._pending then return false end
    st._pending = false
    if st._timer then st._timer:stop() end
    journal(("CANCEL %s.%s pending run cancelled"):format(metric, stage))
    return true
end

-- Stage states for a metric: { name -> { fired, fired_at, pending,
-- snoozed_until } } — for widget display and poking from somewm-client eval.
function M.state(metric)
    local out = {}
    for _, r in ipairs(rules) do
        if r.metric == metric then
            for _, st in ipairs(r.stages) do
                out[st.name] = {
                    fired         = st._fired or false,
                    fired_at      = st._fired_at,
                    pending       = st._pending or false,
                    snoozed_until = st._snoozed_until,
                }
            end
        end
    end
    return out
end

function M.history(name)
    return metrics[name] and metrics[name].hist or nil
end

function M.stop()
    for _, m in pairs(metrics) do
        if m.timer then m.timer:stop() end
    end
    metrics = {}
    rules = {}
end

gears.filesystem.make_parent_directories(LOG_FILE)
awesome.connect_signal("exit", guarded(M.stop))

return M
