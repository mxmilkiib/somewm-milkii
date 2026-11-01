-- Terminal command-line abstraction
-- Each emulator spells "run a program", "set the window class/app_id"
-- and "start in a directory" differently; keep the quirks in one place.
--
-- kitty:     program is positional (no -e), --class sets app_id/class,
--            --directory sets the working directory
-- alacritty: needs -e, --chdir, and --class <general>,<instance>

local M = {}

M.binary = "kitty" -- Wayland-native terminal

local SPECS = {
    kitty = {
        exec_sep = "",
        class_arg = function(name) return "--class " .. name end,
        cwd_flag = "--directory",
    },
    alacritty = {
        exec_sep = "-e ",
        -- takes <general>,<instance>; lain's quake matches on the instance
        class_arg = function(name) return "--class " .. name .. "," .. name end,
        cwd_flag = "--chdir",
    },
}

local spec = assert(SPECS[M.binary], "no terminal spec for " .. M.binary)

-- flag to start the terminal in a directory (no dir; for shell expansions)
M.cwd_flag = spec.cwd_flag

-- command string running cmd inside the terminal
function M.run_in(cmd)
    return M.binary .. " " .. spec.exec_sep .. cmd
end

-- command string running cmd inside the terminal under class/app_id name
function M.run_in_class(name, cmd)
    return M.binary .. " " .. spec.class_arg(name) .. " " .. spec.exec_sep .. cmd
end

-- expanded class/app_id flag for callers that format the name themselves:
-- lain's quake applies string.format(argname, name), so pass a literal that
-- contains no conversion specifiers and formats through unchanged
function M.class_arg(name)
    return spec.class_arg(name)
end

return M
