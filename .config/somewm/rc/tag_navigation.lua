-- rc/tag_navigation.lua
--
-- Tag navigation helpers: moving the focused client between tags and
-- cycling through tags that contain clients.


local awful = require("awful")
local gears = require("gears")
local naughty = require("naughty")

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


-- // MARK: -- spread tag clients to empty tags

-- Spread a crowded Tag: every Client except the focused one is moved to
-- its own empty Tag on the same Screen. When the free Tags run out the
-- remaining Clients stay put and a Notification reports the count.
function M.spread_tag_clients()
    local s = awful.screen.focused()
    local t = s and s.selected_tag
    if not t then return end

    local cls = t:clients()
    if #cls < 2 then return end

    -- Focused Client keeps the Tag; fall back to the first Client
    local keep = client.focus
    if not keep or not gears.table.hasitem(cls, keep) then
        keep = cls[1]
    end

    -- Empty, unselected Tags on this Screen, in order
    local free_tags = {}
    for _, tag in ipairs(s.tags) do
        if tag ~= t and #tag:clients() == 0 then
            table.insert(free_tags, tag)
        end
    end

    local moved, leftover = 0, 0
    for _, c in ipairs(cls) do
        if c ~= keep then
            local target = free_tags[moved + 1]
            if target then
                c:move_to_tag(target)
                moved = moved + 1
            else
                leftover = leftover + 1
            end
        end
    end

    if leftover > 0 then
        naughty.notify {
            title = "spread windows",
            text = string.format("%d moved, %d left on the tag: no free tags", moved, leftover),
            timeout = 2,
        }
    end
end


-- // MARK: -- cycle tags with clients

-- cycle to the next/prev tag that has at least one client
function M.cycle_tags_with_clients(direction)
    local current_screen = awful.screen.focused()
    local all_tags = current_screen.tags
    local current_tag = current_screen.selected_tag
    if not current_tag then return end
    local current_index = gears.table.hasitem(all_tags, current_tag)
    if not current_index then return end

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
    if not current_tag then return end
    local current_index = gears.table.hasitem(all_tags, current_tag)
    if not current_index then return end

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
