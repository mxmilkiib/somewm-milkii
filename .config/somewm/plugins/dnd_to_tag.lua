-- plugins/dnd_to_tag.lua
-- // MARK: DRAG AND DROP
-- ################################################################################
-- ██████╗ ██████╗ ██████╗    █████╗    ██████╗  ██████╗ ██████╗ 
-- ██╔══██╗██╔══██╗██╔══██╗  ██╔══██╗  ██╔═══██╗██╔═══██╗██╔══██╗
-- ██║  ██║██████╔╝██║  ██║  ███████║  ██║   ██║██║   ██║██████╔╝
-- ██║  ██║██╔══██╗██║  ██║  ██╔══██║  ██║   ██║██║   ██║██╔═══╝ 
-- ██████╔╝██║  ██║██████╔╝  ██║  ██║  ╚██████╔╝╚██████╔╝██║     
-- ╚═════╝ ╚═╝  ╚═╝╚═════╝   ╚═╝  ╚═╝   ╚═════╝  ╚═════╝ ╚═╝     
-- ################################################################################
-- drag and drop - client to tag drag and drop functionality
--
-- USAGE:
--   1. require the module in your rc.lua:
--      local dnd_to_tag = require("plugins.dnd_to_tag")
--
--   2. add mouse bindings to client buttons:
--      -- drag to tag and follow view (modkey + shift + button1)
--      awful.button({ modkey, "Shift" }, 1, function (c)
--          c:emit_signal("request::activate", "mouse_click", {raise = true})
--          dnd_to_tag.start_custom_drag(c, {follow_on_drop = true})
--      end)
--
--      -- drag to tag without following (modkey + control + button1)
--      awful.button({ modkey, "Control" }, 1, function (c)
--          c:emit_signal("request::activate", "mouse_click", {raise = true})
--          dnd_to_tag.start_custom_drag(c, {follow_on_drop = false})
--      end)
--
--   3. during drag, hold shift to follow or control to stay on current tag
--
--   4. optional: configure visual feedback
--      dnd_to_tag.configure({
--          visual_feedback = "border",
--          border_color = "#ff8800",
--          highlight_widget = true,
--          hover_bg = "#444444",
--          hover_fg = "#ffffff"
--      })
--
-- API:
--   dnd_to_tag.start_custom_drag(client, opts)
--   dnd_to_tag.finish_custom_drag()
--   dnd_to_tag.set_hover(tag, widget)
--   dnd_to_tag.clear_hover()
--   dnd_to_tag.update_hover_from_mouse()
--   dnd_to_tag.resolve_drop_target()
--   dnd_to_tag.configure(opts)

local awful = require("awful")
local gears = require("gears")
local beautiful = require("beautiful")
local mouse = mouse
local mousegrabber = mousegrabber

local M = {
    dragged_client = nil,
    hovered_tag = nil,
    hovered_widget = nil,
    drag_active = false,
    _timer = nil,
    _follow_on_drop = nil,
    _overlay = nil,
    _drag_keygrabber = nil,
    _paused_border_anim = false,
    -- config (overridable via M.configure)
    config = {
        visual_feedback = "border",  -- "border" | "none"
        border_color = beautiful and beautiful.border_urgent or "#ff8800",
        border_width_delta = 2,
        highlight_widget = true,
        hover_bg = beautiful and beautiful.bg_focus or "#444444",
        hover_fg = beautiful and beautiful.fg_focus or "#ffffff",
        pause_border_animation_signals = true
    }
}

-- simple configure helper (non-destructive merge)
function M.configure(opts)
    if type(opts) ~= "table" then return end
    for k, v in pairs(opts) do
        M.config[k] = v
    end
end

function M.clear_hover()
    local widget_to_clear = M.hovered_widget

    if widget_to_clear then
        local widget_valid = widget_to_clear.valid
        if widget_valid == nil or widget_valid then
            -- Restore original styling
            if widget_to_clear._dnd_prev_bg ~= nil then
                widget_to_clear.bg = widget_to_clear._dnd_prev_bg
                widget_to_clear._dnd_prev_bg = nil
            else
                -- fallback: explicitly clear bg to force default
                widget_to_clear.bg = nil
            end
            if widget_to_clear._dnd_prev_fg ~= nil then
                widget_to_clear.fg = widget_to_clear._dnd_prev_fg
                widget_to_clear._dnd_prev_fg = nil
            else
                -- fallback: explicitly clear fg to force default
                widget_to_clear.fg = nil
            end
            -- force widget update
            if widget_to_clear.emit_signal then
                widget_to_clear:emit_signal("widget::redraw_needed")
            end
        end
    end
    M.hovered_tag = nil
    M.hovered_widget = nil
