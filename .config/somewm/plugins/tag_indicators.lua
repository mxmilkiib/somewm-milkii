-- plugins/tag_indicators.lua
-- Tag occupancy indicators (squares) system for AwesomeWM
-- Provides dynamic square indicators showing tag client state

local gears = require("gears")
local wibox = require("wibox")
local awful = require("awful")
local beautiful = require("beautiful")
local cairo = require("lgi").cairo
local awful_taglist = require("awful.widget.taglist")


local M = {}


-- Configuration
local TAG_SQUARE_SIZE = 5
local TAG_SQUARE_COLOR = "#8DE600"  -- apple green for tag indicators

-- Surface cache for performance
local square_surface_cache = {}



-- MARK: HELPER FUNCTIONS

-- Convert hex color to RGB values
local function hex_to_rgb(hex)
    if not hex or #hex < 7 then return 170, 170, 170 end
    hex = hex:gsub("#", "")
    local r = tonumber(hex:sub(1, 2), 16) or 170
    local g = tonumber(hex:sub(3, 4), 16) or 170
    local b = tonumber(hex:sub(5, 6), 16) or 170
    return r, g, b
end

-- Create a square surface with specified properties
local function create_square_surface(filled, size, color_hex)
    size = size or TAG_SQUARE_SIZE
    color_hex = color_hex or "#aaaaaa"
    
    local key = (filled and "F" or "H") .. ":" .. color_hex .. ":" .. tostring(size)
    if square_surface_cache[key] then return square_surface_cache[key] end
    
    local img = cairo.ImageSurface(cairo.Format.ARGB32, size, size)
    local cr = cairo.Context(img)
    
    local r, g, b = hex_to_rgb(color_hex)
    
    if filled then
        -- Filled square for unminimized windows
        cr:set_source_rgba(r/255, g/255, b/255, 1)
        cr:rectangle(0, 0, size, size)
        cr:fill()
    else
        -- Hollow square for minimized-only windows
        cr:set_source_rgba(r/255, g/255, b/255, 1)
        cr:set_line_width(0.5)
        cr:rectangle(0.25, 0.25, size-0.5, size-0.5)
        cr:stroke()
    end
    
    square_surface_cache[key] = img
    return img
end

-- Get tag square state based on client visibility
local function get_tag_square_state(tag)
    local clients = tag:clients()
    if #clients == 0 then
        return "empty"        -- no clients at all
    end
    
    for _, client in ipairs(clients) do
        if not client.minimized and not client.hidden then
            return "visible"  -- at least one client would be visible on tag switch
        end
    end
    
    return "no_visible"       -- clients exist but none would be visible
end


-- MARK: SQUARE MANAGEMENT
-- legacy widget-overlay approach (disabled)
-- the following block implemented a second indicator in the bottom-right of the tag
-- widget. this is kept for reference but disabled in favor of a simpler monkey-patch
-- that uses the built-in top-left taglist squares. the new approach avoids any theme
-- file edits and works transparently with the default taglist.
--
--[[
-- Create square surfaces for different states
local filled_square = create_square_surface(true, TAG_SQUARE_SIZE, "#b0b0b0")
local hollow_square = create_square_surface(false, TAG_SQUARE_SIZE, "#808080")

function M.get_tag_square(tag, is_selected)
    local state = get_tag_square_state(tag)
    return (state == "visible") and filled_square or hollow_square
end

function M.update_square_widget(square_widget, tag)
    if not square_widget or not tag then return end
    local has_unminimized = false
    for _, client in ipairs(tag:clients()) do
        if not client.minimized and not client.hidden then
            has_unminimized = true
            break
        end
    end
    if has_unminimized then
        square_widget.image = filled_square
    elseif #tag:clients() > 0 then
        square_widget.image = hollow_square
    else
        square_widget.image = nil
    end
end

function M.create_square_widget(tag)
    local square_widget = wibox.widget {
        id = 'occ_square',
        forced_width = TAG_SQUARE_SIZE,
        forced_height = TAG_SQUARE_SIZE,
        widget = wibox.widget.imagebox,
    }
    M.update_square_widget(square_widget, tag)
    return square_widget
end

local update_timer = nil
local pending_updates = {}
function M.register_tag(tag, square_widget)
    if not tag or not square_widget then return end
    local function schedule_update()
        pending_updates[tag] = square_widget
        if update_timer then update_timer:stop() end
        update_timer = require("gears").timer {
            timeout = 0.05,
            single_shot = true,
            callback = function()
                for pending_tag, pending_widget in pairs(pending_updates) do
                    if pending_tag.valid and pending_widget then
                        M.update_square_widget(pending_widget, pending_tag)
                    end
                end
                pending_updates = {}
                update_timer = nil
            end
        }
        update_timer:start()
    end
    tag.connect_signal("property::clients", schedule_update)
    for _, prop in ipairs({"minimized", "hidden"}) do
        client.connect_signal("property::" .. prop, function(c)
            if c and c.valid and c:tags() then
                for _, tg in ipairs(c:tags()) do
                    if tg == tag then schedule_update(); break end
                end
            end
        end)
    end
end
]]


