-- plugins/solo_super.lua
-- Tap Super on its own to toggle a launcher, without a keygrabber.
--
-- Why no keygrabber: in somewm the C-level keygrabber ignores the callback's
-- return value (some_keygrabber_handle_key does lua_pcall(L, 3, 0, 0) and
-- returns true), so while any keygrabber is running every key press and
-- release is swallowed before it reaches keybindings or clients. A grabber
-- that is meant to "pass through" therefore locks the keyboard instead.
-- There is also only one grabber slot, so anything else that calls
-- keygrabber.run/stop (bling, collision, awful.keygrabber) fights over it.
--
-- How it works instead:
--   * awful.key on Super_L press arms the tap and starts a hold timer.
--   * awful.key on Super_L release fires the launcher if the tap is still
--     armed. The compositor updates xkb state after emitting the key event,
--     so the press arrives with no modifiers and the release with Mod4 set;
--     both variants are bound to be safe either way.
--   * key.connect_signal("press") is a class-level signal that fires for
--     every bound key, so any chord (Super+Z, ...) disarms the tap.
--   * client button presses and the hold timer also disarm it.
--
-- The launcher command is a shell toggle, so tapping Super while the
-- launcher is already open closes it again.

local awful = require("awful")
local gears = require("gears")
local guarded = require("error_guard")

local M = {}

local state = { armed = false }

local function disarm()
    state.armed = false
end

--- Build the Super_L key objects.
-- @tparam table opts
-- @tparam string opts.modkey Modifier name for Super ("Mod4").
-- @tparam string opts.launcher Command to launch.
-- @tparam[opt] string opts.process Process name for pkill/pgrep toggle; nil disables the close-on-tap.
-- @tparam[opt=0.6] number opts.hold Seconds after which a held Super no longer counts as a tap.
-- @treturn table List of awful.key objects to append to the global keybindings.
function M.keys(opts)
    local modkey = opts.modkey or "Mod4"
    local cmd = opts.launcher
    if opts.process then
        cmd = string.format("pgrep -x %s >/dev/null && pkill -x %s || %s", opts.process, opts.process, cmd)
    end

    local hold_timer = gears.timer {
        timeout = opts.hold or 0.6,
        single_shot = true,
        callback = guarded(disarm),
    }

    local function on_press()
        state.armed = true
        hold_timer:again()
    end

    local function on_release()
        hold_timer:stop()
        if state.armed then
            awful.spawn.with_shell(cmd, false)
        end
        disarm()
    end

    -- any other bound key while Super is held makes it a chord, not a tap
    key.connect_signal("press", guarded(function(k)
        if state.armed and k.key ~= "Super_L" then disarm() end
    end))
    client.connect_signal("button::press", guarded(disarm))

    local desc = { description = "launcher (tap Super alone)", group = "launcher" }
    return {
        awful.key({}, "Super_L", guarded(on_press), guarded(on_release), desc),
        awful.key({ modkey }, "Super_L", guarded(on_press), guarded(on_release)),
    }
end

return M