end

function M.set_hover(tag, widget)
    -- Clear previous hover first
    M.clear_hover()

    -- Set new hover
    M.hovered_tag = tag
    M.hovered_widget = widget

    -- Apply styling the same way normal hover works
    if widget and M.config.highlight_widget then
        local widget_valid = widget.valid
        if widget_valid == nil or widget_valid then
            -- Store original colors before changing
            widget._dnd_prev_bg = widget.bg
            widget._dnd_prev_fg = widget.fg
            -- Apply hover styling
            widget.bg = M.config.hover_bg or "#444444"
            widget.fg = M.config.hover_fg or "#ffffff"
        end
    end

    if awesome and awesome.emit_signal then
        awesome.emit_signal("dnd_to_tag::hover", tag, widget)
    end
end

function M.start_custom_drag(c, opts)
    if not c or not c.valid then return end

    M.dragged_client = c

    -- set visual feedback immediately
    c._dnd_prev_border_color = c.border_color
    c._dnd_prev_border_width = c.border_width
    if M.config.visual_feedback == "border" then
        c.border_color = M.config.border_color or (beautiful and beautiful.border_urgent) or "#ff8800"
        -- use theme border width instead of adding delta
        c.border_width = beautiful and beautiful.border_width or 1
    end
    c._dnd_dragging = true

    -- global drag flag (also used by border animation to pause)
    M.drag_active = true
    M._follow_on_drop = opts and opts.follow_on_drop or false

    -- prevent text selection in client (best-effort)
    c.input_passthrough = true

    -- pause border animation via signal (plugin-aware)
    if M.config.pause_border_animation_signals and awesome and awesome.emit_signal then
        awesome.emit_signal("border_animation::pause")
    end
    -- Fallback: stop inline timer if present
    if border_animation_timer and border_animation_timer.started then
        border_animation_timer:stop()
        M._paused_border_anim = true
    end

    if awesome and awesome.emit_signal then
        awesome.emit_signal("dnd_to_tag::start", c)
    end

    -- use mousegrabber to capture pointer and set cursor during drag
    mousegrabber.run(function(m)
        if not c.valid then
            M.finish_custom_drag()
            return false
        end
        -- detect shift/control follow-on-drop via modifiers if available
        if m.modifiers then
            local shift_held = m.modifiers.Shift or m.modifiers["Shift_L"] or m.modifiers["Shift_R"]
            local ctrl_held = m.modifiers.Control or m.modifiers["Control_L"] or m.modifiers["Control_R"]
            
            if ctrl_held then
                M._follow_on_drop = false  -- control = don't follow
            elseif shift_held then
                M._follow_on_drop = true   -- shift = follow
            end
            -- otherwise keep existing _follow_on_drop value
        end
        -- continuously update hovered tag
        if M.update_hover_from_mouse then
            M.update_hover_from_mouse()
        end
        -- stop on left button release
        if not (m.buttons and m.buttons[1]) then
            M.finish_custom_drag()
            return false
        end
        return true
    end, "fleur")
end