-- MARK: THEME INTEGRATION

-- helper: derive size and color from theme when available
local function get_theme_square_size()
    return beautiful.tag_square_size or beautiful.taglist_square_size or TAG_SQUARE_SIZE
end

local function get_theme_square_color()
    return TAG_SQUARE_COLOR or beautiful.taglist_fg_occupied or beautiful.taglist_fg_focus or beautiful.fg_normal or "#aaaaaa"
end

-- helper: client state
local function tag_has_unminimised_clients(tag_object)
    if not tag_object or not tag_object.valid then return false end
    for _, c in ipairs(tag_object:clients() or {}) do
        if c.valid and not c.minimized and not c.hidden then
            return true
        end
    end
    return false
end

-- debounced refresh of all taglists
local _refresh_timer = nil
local function refresh_all_taglists()
    if _refresh_timer then
        _refresh_timer:again()
        return
    end
    _refresh_timer = gears.timer {
        timeout = 0.05,
        autostart = true,
        single_shot = true,
        callback = function()
            -- directly refresh all known taglists per screen; fallback to redraw
            for s in screen do
                if s.mytaglist then
                    if s.mytaglist._do_taglist_update_now then
                        -- internal, but reliable to recompute labels
                        pcall(function() s.mytaglist:_do_taglist_update_now() end)
                    elseif s.mytaglist.emit_signal then
                        s.mytaglist:emit_signal("widget::redraw_needed")
                    end
                end
            end
            _refresh_timer = nil
        end
    }
end

-- apply monkey-patch: wrap taglist_label to return dynamic squares per-tag
local _label_patched = false
local _surface_cache = { filled = nil, hollow = nil }

-- build/refresh the static surfaces we reuse for all tags
local function _rebuild_surfaces()
    local sz = get_theme_square_size()
    if type(sz) ~= 'number' then sz = TAG_SQUARE_SIZE end
    sz = math.max(1, sz - 3) -- 3px smaller than theme size
    _surface_cache.filled = create_square_surface(true, sz, get_theme_square_color())
    _surface_cache.hollow = create_square_surface(false, sz, get_theme_square_color())
end

local function apply_tag_label_patch()
    if not _label_patched then
        _rebuild_surfaces()
        -- keep original for text/bg/shape logic
        local original = awful_taglist.taglist_label
        -- keep a commented reference to old behavior for clarity
        -- original used theme.taglist_squares_* to decide bg_image based on selection/occupancy
        awful_taglist.taglist_label = function(t, args)
            local text, bg_color, bg_image, icon, other_args = original(t, args)
            -- compute dynamic indicator: filled if any unminimized client, hollow if only minimized, none if empty
            local clients = t and t.valid and t:clients() or {}
            if #clients == 0 then
                return text, bg_color, nil, icon, other_args
            end
            local filled = tag_has_unminimised_clients(t)
            bg_image = filled and _surface_cache.filled or _surface_cache.hollow
            return text, bg_color, bg_image, icon, other_args
        end
        _label_patched = true
    else
        -- only rebuild surfaces on subsequent calls (e.g., theme change)
        _rebuild_surfaces()
    end
end

-- update helper for our overlay square widget
local function update_occ_square_widget(square_widget, tag)
    if not square_widget or not tag or not tag.valid then return end
    local clients = tag:clients() or {}
    if #clients == 0 then
        square_widget.image = nil
        return
    end
    local filled = tag_has_unminimised_clients(tag)
    square_widget.image = create_square_surface(filled, get_theme_square_size(), get_theme_square_color())
end

