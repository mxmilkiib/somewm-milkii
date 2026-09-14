-- Minimal nested-test config for the shake_cursor cursor_scale path.
-- Loads only what's needed to exercise root.cursor_scale() live.
local gears = require("gears")
local guarded = require("error_guard")

-- A basic wibar so there's something to look at and a root area to hover.
local wibar = require("awful.wibar")
local wb = wibar({ position = "top", height = 24, bg = "#222" })
wb:setup({ layout = require("awful.widget.layout").horizontal.leftright,
    { widget = require("wibox.widget.textbox"), text = "  shake_cursor nested test  " },
})

require("plugins.shake_cursor").start()

-- Esc quits the nested compositor.
globalkeys = gears.table.join(
    require("awful.key")({ "Mod4" }, "Escape", awesome.quit))
root.keys(globalkeys)

-- Also quit if the nested window is closed.
awesome.connect_signal("exit", function() end)
