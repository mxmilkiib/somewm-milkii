-- startup_profiler.lua
-- Performance profiling for somewm startup to identify blocking operations.
--
-- Install as early as possible in rc.lua, before the library requires:
--     local profiler = require("rc.startup_profiler")
--     profiler.install()
--
-- install() times every require() call, io.popen/os.execute, and the
-- awful.spawn* family, then arms an event-loop watchdog (repeating-timer
-- lateness == main-loop stall, the same thing somewm's "Last iteration took"
-- warning measures, but without the ratcheting limit hiding smaller stalls).
-- Reports print on the "startup" signal and at fixed marks so hot-reloads
-- (which re-run rc.lua without a startup signal) still produce one.
-- Output goes to stderr (journal) and appends to /tmp/somewm-startup-profile.log.
--
-- Manual sections remain available:
--     profiler.start("name") / profiler.stop()
--     profiler.measure("name", function() ... end)
--     profiler.report()  -- on demand

local M = {}

-- Wall-clock source: os.clock() measures CPU time only, which misses the I/O
-- and fork waits that actually stall the compositor, so prefer GLib monotonic.
local now, glib
do
    local ok, lgi = pcall(require, "lgi")
    if ok and lgi and lgi.GLib and lgi.GLib.get_monotonic_time then
        glib = lgi.GLib
        now = function() return glib.get_monotonic_time() / 1e6 end
    else
        now = os.clock
    end
end

local pack = table.pack or function(...) return { n = select("#", ...), ... } end
local unpack_ = table.unpack or unpack

local t_init = now()

local open_section = nil
local sections = {}   -- {name, at, dt}
local req_log = {}    -- {name, at, dt, depth}
local req_depth = 0
local blockers = {}   -- {kind, detail, at, dt}
local stalls = {}     -- {at, dt}
local out = {}        -- report lines pending file flush

local SLOW_REQ = 0.050   -- live-log requires slower than this
local SLOW_CALL = 0.020  -- live-log blocking calls slower than this
local STALL_MIN = 0.150  -- watchdog reports lateness beyond this
local WATCHDOG_S = 0.05
local GAP_MIN = 0.030    -- report top-level gaps between requires beyond this
local LOG_PATH = "/tmp/somewm-startup-profile.log"

