-- rc/tag_navigation.lua
--
-- Tag navigation helpers: moving the focused client between tags and
-- cycling through tags that contain clients.


local awful = require("awful")
local gears = require("gears")

local M = {}


-- // MARK: -- move client to adjacent tag

-- move the focused client to the previous tag on its screen
function M.move_to_previous_tag()
    local c = client.focus
    if not c then return end
    local current_tag = c:tags()[1]
    if current_tag then
        local prev_tag = current_tag.screen.tags[current_tag.index - 1]
        if prev_tag then c:move_to_tag(prev_tag) end
    end
end

-- move the focused client to the next tag on its screen
function M.move_to_next_tag()
    local c = client.focus
    if not c then return end
    local current_tag = c:tags()[1]
    if current_tag then
        local next_tag = current_tag.screen.tags[current_tag.index + 1]
        if next_tag then c:move_to_tag(next_tag) end
    end
end

-- move the focused client to the previous tag and follow it (view that tag)
function M.move_to_previous_tag_and_follow()
    local c = client.focus
    if not c then return end
    local current_tag = c:tags()[1]
    if current_tag then
        local prev_tag = current_tag.screen.tags[current_tag.index - 1]
        if prev_tag then
            c:move_to_tag(prev_tag)
            prev_tag:view_only()
        end
    end
end

-- move the focused client to the next tag and follow it (view that tag)
function M.move_to_next_tag_and_follow()
    local c = client.focus
    if not c then return end
    local current_tag = c:tags()[1]
    if current_tag then
        local next_tag = current_tag.screen.tags[current_tag.index + 1]
        if next_tag then
            c:move_to_tag(next_tag)
            next_tag:view_only()
        end
    end
end


-- // MARK: -- cycle tags with clients

-- cycle to the next/prev tag that has at least one client
function M.cycle_tags_with_clients(direction)
    local current_screen = awful.screen.focused()
    local all_tags = current_screen.tags
    local current_tag = current_screen.selected_tag
    local current_index = gears.table.hasitem(all_tags, current_tag)

    local count = #all_tags

    for i = 1, count - 1 do
        local idx
        if direction == "next" then
            idx = ((current_index + i - 1) % count) + 1
        else
            idx = ((current_index - i - 1 + count) % count) + 1
        end
        local tag = all_tags[idx]

        if #tag:clients() > 0 then
            tag:view_only()
            return
        end
    end
end

-- cycle to the next/prev tag that has at least one visible (non-minimized) client
function M.cycle_tags_with_visible_clients(direction)
    local current_screen = awful.screen.focused()
    local all_tags = current_screen.tags
    local current_tag = current_screen.selected_tag
    local current_index = gears.table.hasitem(all_tags, current_tag)

    for i = 1, #all_tags - 1 do
        local idx
        if direction == "next" then
            idx = ((current_index - 1 + i) % #all_tags) + 1
        else
            idx = ((current_index - 1 - i + #all_tags) % #all_tags) + 1
        end
        local tag = all_tags[idx]
        local has_visible_clients = false
        for _, c in ipairs(tag:clients()) do
            if not c.minimized then
                has_visible_clients = true
                break
            end
        end
        if has_visible_clients then
            tag:view_only()
            return
        end
    end
end


return M
