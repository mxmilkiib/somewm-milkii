-- Qt dark-theme launch wrapper
-- Prepends bin/qt-dark to a shell command string; the wrapper detects Qt
-- programs and re-execs them with QT_QPA_PLATFORMTHEME set to qt5ct or
-- qt6ct as appropriate, so they follow the dark qtNct palette (the WM's
-- environment exports no platform theme of its own). Non-Qt commands
-- pass through unchanged.

local gears = require("gears")

local M = {}

local wrapper = gears.filesystem.get_configuration_dir() .. "bin/qt-dark"

local function shell_quote(s)
    return "'" .. s:gsub("'", "'\\''") .. "'"
end

function M.wrap(cmd)
    return wrapper .. " " .. shell_quote(cmd)
end

return M
