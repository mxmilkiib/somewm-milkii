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
--   * awful.key on Super_L press arms the tap and starts a hold timer. Only
--     the initial press arms; keyboard-repeat events are ignored, otherwise
--     they would reset the hold timer forever and a held Super would never
--     disarm (so the launcher would fire on release and interrupt any
--     Super+drag in progress).
--   * awful.key on Super_L release fires the launcher if the tap is still
--     armed. The compositor updates xkb state after emitting the key event,
--     so the press arrives with no modifiers and the release with Mod4 set;
--     both variants are bound to be safe either way.
--   * M.disarm() is wired directly onto the "press" signal of every real
--     keybinding's underlying key object (see M.watch below), so any chord
--     (Super+Z, ...) disarms the tap.
--   * client button presses and the hold timer also disarm it.
--
-- old: relied on `key.connect_signal("press", ...)`, the class-level signal
--      on the "key" capi class, on the theory that it fires for every bound
--      key regardless of which specific key object triggered it. In
--      practice the launcher kept popping up after ordinary chorded binds
--      (Mod4+j, Mod4+Shift+..., etc.) - the tap was never getting disarmed.
--      Rather than keep guessing at the class-signal semantics, M.watch
--      below hooks disarm onto the exact same per-instance "press" signal
--      that already reliably drives every keybinding's own action, so it
--      cannot silently fail to fire.
--
-- The launcher command is a shell toggle, so tapping Super while the
-- launcher is already open closes it again.

local awful = require("awful")
local gears = require("gears")
local guarded = require("error_guard")
local naughty = require("naughty")
local GLib = require("lgi").GLib

local M = {}

-- TEMPORARY DIAGNOSTIC: remove once chord-disarm is confirmed working.
local DEBUG = false

local state = { armed = false, pressed = false }

-- module-level so repeated M.keys() calls (hot-reload) do not stack a new
-- client button::press handler each time (B5): the connection is made once
local button_press_connected = false
-- module-level hold timer reused across M.keys() calls; a fresh timer per
-- call leaked the previous one (B5). timeout is (re)set per call from opts.hold
local hold_timer

local function disarm()
    state.armed = false
end

M.disarm = disarm

--- Seconds since the current Super press went down (math.huge when Super
-- is up). state.pressed is only set on the initial press and cleared on
-- release, so the timestamp marks the start of the physical hold even
-- through keyboard-repeat events. Consumers like the dictation chord use
-- this to tell a held Mod4 apart from the Copilot key, whose firmware
-- emits Super+Shift+F23 in one burst - the synthesized Super_L lands only
-- milliseconds before F23, while a human-held Mod4 is far older.
function M.press_age()
    if not state.pressed or not state.press_time then
        return math.huge
    end
    return (GLib.get_monotonic_time() - state.press_time) / 1e6
end

--- Wire disarm() onto the "press" signal of every underlying key object in
-- one or more keybinding tables (as returned by keybindings.build: an array
-- of awful.key groups, each itself an array of raw capi.key sub-objects).
-- Call this with the real globalkeys/clientkeys tables once they're built,
-- so any bound key press - i.e. any chord involving Super - disarms the tap.
-- @tparam table ... One or more keybinding tables (globalkeys, clientkeys).
function M.watch(...)
    local watched = 0
    for _, keys_table in ipairs({ ... }) do
        for _, group in ipairs(keys_table or {}) do
            for _, subkey in ipairs(group) do
                watched = watched + 1
                subkey:connect_signal("press", guarded(function()
                    if DEBUG and state.armed then
                        naughty.notification { message = "solo_super: chord disarm fired (key=" .. tostring(subkey.key) .. ")", timeout = 2 }
                    end
                    disarm()
                end))
            end
        end
    end
    if DEBUG then
        naughty.notification { message = "solo_super: watching " .. watched .. " key objects for chord detection", timeout = 3 }
    end
end