local function emit(fmt, ...)
    local s = string.format("[PROFILE] " .. fmt, ...)
    out[#out + 1] = s
    io.stderr:write(s, "\n")
    io.stderr:flush()
end

local function flush_log()
    if #out == 0 then return end
    local f = io.open(LOG_PATH, "a")
    if f then
        f:write(table.concat(out, "\n"), "\n")
        f:close()
    end
    out = {}
end

local function record(kind, detail, t0, dt)
    blockers[#blockers + 1] = { kind = kind, detail = detail, at = t0 - t_init, dt = dt }
    if dt > SLOW_CALL then
        emit("%s %s took %.1fms (at %.3fs)", kind, detail, dt * 1000, t0 - t_init)
    end
end

-- time a spawn-family call; errors propagate unrecorded
local function time_spawn(key, orig, cmd, ...)
    local t0 = now()
    local r = pack(orig(cmd, ...))
    record("awful.spawn." .. key, tostring(cmd), t0, now() - t0)
    return unpack_(r, 1, r.n)
end

local spawn_wrapped = false
local function wrap_spawn(mod)
    -- awful.spawn is a callable table; wrapping its fields covers both
    -- awful.spawn(cmd) (via __call -> spawn.spawn) and the named methods
    if spawn_wrapped or type(mod) ~= "table" or type(mod.spawn) ~= "table" then return end
    spawn_wrapped = true
    for _, key in ipairs({ "spawn", "with_shell", "easy_async", "easy_async_with_shell" }) do
        local orig = mod.spawn[key]
        if type(orig) == "function" then
            mod.spawn[key] = function(cmd, ...) return time_spawn(key, orig, cmd, ...) end
        end
    end
end

-- wrap require so every module load is timed, including nested loads
local real_require = require
function M.install_require_tracer()
    rawset(_G, "require", function(name)
        local t0 = now()
        req_depth = req_depth + 1
        local r = pack(pcall(real_require, name))
        req_depth = req_depth - 1
        local dt = now() - t0
        req_log[#req_log + 1] = { name = tostring(name), at = t0 - t_init, dt = dt, depth = req_depth }
        if dt > SLOW_REQ then
            emit("require %s took %.1fms (at %.3fs)", name, dt * 1000, t0 - t_init)
        end
        if r[1] then
            if name == "awful" then wrap_spawn(r[2]) end
            return unpack_(r, 2, r.n)
        end
        error(r[2], 0)
    end)
end

-- wrap the synchronous stdlib calls; popen timing covers the fork only,
-- a slow read() shows up in the gap analysis / watchdog instead
local function wrap_blocking()
    local real_popen = io.popen
    io.popen = function(cmd, mode)
        local t0 = now()
        local h = real_popen(cmd, mode)
        record("io.popen", tostring(cmd), t0, now() - t0)
        return h
    end
    local real_execute = os.execute
    os.execute = function(cmd, ...)
        local t0 = now()
        local r = pack(real_execute(cmd, ...))
        record("os.execute", tostring(cmd), t0, now() - t0)
        return unpack_(r, 1, r.n)
    end
end

-- repeating-timer lateness == main-loop stall; glib preferred (same context
-- somewm iterates), gears.timer fallback re-arms one-shots
local function arm_watchdog()
    local last = now()
    local function tick()
        local t = now()
        local late = t - last - WATCHDOG_S
        last = t
        if late > STALL_MIN then
            stalls[#stalls + 1] = { at = t - t_init, dt = late }
            emit("STALL main loop unresponsive %.0fms (at %.3fs)", late * 1000, t - t_init)
            flush_log()
        end
        return true
    end
    if glib and glib.timeout_add then
        glib.timeout_add(glib.PRIORITY_DEFAULT, WATCHDOG_S * 1000, tick)
        return
    end
    local ok, gears = pcall(real_require, "gears")
    if not (ok and gears and gears.timer) then return end
    local function arm()
        gears.timer.start_new(WATCHDOG_S, function()
            tick()
            arm()
            return false
        end)
    end
    arm()
end

-- start timing a named section
function M.start(section_name)
    open_section = { name = section_name, t0 = now() }
end

-- end timing the open section
function M.stop()
    if not open_section then return end
    local dt = now() - open_section.t0
    open_section.dt = dt
    open_section.at = open_section.t0 - t_init
    sections[#sections + 1] = open_section
    if dt > SLOW_REQ then
        emit("section %s took %.1fms (at %.3fs)", open_section.name, dt * 1000, open_section.at)
    end
    open_section = nil
end

-- measure a function execution
function M.measure(name, func)
    M.start(name)
    local r = pack(pcall(func))
    M.stop()
    if not r[1] then error(r[2], 0) end
    return unpack_(r, 2, r.n)
end

-- print + log a report; tag identifies which mark triggered it
function M.report(tag)
    local t_now = now()
    emit("=== STARTUP PROFILE: %s (%.3fs since config start, epoch %d) ===",
         tag or "manual", t_now - t_init, os.time())

    -- slowest module loads, inclusive of nested requires
    local sorted = {}
    local n_slow = 0
    for _, r in ipairs(req_log) do
        sorted[#sorted + 1] = r
        if r.dt > SLOW_REQ then n_slow = n_slow + 1 end
    end
    table.sort(sorted, function(a, b) return a.dt > b.dt end)
    emit("require: %d loads, %d over %.0fms; slowest (incl. nested):",
         #req_log, n_slow, SLOW_REQ * 1000)
    for i = 1, math.min(15, #sorted) do
        local r = sorted[i]
        emit("  %8.1fms %-44s depth=%d at %.3fs", r.dt * 1000, r.name, r.depth, r.at)
    end

    -- gaps between top-level requires = rc.lua body code running
    local top = {}
    for _, r in ipairs(req_log) do
        if r.depth == 0 then top[#top + 1] = r end
    end
    table.sort(top, function(a, b) return a.at < b.at end)
    emit("gaps over %.0fms between top-level requires (rc.lua body code):", GAP_MIN * 1000)
    local prev_end = 0
    local n_gaps = 0
    for _, r in ipairs(top) do
        local gap = r.at - prev_end
        if gap > GAP_MIN then
            n_gaps = n_gaps + 1
            emit("  %8.1fms  at %.3fs, before require %s", gap * 1000, r.at, r.name)
        end
        prev_end = math.max(prev_end, r.at + r.dt)
    end
    local tail = (t_now - t_init) - prev_end
    if tail > GAP_MIN then
        n_gaps = n_gaps + 1
        emit("  %8.1fms  at %.3fs, trailing code after last require", tail * 1000, prev_end)
    end
    if n_gaps == 0 then emit("  (none)") end

    -- blocking calls
    if #blockers > 0 then
        table.sort(blockers, function(a, b) return a.dt > b.dt end)
        emit("blocking calls: %d total; slowest:", #blockers)
        for i = 1, math.min(15, #blockers) do
            local b = blockers[i]
            emit("  %8.1fms %-28s at %.3fs  %s", b.dt * 1000, b.kind, b.at, b.detail or "")
        end
    else
        emit("blocking calls: none recorded")
    end

    -- manual sections
    for _, s in ipairs(sections) do
        emit("section %-30s %8.1fms at %.3fs", s.name, s.dt * 1000, s.at)
    end

    -- event-loop stalls seen by the watchdog
    if #stalls > 0 then
        local worst = 0
        for _, s in ipairs(stalls) do worst = math.max(worst, s.dt) end
        emit("event-loop stalls: %d over %.0fms, worst %.0fms:", #stalls, STALL_MIN * 1000, worst * 1000)
        table.sort(stalls, function(a, b) return a.dt > b.dt end)
        for i = 1, math.min(10, #stalls) do
            emit("  %8.1fms  at %.3fs", stalls[i].dt * 1000, stalls[i].at)
        end
    else
        emit("event-loop stalls: none over %.0fms", STALL_MIN * 1000)
    end

    emit("lua heap %.1fMB", collectgarbage("count") / 1024)
    emit("=== END PROFILE %s ===", tag or "manual")
    flush_log()
end

function M.install()
    if M._installed then return M end
    M._installed = true

    emit("installed (clock=%s, epoch %d)", glib and "glib-monotonic" or "os.clock-cpu", os.time())
    M.install_require_tracer()
    wrap_blocking()
    arm_watchdog()

    if awesome and awesome.connect_signal then
        awesome.connect_signal("startup", function() M.report("startup") end)
    end

    -- fixed marks so hot-reloads (no startup signal) still produce reports
    local ok, gears = pcall(real_require, "gears")
    if ok and gears and gears.timer then
        for _, delay in ipairs({ 3, 30 }) do
            gears.timer.start_new(delay, function()
                M.report("t+" .. delay .. "s")
                return false
            end)
        end
    end

    flush_log()
    return M
end

return M
