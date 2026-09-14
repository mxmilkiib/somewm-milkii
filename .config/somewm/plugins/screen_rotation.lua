-- plugins/screen_rotation.lua
--
-- Screen content rotation across multiple displays.
--
-- Rotates all tag contents (clients, layouts, properties) between screens,
-- preserving tag selection states and window assignments. Works
-- bidirectionally (left/right rotation) and provides visual feedback via
-- notifications.
--
-- rotation direction semantics:
--   "left":  content moves left  (screen 1 gets screen 2's content)
--   "right": content moves right (screen 1 gets last screen's content)
--
-- keybindings (wired from rc.lua via keybindings.build):
--   mod4 + ctrl + left/right arrows: keyboard rotation
--   mod4 + scroll wheel (over layout widget): mouse rotation


local naughty = require("naughty")

local M = {}


-- // MARK: -- rotate screens

function M.rotate_screens(direction)
    local all_screens = {}
    for s in screen do
        table.insert(all_screens, s)
    end

    -- need at least 2 screens to rotate content
    if #all_screens <= 1 then
        naughty.notify({
            title = "Screen Rotation",
            text = "Only one screen, nothing to rotate",
            timeout = 2
        })
        return
    end

    -- collect all tag configurations from all screens
    local screen_tags = {}
    for i, s in ipairs(all_screens) do
        screen_tags[i] = {}
        for j, tag in ipairs(s.tags) do
            -- store tag properties
            screen_tags[i][j] = {
                name = tag.name,
                selected = tag.selected,
                layout = tag.layout,
                clients = tag:clients(),
                -- store additional tag properties
                master_width_factor = tag.master_width_factor,
                master_count = tag.master_count,
                column_count = tag.column_count,
                gap = tag.gap,
                gap_single_client = tag.gap_single_client
            }
        end
    end

    -- calculate rotation: left = content moves left (screen indices go right)
    -- right = content moves right (screen indices go left)
    local target_mapping = {}
    for i = 1, #all_screens do
        if direction == "left" or direction == 1 then
            -- content moves left: screen 1 gets screen 2's content, etc.
            target_mapping[i] = (i % #all_screens) + 1
        else -- right or -1
            -- content moves right: screen 1 gets screen #'s content, etc.
            target_mapping[i] = ((i - 2 + #all_screens) % #all_screens) + 1
        end
    end

    -- apply the rotation
    for screen_idx, source_idx in pairs(target_mapping) do
        local target_screen = all_screens[screen_idx]
        local source_tags = screen_tags[source_idx]

        -- update each tag with properties from source
        for tag_idx, tag in ipairs(target_screen.tags) do
            local source_tag_data = source_tags[tag_idx]
            if source_tag_data then
                -- move all clients from source to target tag
                for _, client in ipairs(source_tag_data.clients) do
                    if client.valid then
                        client:move_to_tag(tag)
                    end
                end

                -- apply tag properties
                tag.layout = source_tag_data.layout
                tag.master_width_factor = source_tag_data.master_width_factor
                tag.master_count = source_tag_data.master_count
                tag.column_count = source_tag_data.column_count
                tag.gap = source_tag_data.gap
                tag.gap_single_client = source_tag_data.gap_single_client

                -- apply selection state last (after clients are moved)
                if source_tag_data.selected then
                    tag:view_only()
                end
            end
        end
    end

    -- show notification
    local direction_text = (direction == "left" or direction == 1) and "left" or "right"
    naughty.notify({
        title = "Screen Content Rotated",
        text = "All tags rotated " .. direction_text .. " across " .. #all_screens .. " screens",
        timeout = 2
    })
end


return M