-- inject our indicator into any taglist widget_template by wrapping it in a stack
local function wrap_taglist_template(tpl)
    local size = get_theme_square_size()
    local occ_square = {
        id = 'occ_square',
        forced_width = size,
        forced_height = size,
        widget = wibox.widget.imagebox,
    }

    if type(tpl) == 'table' and tpl.widget then
        -- wrap the existing template content with our overlay
        local wrapped = {
            {
                tpl,
                {
                    {
                        occ_square,
                        left = 1,
                        top = 1,
                        widget = wibox.container.margin,
                    },
                    halign = 'left',
                    valign = 'top',
                    widget = wibox.container.place,
                },
                layout = wibox.layout.stack,
            },
            widget = wibox.container.margin,
        }

        -- extend callbacks while preserving user callbacks
        local old_create = tpl.create_callback
        wrapped.create_callback = function(self, tag, index, objects)
            if type(old_create) == 'function' then pcall(old_create, self, tag, index, objects) end
            local sq = self:get_children_by_id('occ_square')[1]
            if sq then update_occ_square_widget(sq, tag) end
        end

        local old_update = tpl.update_callback
        wrapped.update_callback = function(self, tag, index, objects)
            if type(old_update) == 'function' then pcall(old_update, self, tag, index, objects) end
            local sq = self:get_children_by_id('occ_square')[1]
            if sq then update_occ_square_widget(sq, tag) end
        end

        return wrapped
    else
        -- build a minimal template if none was supplied
        return {
            {
                {
                    { id = 'text_role', widget = wibox.widget.textbox },
                    widget = wibox.container.margin,
                },
                {
                    {
                        occ_square,
                        left = 1,
                        top = 1,
                        widget = wibox.container.margin,
                    },
                    halign = 'left',
                    valign = 'top',
                    widget = wibox.container.place,
                },
                layout = wibox.layout.stack,
            },
            id = 'background_role',
            widget = wibox.container.background,
            create_callback = function(self, tag, index, objects)
                local sq = self:get_children_by_id('occ_square')[1]
                if sq then update_occ_square_widget(sq, tag) end
            end,
            update_callback = function(self, tag, index, objects)
                local sq = self:get_children_by_id('occ_square')[1]
                if sq then update_occ_square_widget(sq, tag) end
            end
        }
    end
end

-- public function for rc.lua to update square widgets
function M.update_square(square_widget, tag)
    update_occ_square_widget(square_widget, tag)
end

-- set custom square color (optional)
function M.set_square_color(color_hex)
    TAG_SQUARE_COLOR = color_hex
    _rebuild_surfaces()
    refresh_all_taglists()
end

-- Initialize tag indicators system
function M.init()
    -- initialize tag indicators system
    
    -- apply a robust taglist_label wrapper for dynamic squares per tag
    apply_tag_label_patch()
    
    -- verify patch is active (no-op; kept for reference)
    
    -- re-apply on theme changes
    if beautiful.connect_signal then
        beautiful.connect_signal("changed", function()
            apply_tag_label_patch()
            refresh_all_taglists()
        end)
    end
    
    -- refresh when clients move/change visibility
    tag.connect_signal("property::clients", refresh_all_taglists)
    client.connect_signal("property::minimized", refresh_all_taglists)
    client.connect_signal("property::hidden", refresh_all_taglists)
    client.connect_signal("tagged", refresh_all_taglists)
    client.connect_signal("untagged", refresh_all_taglists)

    -- initial draw
    refresh_all_taglists()
end

-- legacy widget template (disabled; see monkey-patch in M.init())
--[[
function M.create_tag_widget_template()
    return {
        {
            {
                {
                    { id = 'occ_square', forced_width = TAG_SQUARE_SIZE, forced_height = TAG_SQUARE_SIZE, widget = wibox.widget.imagebox },
                    halign = 'right', valign = 'bottom', widget = wibox.container.place,
                },
                {
                    { id = 'text_role', widget = wibox.widget.textbox },
                    left = 4, right = 4, top = 1, bottom = 1, widget = wibox.container.margin,
                },
                layout = wibox.layout.stack,
            },
            widget = wibox.container.margin,
        },
        id = 'background_role',
        widget = wibox.container.background,
        update_callback = function(self, tag, index, objects)
            local square_widget = self:get_children_by_id('occ_square')[1]
            if square_widget and tag then M.update_square_widget(square_widget, tag) end
        end,
        create_callback = function(self, tag, index, objects)
            local square_widget = self:get_children_by_id('occ_square')[1]
            if square_widget and tag then M.register_tag(tag, square_widget) end
        end
    }
end
]]


-- MARK: INITIALIZATION

-- Initialize the system
M.init()

return M
