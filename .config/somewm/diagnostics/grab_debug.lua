-- plugins/grab_debug.lua
-- TEMPORARY DIAGNOSTIC for the cursor-capture hunt: logs every mousegrabber
-- transition with an attribution tag, so a frozen pointer can be traced back
-- to whichever module grabbed it (or ruled out as compositor-side when the
-- log shows no grab at all). Remove this module and the gd.* call sites once
-- the mystery is solved.
--
-- Attribution model: mousegrabber.run is wrapped below so every grab logs a
-- START event naming its owner - a gd.claim("tag") made immediately before
-- the call wins the semantic tag, otherwise the caller's file:line is used.
-- START/STOP at the call boundary also catch micro-grabs shorter than one
-- poll window, which the poller alone would miss entirely.
--
-- Log: ~/.local/state/somewm/grab-debug.log (append), also mirrored into the
-- somewm log via print.

local gears = require("gears")

local M = { enabled = true }

local LOG_PATH = (os.getenv("XDG_STATE_HOME") or (os.getenv("HOME") .. "/.local/state"))
    .. "/somewm/grab-debug.log"

local last_claim = nil      -- tag set by the most recent gd.claim()
local running = false       -- last observed C-side grab state
local active_since = nil    -- os.time() when the current grab went active
local active_by = nil       -- claim attribution for the current grab

local function stamp()
    return os.date("%H:%M:%S")
end

--- Append a line to the diagnostic log.
-- @param msg string
function M.event(tag, msg)
    if not M.enabled then return end
    local line = string.format("%s [%-22s] %s", stamp(), tag, msg)
    local h = io.open(LOG_PATH, "a")
    if h then h:write(line .. "\n") h:close() end
    print("grab-debug: " .. line)
end

--- Attribute the grab that is about to start. Call immediately before
--- mousegrabber.run() or awful.mouse.client.move/resize.
-- @param tag string identifying the call site
function M.claim(tag)
    last_claim = tag
end

-- warn when a grab outlives any reasonable drag: a stuck grab routes all
-- pointer input into its callback and eats every app click. log-only - the
-- per-site watchdogs do the actual force-stopping
local stuck_warn = gears.timer {
    timeout = 10,
    single_shot = true,
    callback = function()
        if M.enabled and mousegrabber.isrunning and mousegrabber.isrunning() then
            M.event("grab", "STUCK >10s (owner " .. tostring(active_by) .. ")")
        end
    end,
}

-- resolve an attribution tag for an unclaimed .run call: the caller's
-- file:line, one stack frame above the wrapped function
local function caller_tag()
    local info = debug.getinfo(3, "Sl")
    if not info then return "unknown" end
    return string.format("%s:%d", info.short_src or info.source or "?",
        info.currentline or 0)
end

-- wrap run/stop with rawset (the capi table's __newindex would block plain
-- assignment). callers look up .run/.stop at call time, so the wrap covers
-- every site that grabbed the table before this file loaded
local real_run = mousegrabber.run
local real_stop = mousegrabber.stop

local function wrapped_run(func, cursor)
    local tag = last_claim or caller_tag()
    last_claim = nil
    local ok, err = pcall(real_run, func, cursor)
    if not ok then
        M.event("grab", "FAILED START via " .. tag .. ": " .. tostring(err))
        error(err, 0)
    end
    active_by = tag
    active_since = os.time()
    M.event("grab", "START via " .. tag)
    stuck_warn:again()
end

local function wrapped_stop(...)
    if M.enabled and mousegrabber.isrunning and mousegrabber.isrunning() then
        M.event("grab", "STOP (was " .. tostring(active_by) .. ")")
    end
    return real_stop(...)
end

rawset(mousegrabber, "run", wrapped_run)
rawset(mousegrabber, "stop", wrapped_stop)

-- watch the C-side grab slot itself so transitions are caught regardless of
-- who started them; 250ms is cheap (isrunning is a flag read) and tight
-- enough to nail down duration
local poll = gears.timer {
    timeout = 0.25,
    single_shot = false,
    callback = function()
        if not M.enabled then return end
        local now = mousegrabber.isrunning and mousegrabber.isrunning() or false
        if now and not running then
            -- the run wrapper already stamped owner/start time for grabs it
            -- saw; only synthesize values for a grab it never observed
            active_since = active_since or os.time()
            active_by = active_by or last_claim
                or "UNCLAIMED (grab not via mousegrabber.run)"
            last_claim = nil
            M.event("grab", "ACTIVE via " .. active_by)
        elseif not now and running then
            local dur = active_since and (os.time() - active_since) or -1
            M.event("grab", string.format("RELEASED after ~%ds (was %s)", dur, tostring(active_by)))
            active_since = nil
            active_by = nil
        end
        running = now
    end,
}
poll:start()

M.event("init", "grab_debug armed, log at " .. LOG_PATH)

return M
