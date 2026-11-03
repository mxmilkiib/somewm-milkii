-- Per-handler protected-call wrapper for capturing tracebacks on errors that
-- would otherwise hit luaA_panic (which prints only the message, no traceback,
-- and tears down the WM). Wrap any callback handed to connect_signal / buttons
-- / timers / delayed_call with guarded(fn); errors are logged with a full
-- debug.traceback via gears.debug instead of crashing the session.
--
-- Usage:
--   local guarded = require("error_guard")
--   client.connect_signal("property::name", guarded(function(c) ... end))
--
-- Returns nil on error so callers can treat a failed handler as a no-op.

local gpcall = require("gears.protected_call")

-- stall probe prints only when SOMEWM_STALL is set
local stall_enabled = os.getenv("SOMEWM_STALL") == "1"

local function guarded(fn)
    if not fn then return nil end
    -- stall probe: capture the wrapped handler's definition site once so a
    -- slow call can name it (SIGSTALL only sees this wrapper's own line)
    local info = debug.getinfo(fn, "S")
    local site = string.format("%s:%d", info.short_src or "?", info.linedefined or -1)
    return function(...)
        if not stall_enabled then
            return gpcall(fn, ...)
        end
        local t0 = os.clock()
        -- stall probe, part 2: a count hook snapshots the running stack once
        -- the call crosses the threshold while still running, so the slow
        -- inner call names itself. For a slow C call it fires on the next
        -- Lua instruction after it returns, naming the line that called it.
        -- Note: os.clock is CPU time, so pure wall-blocked calls slip by.
        local stack
        local function hook()
            if stack or (os.clock() - t0) * 1000 <= 100 then return end
            local parts, lvl = {}, 2
            while #parts < 12 do
                local fi = debug.getinfo(lvl, "nSl")
                if not fi then break end
                parts[#parts + 1] = string.format("%s@%s:%d",
                    fi.name or "?", fi.short_src or "?", fi.currentline or -1)
                lvl = lvl + 1
            end
            stack = table.concat(parts, " <- ")
        end
        local oh, om, oc = debug.gethook()
        debug.sethook(hook, "", 5000)
        local r = gpcall(fn, ...)
        -- gethook returns "external hook" for C-set hooks (SIGSTALL probe);
        -- only a function can be handed back
        if type(oh) == "function" then
            debug.sethook(oh, om, oc)
        else
            debug.sethook()
        end
        local ms = (os.clock() - t0) * 1000
        if ms > 100 then
            io.stderr:write(string.format("GUARDSTALL %s=%.0fms stack: %s\n",
                site, ms, stack or "?"))
        end
        return r
    end
end

return guarded