function M.finish_custom_drag()
    -- ensure any overlay/keygrabber are gone (legacy cleanup)
    if M._overlay and M._overlay.valid then
        M._overlay.visible = false
    end
    M._overlay = nil
    if M._drag_keygrabber then M._drag_keygrabber:stop() end
    M._drag_keygrabber = nil

    local c = M.dragged_client
    local target_tag = M.hovered_tag or M.resolve_drop_target()
    local follow = M._follow_on_drop
    
    -- Emit drag end signal for maximized window handling
    if c and c.valid and c._was_maximized then
        c:emit_signal("awesome::drag_end")
    end

    -- perform the drop
    if c and c.valid and target_tag and target_tag.valid then
        -- move client to target tag
        c:move_to_tag(target_tag)
        
        -- optionally follow client to new tag
        if follow then
            target_tag:view_only()
        end
    end

    -- restore client visuals
    if c and c.valid then
        if c._dnd_prev_border_color ~= nil then
            c.border_color = c._dnd_prev_border_color
            c._dnd_prev_border_color = nil
        else
            -- fallback: restore to theme default or beautiful value
            c.border_color = beautiful and beautiful.border_normal or "#000000"
        end
        if c._dnd_prev_border_width ~= nil then
            c.border_width = c._dnd_prev_border_width
            c._dnd_prev_border_width = nil
        else
            -- fallback: restore to theme default
            c.border_width = beautiful and beautiful.border_width or 1
        end
        c._dnd_dragging = nil
        c.input_passthrough = false
        
        -- force client redraw to ensure border changes are applied
        if c.emit_signal then
            c:emit_signal("property::border_color")
            c:emit_signal("property::border_width")
        end
    end

    -- resume border animation via signal (plugin-aware)
    if M.config.pause_border_animation_signals and awesome and awesome.emit_signal then
        awesome.emit_signal("border_animation::resume")
    end
    -- Fallback: restart inline timer if we paused it
    if M._paused_border_anim and border_animation_timer then
        border_animation_timer:start()
        M._paused_border_anim = false
    end

    if awesome and awesome.emit_signal then
        awesome.emit_signal("dnd_to_tag::finish", c, target_tag, follow)
    end

    -- clear visual feedback and state
    M.clear_hover()
    M.dragged_client = nil
    M.hovered_tag = nil
    M.drag_active = false
    M._follow_on_drop = nil
end

function M.update_hover_from_mouse()
    local mc = mouse.coords()
    if not mc then
        M.clear_hover()
        return
    end

    local found_tag = nil
    local found_widget = nil

    -- calculate tag based on known 23px tag width
    for s in screen do
        if s.mywibox and s.mywibox.visible then
            local wibox_geo = s.mywibox:geometry()
            if mc.x >= wibox_geo.x and mc.x <= wibox_geo.x + wibox_geo.width and
               mc.y >= wibox_geo.y and mc.y <= wibox_geo.y + wibox_geo.height then
                
                if s.tags and #s.tags > 0 then
                    local tag_width = 23  -- exact width from user feedback
                    local taglist_start_x = wibox_geo.x + 32  -- launcher + spacing
                    local taglist_end_x = taglist_start_x + (#s.tags * tag_width)
                    
                    if mc.x >= taglist_start_x and mc.x <= taglist_end_x then
                        local rel_x = mc.x - taglist_start_x
                        local idx = math.floor(rel_x / tag_width) + 1
                        if idx >= 1 and idx <= #s.tags then
                            found_tag = s.tags[idx]
                        end
                    end
                end
            end
        end
        if found_tag then break end
    end

    -- always either set hover or clear it
    if found_tag then
        -- try to locate the corresponding widget via shimmer integrations (if present)
        if not found_widget then
            local ok, integrations = pcall(require, 'plugins.shimmer.integrations')
            if ok and integrations and integrations._get_registered_widgets then
                local widgets = integrations._get_registered_widgets()
                if widgets and widgets.taglist then
                    local screen_index = found_tag.screen and found_tag.screen.index or nil
                    if screen_index and widgets.taglist[screen_index] then
                        found_widget = widgets.taglist[screen_index][found_tag]
                    end
                end
            end
        end
        M.set_hover(found_tag, found_widget)
    else
        M.clear_hover()
    end
end

function M.resolve_drop_target()
    if M.hovered_tag and M.hovered_tag.valid then
        return M.hovered_tag
    end
    local mc = mouse.coords()
    if not mc then return nil end

    -- calculate based on known 23px tag width
    for s in screen do
        if s.mywibox and s.mywibox.visible then
            local wibox_geo = s.mywibox:geometry()
            if mc.x >= wibox_geo.x and mc.x <= (wibox_geo.x + wibox_geo.width) and
               mc.y >= wibox_geo.y and mc.y <= (wibox_geo.y + wibox_geo.height) then
                
                if s.tags and #s.tags > 0 then
                    local tag_width = 23  -- exact width from user feedback
                    local taglist_start_x = wibox_geo.x + 32  -- launcher + spacing
                    local taglist_end_x = taglist_start_x + (#s.tags * tag_width)
                    
                    if mc.x >= taglist_start_x and mc.x <= taglist_end_x then
                        local rel_x = mc.x - taglist_start_x
                        local idx = math.floor(rel_x / tag_width) + 1
                        if idx >= 1 and idx <= #s.tags then
                            return s.tags[idx]
                        end
                    end
                end
            end
        end
    end
    return nil
end

return M
