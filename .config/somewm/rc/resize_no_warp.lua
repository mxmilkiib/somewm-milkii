-- rc/resize_no_warp.lua
--
-- Anti-warp resize function that prevents the cursor from jumping to
-- another monitor during window resize operations.
--
-- Layout-aware: delegates to the current tag layout's mouse_resize_handler
-- for tiled clients, and falls back to a custom floating resize with
-- corner/edge detection and screen-boundary clamping for floating windows.


local awful = require("awful")

local M = {}


-- // MARK: -- create resize function
--
-- Returns a resize_no_warp function bound to the given shared state.
--
-- @param opts  table with:
--   min_window_size  number  - minimum width/height in pixels (default 50)
--   window_centers   table   - shared weak-key table from rc.lua for
--                              updating floating center positions after
--                              resize completes
function M.create(opts)
    opts = opts or {}
    local min_window_size = opts.min_window_size or 50
    local window_centers = opts.window_centers

    return function(c)
        c:emit_signal("request::activate", "mouse_click", {raise = true})

        -- check if client is floating or if current layout has mouse_resize_handler
        local layout = awful.layout.get(c.screen)

        -- if client is not floating and layout has mouse_resize_handler, use it
        if not c.floating and layout and layout.mouse_resize_handler then

            local initial_coords = mouse.coords()
            local geo = c:geometry()

            -- determine corner based on mouse position relative to client center
            local corner
            if initial_coords.y < geo.y + geo.height/2 then
                if initial_coords.x < geo.x + geo.width/2 then
                    corner = "top_left"
                else
                    corner = "top_right"
                end
            else
                if initial_coords.x < geo.x + geo.width/2 then
                    corner = "bottom_left"
                else
                    corner = "bottom_right"
                end
            end

            -- call the layout's mouse resize handler
            layout.mouse_resize_handler(c, corner, initial_coords.x, initial_coords.y)
            return
        end

        -- fallback to floating window resize for floating clients or layouts without mouse handler
        -- store initial cursor position
        local initial_coords = mouse.coords()

        -- store initial client geometry
        local geo = c:geometry()
        local initial_geo = {x = geo.x, y = geo.y, width = geo.width, height = geo.height}

        -- detect which corner/edge was grabbed based on mouse position
        -- this determines which corner stays fixed (anchor) during resize
        local corner = ""
        local edge_threshold = 20  -- pixels from edge to consider it an edge grab

        local rel_x = initial_coords.x - geo.x
        local rel_y = initial_coords.y - geo.y

        -- determine vertical anchor (top or bottom)
        if rel_y < edge_threshold then
            corner = "top"
        elseif rel_y > geo.height - edge_threshold then
            corner = "bottom"
        else
            -- middle vertical, will resize both top and bottom equally
            corner = "middle"
        end

        -- determine horizontal anchor (left or right)
        if rel_x < edge_threshold then
            corner = corner .. "_left"
        elseif rel_x > geo.width - edge_threshold then
            corner = corner .. "_right"
        else
            -- middle horizontal, will resize both left and right equally
            corner = corner .. "_center"
        end

        -- define anchor point based on grabbed corner (opposite corner stays fixed)
        local anchor_x, anchor_y
        if corner:match("left") then
            anchor_x = geo.x + geo.width  -- right edge is anchor
        elseif corner:match("right") then
            anchor_x = geo.x  -- left edge is anchor
        else
            anchor_x = geo.x + geo.width / 2  -- center is anchor
        end

        if corner:match("top") then
            anchor_y = geo.y + geo.height  -- bottom edge is anchor
        elseif corner:match("bottom") then
            anchor_y = geo.y  -- top edge is anchor
        else
            anchor_y = geo.y + geo.height / 2  -- center is anchor
        end

        -- get the current screen's geometry for boundary checking
        local screen_geo = screen[c.screen].geometry

        -- start the mouse grabber without warping the cursor
        mousegrabber.run(function(m)
            if not c.valid then return false end

            -- calculate new dimensions based on mouse movement from anchor point
            local new_x, new_y, new_width, new_height

            if corner:match("left") then
                -- dragging left edge: anchor is right edge
                new_x = math.min(m.x, anchor_x - min_window_size)
                new_width = anchor_x - new_x
            elseif corner:match("right") then
                -- dragging right edge: anchor is left edge
                new_x = anchor_x
                new_width = math.max(m.x - anchor_x, min_window_size)
            else
                -- dragging center horizontally: expand/contract symmetrically
                local dx = m.x - initial_coords.x
                new_width = math.max(initial_geo.width + dx * 2, min_window_size)
                new_x = anchor_x - new_width / 2
            end

            if corner:match("top") then
                -- dragging top edge: anchor is bottom edge
                new_y = math.min(m.y, anchor_y - min_window_size)
                new_height = anchor_y - new_y
            elseif corner:match("bottom") then
                -- dragging bottom edge: anchor is top edge
                new_y = anchor_y
                new_height = math.max(m.y - anchor_y, min_window_size)
            else
                -- dragging center vertically: expand/contract symmetrically
                local dy = m.y - initial_coords.y
                new_height = math.max(initial_geo.height + dy * 2, min_window_size)
                new_y = anchor_y - new_height / 2
            end

            -- constrain to screen boundaries
            if new_x < screen_geo.x then
                new_width = new_width - (screen_geo.x - new_x)
                new_x = screen_geo.x
            end
            if new_y < screen_geo.y then
                new_height = new_height - (screen_geo.y - new_y)
                new_y = screen_geo.y
            end
            if new_x + new_width > screen_geo.x + screen_geo.width then
                new_width = screen_geo.x + screen_geo.width - new_x
            end
            if new_y + new_height > screen_geo.y + screen_geo.height then
                new_height = screen_geo.y + screen_geo.height - new_y
            end

            -- ensure minimum size after boundary constraints
            new_width = math.max(new_width, min_window_size)
            new_height = math.max(new_height, min_window_size)

            -- apply the new geometry
            c:geometry({
                x = math.floor(new_x),
                y = math.floor(new_y),
                width = math.floor(new_width),
                height = math.floor(new_height)
            })

            local continuing = m.buttons[3] or m.buttons[2]
            if not continuing and c.floating and window_centers then
                local new_geo = c:geometry()
                window_centers[c] = {
                    x = new_geo.x + new_geo.width / 2,
                    y = new_geo.y + new_geo.height / 2
                }
            end
            return continuing  -- continue as long as right or middle button is pressed
        end, "fleur")
    end
end


return M
