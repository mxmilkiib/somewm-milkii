-- plugins/smart_borders.lua
--
-- Dynamic border width: no border when a tag has only one visible tiled
-- client, borders for all when two or more share a tag. This replaces the
-- old static terminal_borderless rule which left terminals borderless even
-- when sharing a tag with other windows.


local gears = require("gears")
local beautiful = require("beautiful")
local guarded = require("error_guard")

local M = {}


-- // MARK: -- border width helpers

local function count_visible_tiled_clients(tag)
    local n = 0
    for _, c in ipairs(tag:clients() or {}) do
        if c.valid and not c.minimized and not c.hidden and not c.floating then
            n = n + 1
        end
    end
    return n
end

local function update_borders_for_tag(tag)
    if not tag or not tag.valid then return end
    local n = count_visible_tiled_clients(tag)
    local bw = (n > 1) and (beautiful.border_width or 1) or 0
    for _, c in ipairs(tag:clients() or {}) do
        if c.valid and not c.floating then
            c.border_width = bw
        end
    end
end

local function update_all_borders()
    for s in screen do
        for _, t in ipairs(s.tags) do
            update_borders_for_tag(t)
        end
    end
end


-- // MARK: -- signal connections

-- connect all signals needed for dynamic border updates.
-- call once after client rules are registered.
function M.init()
    client.connect_signal("request::manage", guarded(function(c)
        gears.timer.delayed_call(guarded(function()
            if not c or not c.valid then return end
            for _, t in ipairs(c:tags() or {}) do
                update_borders_for_tag(t)
            end
        end))
    end))

    client.connect_signal("request::unmanage", guarded(function(c)
        gears.timer.delayed_call(guarded(update_all_borders))
    end))

    client.connect_signal("property::minimized", guarded(update_all_borders))
    client.connect_signal("property::floating", guarded(update_all_borders))
    client.connect_signal("tagged", guarded(function(c)
        if not c or not c.valid then return end
        for _, t in ipairs(c:tags() or {}) do
            update_borders_for_tag(t)
        end
    end))
    client.connect_signal("untagged", guarded(update_all_borders))
end


return M
