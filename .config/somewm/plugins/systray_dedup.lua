-- Removes orphaned StatusNotifierItem icons that hot-reloads leave in the
-- C-level systray item list.
--
-- awful.systray._cleanup (run on the "exit" signal before a reload) clears its
-- Lua tracking table (systray._private.items) but never calls
-- systray_item.unregister() on the C objects it references. On re-init,
-- fetch_registered_items() re-creates a C systray_item for every still
-- registered SNI app, while the pre-reload C objects remain in
-- systray_item.get_items(). wibox.widget.systray builds its children from that
-- C list, so each reload leaks one duplicate tray icon per long-running SNI
-- app (most visibly Steam, whose steamwebhelper stays registered under the
-- same bus name + path across reloads).
--
-- This plugin keeps the C list in sync with the watcher's live set: any C
-- item no longer tracked by awful.systray is unregistered, then a
-- systray::update is emitted so the widget resyncs. It runs on systray::added
-- (fired for each re-registered item during re-init) plus a one-shot sweep
-- shortly after load to catch orphans left before this plugin was wired up.

local awful_systray = require("awful.systray")
local gtimer = require("gears.timer")
local guarded = require("error_guard")

local capi = {
    awesome = awesome,
    systray_item = systray_item,
}

local M = {}

local running = false  -- reentrancy guard: unregister emits systray::update

-- Unregister C-level systray items that the watcher no longer tracks.
-- Returns the number of orphans removed.
function M.dedup()
    if running then return 0 end
    running = true

    local private = awful_systray._private
    if not private or not private.items then
        running = false
        return 0
    end

    -- live items currently tracked by the watcher (keyed by service..path)
    local live = {}
    for _, item in pairs(private.items) do
        live[item] = true
    end

    local removed = 0
    for _, item in ipairs(capi.systray_item.get_items()) do
        if not live[item] then
            capi.systray_item.unregister(item)
            removed = removed + 1
        end
    end

    if removed > 0 then
        capi.awesome.emit_signal("systray::update")
    end

    running = false
    return removed
end

function M.start()
    capi.awesome.connect_signal("systray::added", guarded(function()
        M.dedup()
    end))

    -- sweep once after load to clear orphans left by a prior reload before
    -- this plugin (or the watcher) was wired up
    gtimer.start_new(2, guarded(function()
        M.dedup()
        return false
    end))
end

return M