--- Build the Super_L key objects.
-- @tparam table opts
-- @tparam string opts.modkey Modifier name for Super ("Mod4").
-- @tparam string opts.launcher Command to launch.
-- @tparam[opt] string opts.process Process name for pkill/pgrep toggle; nil disables the close-on-tap.
-- @tparam[opt=0.6] number opts.hold Seconds after which a held Super no longer counts as a tap.
-- @tparam[opt=0.05] number opts.tap_min Minimum hold for a release to count as a tap
--   (the Copilot key's burst holds its synthesized Meta for only ~4ms).
-- @treturn table List of awful.key objects to append to the global keybindings.
function M.keys(opts)
    local modkey = opts.modkey or "Mod4"
    local cmd = opts.launcher
    if opts.process then
        cmd = string.format("pgrep -x %s >/dev/null && pkill -x %s || %s", opts.process, opts.process, cmd)
    end

    local function on_hold()
        if DEBUG and state.armed then
            naughty.notification { message = "solo_super: hold timer fired, disarming (held > " .. tostring(opts.hold or 0.6) .. "s)", timeout = 2 }
        end
        disarm()
    end

    -- reuse the module-level hold timer (created once, stopped before each
    -- arm) instead of allocating a new one per M.keys() call (B5 leak). the
    -- callback is refreshed each call so a new opts.hold / debug message
    -- takes effect without leaking a new timer object.
    if not hold_timer then
        hold_timer = gears.timer {
            timeout = opts.hold or 0.6,
            single_shot = true,
            callback = guarded(on_hold),
        }
    else
        hold_timer.timeout = opts.hold or 0.6
        hold_timer.callback = guarded(on_hold)
        hold_timer:stop()
    end

    -- old: armed on every press and restarted the hold timer each time.
    --      Super_L keyboard-repeat events call on_press repeatedly while the
    --      key is held, so hold_timer:again() reset the 0.6s countdown
    --      forever - the timer never fired, state.armed stayed true, and the
    --      launcher spawned on release even after a long hold (which also
    --      interrupted any Super+drag in progress by grabbing the pointer).
    --      Guarding on state.armed alone is not enough: once the hold timer
    --      disarms, the next repeat sees armed == false and re-arms, looping.
    -- new: a separate state.pressed flag tracks the physical key and is only
    --      cleared on release, so repeat events never re-arm after the hold
    --      threshold expires. The timer then reliably disarms a held Super.
    local function record_press()
        if state.pressed then return end
        state.pressed = true
        state.press_time = GLib.get_monotonic_time()
    end

    local function on_press()
        if state.pressed then return end
        record_press()
        state.armed = true
        hold_timer:again()
    end

    local function on_release()
        -- a lone AI-key burst holds its synthesized Meta for only ~4ms and
        -- can slip a release past the chord-disarm paths depending on which
        -- modifier the firmware drops first; a deliberate tap is never that
        -- fast, so holds under the floor never count as taps
        local held = state.press_time
            and (GLib.get_monotonic_time() - state.press_time) / 1e6
            or math.huge
        state.pressed = false
        state.press_time = nil
        hold_timer:stop()
        if state.armed and held >= (opts.tap_min or 0.05) then
            awful.spawn.with_shell(cmd, false)
        end
        disarm()
    end

    -- Release cleanup for masks where the tap can never fire anyway: the
    -- emitted mask carries the released key's own modifier, so a Meta
    -- released while Shift is still down arrives as {Mod4,Shift}+Super_L.
    -- The Copilot key's firmware burst releases its synthesized Meta exactly
    -- that way - without this, state.pressed would wedge true on the first
    -- AI-key press, sticking solo-tap and press_age consumers forever.
    local function on_release_only()
        state.pressed = false
        state.press_time = nil
        hold_timer:stop()
        disarm()
    end

    -- chord detection: see M.watch, called from rc.lua once globalkeys and
    -- clientkeys are built, which wires disarm() onto every real
    -- keybinding's own "press" signal. connected once at module level (B5)
    -- so repeated M.keys() calls do not stack handlers.
    if not button_press_connected then
        client.connect_signal("button::press", guarded(disarm))
        button_press_connected = true
    end

    local desc = { description = "launcher (tap Super alone)", group = "launcher" }
    return {
        awful.key({}, "Super_L", guarded(on_press), guarded(on_release), desc),
        awful.key({ modkey }, "Super_L", guarded(on_press), guarded(on_release)),
        -- Super_L arriving/releasing with other modifiers already in the
        -- mask (the Copilot key's Shift+Super+F23 burst, or a held Shift):
        -- tracked for press_age bookkeeping but never arms or fires the tap
        awful.key({ "Shift" }, "Super_L", guarded(record_press), guarded(on_release_only)),
        awful.key({ modkey, "Shift" }, "Super_L", guarded(record_press), guarded(on_release_only)),
        awful.key({ modkey, "Control" }, "Super_L", guarded(record_press), guarded(on_release_only)),
        awful.key({ modkey, "Mod1" }, "Super_L", guarded(record_press), guarded(on_release_only)),
    }
end

return M
