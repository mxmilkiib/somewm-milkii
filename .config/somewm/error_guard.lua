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

local function guarded(fn)
    if not fn then return nil end
    return function(...)
        return gpcall(fn, ...)
    end
end

return guarded
