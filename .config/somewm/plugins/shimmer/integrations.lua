-- plugins/shimmer/integrations.lua
-- Widget integration and shimmer application for tags, tasks, and launcher
--
-- INTEGRATION ARCHITECTURE:
-- This module handles shimmer integration with AwesomeWM widgets:
-- • Taglist widgets - per-tag registration with hover effects
-- • Tasklist widgets - focused client shimmer with per-character support
-- • Launcher widget - continuous shimmer animation
-- • Tag hover system - smooth fade transitions with color interpolation
-- • Phase offset management - different timing for each component type
--
-- HOVER SYSTEM:
-- • Mouse enter: applies shimmer/gold with unique phase per tag
-- • Mouse leave: smooth fade using color interpolation over 15 steps
-- • Per-character aware: handles both solid and per-character fade modes
-- • Theme integration: fades to beautiful.taglist_fg_empty colors
--
-- PHASE OFFSETS:
-- • tag_phase = 0.0    (base timing)
-- • task_phase = 1.0   (offset for variety)
-- • launcher_phase = 2.0 (further offset)
-- • border_phase - managed by border module, tasklist, launcher

local gears = require("gears")
local awful = require("awful")

local M = {}

-- // MARK: CONSTANT FOLDING & MATH OPTIMIZATION
-- pre-calculated mathematical constants
local HALF = 0.5

-- cached math functions for performance
local math_floor, math_max, math_min = math.floor, math.max, math.min
local string_format = string.format
local tostring = tostring

-- // MARK: CONFIGURATION STATE

-- shimmer configuration with phase offsets for component timing variety
local shimmer_config = {
    tag_phase = 0.0,
    task_phase = 0.3,
    launcher_phase = 0.6,
    per_letter = {
        tags = true,
        tasks = true,
        launcher = false
    }
}

-- static text cache: cache markup for unchanging content
-- cache: stable text -> ready-made markup; avoids regen for static labels
local static_text_cache = {}
local STATIC_CACHE_MAX_ENTRIES = 100  -- limit cache size
local static_cache_stats = { hits = 0, misses = 0, size = 0 }

-- generate cache key for static text
local function get_static_cache_key(text, phase_offset, per_letter)
    return text .. "|" .. (phase_offset or 0) .. "|" .. tostring(per_letter or false)
end

-- attach hover wiring for a tag widget
function M.attach_tag_hover(tag_widget, tag)
    if not tag_widget or not tag then return end -- guard
    -- wire mouse enter/leave to existing hover handler
    tag_widget:connect_signal('mouse::enter', function()
        M.handle_tag_hover(tag_widget, tag, "enter")
    end)
    tag_widget:connect_signal('mouse::leave', function()
        M.handle_tag_hover(tag_widget, tag, "leave")
    end)
end

-- apply tasklist fg and status_prefix color safely
function M.apply_tasklist_safety(container, c)
    if not container or not c then return end
    local beautiful = require("beautiful")
    -- container fg to avoid white flashes
    local br = container:get_children_by_id('background_role')[1]
    if br then
        local unfocused = beautiful.tasklist_fg_normal or "#c0c0c0"
        br.fg = (c == client.focus) and (beautiful.tasklist_fg_focus or "#d2b48c") or unfocused
    end
    -- recolor status_prefix to match state
    local sp = container:get_children_by_id('status_prefix')[1]
    if sp then
        local txt = sp.get_text and sp:get_text() or ""
        local safe = (gears.string and gears.string.xml_escape and gears.string.xml_escape(txt)) or txt
        local color = (c == client.focus) and (beautiful.tasklist_fg_focus or "#d2b48c") or (beautiful.tasklist_fg_normal or "#c0c0c0")
        sp.markup = '<span color="' .. color .. '\">' .. (safe or "") .. '</span>'
    end
end

-- refresh all tasklists across screens
function M.refresh_all_tasklists()
    for s in screen do
        if s.mytasklist then
            s.mytasklist:emit_signal("widget::layout_changed")
            s.mytasklist:emit_signal("widget::redraw_needed")
        end
    end
end

-- forward declaration for get_animation function
local get_animation

-- get or generate cached markup for static text
local function get_cached_static_markup(text, phase_offset, options)
    if not text or text == "" then return "" end
    
    local animation = require("plugins.shimmer.animation")
    local per_letter = animation.should_use_per_character(options)
    local cache_key = get_static_cache_key(text, phase_offset, per_letter)
    
    -- check cache first
    if static_text_cache[cache_key] then
        static_cache_stats.hits = static_cache_stats.hits + 1
        return static_text_cache[cache_key]
    end
    
    -- cache miss - generate markup
    static_cache_stats.misses = static_cache_stats.misses + 1
    local markup = animation.get_letter_shimmer_markup(text, phase_offset, options)
    
    -- store in cache
    static_text_cache[cache_key] = markup
    static_cache_stats.size = static_cache_stats.size + 1
    
    -- cleanup if cache gets too large
    if static_cache_stats.size > STATIC_CACHE_MAX_ENTRIES then
        -- clear 25% of cache entries
        local new_cache = {}
        local count = 0
        local keep_count = math_floor(STATIC_CACHE_MAX_ENTRIES * 0.75)
        
        for key, value in pairs(static_text_cache) do
            if count < keep_count then
                new_cache[key] = value
                count = count + 1
            end
        end
        
        static_text_cache = new_cache
        static_cache_stats.size = count
    end
    
    return markup
end

-- // MARK: WIDGET TRACKING

-- widget registration and reference storage
local registered_widgets = {
    taglist = {},  -- [screen_index][tag] = widget
    tasklist = {},
    tasklist_clients = {},  -- [client] = text_widget for direct shimmer updates
    launcher = nil
}

local last_applied_colors = {}  -- [text_widget] = {color, title}

-- widget update locks to prevent race conditions between multiple callbacks
local widget_update_locks = {}  -- [text_widget] = true when locked

-- // MARK: MODULE DEPENDENCIES

-- get animation functions (lazy loading to avoid circular deps)
local get_animation
get_animation = function()
    return require("plugins.shimmer.animation")
end

-- // MARK: TAGLIST INTEGRATION

-- simplified taglist registration - map individual tag widgets to their tags
function M.register_taglist(taglist_widget, screen_index, tag)
    if not registered_widgets.taglist[screen_index] then
        registered_widgets.taglist[screen_index] = {}
    end
    -- store widget by tag reference for proper mapping
    if tag then
        registered_widgets.taglist[screen_index][tag] = taglist_widget
    else
        -- backward compatibility - store as array
        table.insert(registered_widgets.taglist[screen_index], taglist_widget)
    end
end

-- // MARK: TASKLIST INTEGRATION

-- simplified tasklist registration  
function M.register_tasklist(tasklist_widget)
    table.insert(registered_widgets.tasklist, tasklist_widget)
    
    -- immediately check for focused client and apply shimmer
    local focused = client.focus
    if focused then
        -- force tasklist content update by triggering property changes
        focused:emit_signal("property::name")
        focused:emit_signal("property::class")
        tasklist_widget:emit_signal("widget::redraw_needed")
        
        -- defer shimmer application to prevent startup blocking
            local text_widget = registered_widgets.tasklist_clients[focused]
            if text_widget then
                local title = focused.name or focused.class or ""
                if title ~= "" then
                    local animation = get_animation()
                    local options = {
                        phase_offset = shimmer_config.task_phase
                    }
                    animation.apply_to_widget(text_widget, title, nil, options)
                end
            end
            return false
    end
end

-- helper function to apply color with flash prevention and race condition protection
local function apply_color_safe(text_widget, title, color, is_shimmer)
    if not text_widget or not title or title == "" then return end
    
    -- prevent race conditions by locking widget during update
    local animation = get_animation()
    if animation.is_widget_locked(text_widget) then
        return -- widget is locked, skip this update
    end
    
    animation.set_widget_lock(text_widget)
    
    -- check if we're applying the same color/title combination
    local last_state = last_applied_colors[text_widget]
    if last_state and last_state.color == color and last_state.title == title then
        animation.clear_widget_lock(text_widget)
        return -- no change needed
    end
    
    -- apply immediately using original methods to bypass our protection
    if is_shimmer then
        -- for shimmer, use apply_to_widget which handles markup properly
        local animation = get_animation()
        local options = { phase_offset = shimmer_config.task_phase }
        animation.apply_to_widget(text_widget, title, nil, options)
        -- clear any static cache so protection won't block shimmer updates
        last_applied_colors[text_widget] = nil
    else
        -- for static color, use original markup method to bypass protection
        local markup = '<span color="' .. color .. '">' .. gears.string.xml_escape(title) .. '</span>'
        if text_widget.__original_set_markup then
            text_widget.__original_set_markup(text_widget, markup)
        else
            text_widget:set_markup(markup)
        end
        last_applied_colors[text_widget] = {color = color, title = title}
    end
    
    -- unlock widget after update
    animation.clear_widget_lock(text_widget)
end

-- override widget methods to prevent external interference
local function protect_widget_from_interference(widget)
    if not widget or widget.__shimmer_protected then return end
    
    -- store original methods
    widget.__original_set_text = widget.set_text
    widget.__original_set_markup = widget.set_markup
    widget.__shimmer_protected = true
    
    -- override set_text to preserve shimmer colors
    -- gate plain text when shimmer has applied color, to prevent flicker
    widget.set_text = function(self, text)
        -- if shimmer has applied colors, ignore plain text calls
        if last_applied_colors[self] then
            return -- ignore external plain text calls
        end
        return self.__original_set_text(self, text)
    end
    
    -- override set_markup to only allow shimmer markup
    -- only accept colored markup while shimmer controls the widget
    widget.set_markup = function(self, markup)
        -- if this is a shimmer-controlled widget and the markup doesn't contain color spans, ignore it
        -- allow both 'color' and 'foreground' attributes used by Pango markup
        if last_applied_colors[self] then
            local has_color = markup:match('<span[^>]*color[^>]*>')
            local has_foreground = markup:match('<span[^>]*foreground[^>]*>')
            if not (has_color or has_foreground) then
                return -- ignore external plain markup calls
            end
        end
        return self.__original_set_markup(self, markup)
    end
end

-- tasklist update callback for shimmer integration with per-character support
function M.tasklist_update_callback(self, c, index, objects)
        local tb = self:get_children_by_id('text_role')[1]
        if tb and c then
            -- protect widget from external interference
            protect_widget_from_interference(tb)
            
            -- store client->widget mapping for continuous shimmer updates
            registered_widgets.tasklist_clients[c] = tb
            
            -- always check if this client is focused and apply shimmer accordingly
            local is_focused = (c == client.focus)
            local title = c.name or c.class or ""
            
            if title ~= "" then
                if is_focused then
                    apply_color_safe(tb, title, nil, true) -- shimmer mode
                else
                    -- for unfocused clients, use current shimmer color to avoid white flash
                    local animation = get_animation()
                    local current_color = animation.get_color(nil, #title, shimmer_config.task_phase)
                    apply_color_safe(tb, title, current_color, false) -- static color mode
                end
            end
        end
        return false
end

-- // MARK: LAUNCHER INTEGRATION

-- launcher registration for continuous shimmer
function M.register_launcher(launcher_widget)
    registered_widgets.launcher = launcher_widget
    if launcher_widget and launcher_widget.set_markup then
        local animation = get_animation()
        -- disable per-character shimmer for launcher to avoid UTF-8 issues
        local launcher_options = {
            phase_offset = shimmer_config.launcher_phase,
            per_letter = false  -- force solid color for launcher
        }
        animation.apply_to_widget(launcher_widget, 'gear', nil, launcher_options)
    end
end

-- // MARK: TAG HOVER SYSTEM

-- tag hover handler with smooth fade transitions and per-character support
function M.handle_tag_hover(tag_widget, tag, mode)
    local text_widget = tag_widget and tag_widget:get_children_by_id('text_role')[1]
    if not text_widget or not text_widget.set_markup then return end
    
    local current = tag.name or ''
    local animation = get_animation()
    local base_gold = animation.get_base_gold()
    
    if mode == "enter" then
        if tag.selected then return end
        
        local dnd_to_tag = package.loaded["plugins.dnd_to_tag"]
        if dnd_to_tag and dnd_to_tag.drag_active then
            -- when dragging, delegate hover to dnd module and skip shimmer hover FX
            dnd_to_tag.set_hover(tag, tag_widget)
            return
        end
        
        text_widget.__hover_lock = true
        
        -- use per-character shimmer if enabled, otherwise use current palette gold
        if animation.should_use_per_character() then
            -- each tag gets slightly different hover phase for variety
            local hover_phase = shimmer_config.tag_phase + (tag.index or 1) * 0.3
            local hover_options = { per_character_mode = animation.get_per_character_mode() }
            local hover_markup = animation.get_letter_shimmer_markup(current, hover_phase, hover_options)
            text_widget:set_markup(hover_markup)
        else
            -- use current palette color for consistent gold shine
            local palette_color = animation.get_color(nil, 1, shimmer_config.tag_phase + (tag.index or 1) * 0.3)
            text_widget:set_markup('<span color="' .. palette_color .. '">' .. current .. '</span>')
        end
        
        tag_widget.__hover_text_colored = true
        
    elseif mode == "leave" then
        -- when dragging, clear dnd hover and skip shimmer leave FX
        local dnd_to_tag = package.loaded["plugins.dnd_to_tag"]
        if dnd_to_tag and dnd_to_tag.drag_active then
            dnd_to_tag.clear_hover()
            return
        end
        if tag_widget.__hover_text_colored then
            text_widget.__hover_lock = nil
            tag_widget.__hover_text_colored = nil

            if tag.selected then
                local options = {
                    phase_offset = shimmer_config.tag_phase,
                    per_letter = shimmer_config.per_letter.tags
                }
                animation.apply_to_widget(text_widget, current, nil, options)
            else
                if text_widget.__hover_fade_timer and text_widget.__hover_fade_timer.stop then
                    text_widget.__hover_fade_timer:stop()
                end
                
                local fade_steps = 20
                local fade_duration = 1.5
                local step_time = fade_duration / fade_steps
                local step = 0
                
                -- determine fade target based on theme with better fallbacks
                local beautiful = require("beautiful")
                local animation = get_animation()
                
                -- improved fade target selection with debug info
                local fade_target
                if beautiful.taglist_fg_empty then
                    fade_target = beautiful.taglist_fg_empty
                elseif beautiful.fg_normal then
                    fade_target = beautiful.fg_normal  -- use theme color directly
                else
                    -- instead of harsh white, use a warm neutral
                    fade_target = "#c0c0c0"  -- light gray instead of white
                end
                
                text_widget.__hover_fade_timer = gears.timer {
                    timeout = step_time,
                    autostart = true,
                    callback = function()
                        step = step + 1
                        local linear_progress = step / fade_steps
                        
                        -- easing curves for smoother fade animation
                        local progress
                        if linear_progress >= 1.0 then
                            progress = 1.0
                        else
                            -- ease-out cubic: fast start, slow end (most natural for fade out)
                            progress = 1 - (1 - linear_progress)^3
                            
                            -- alternative easing options (comment/uncomment to try):
                            -- ease-in-out cubic: slow start and end, fast middle
                            -- progress = linear_progress < HALF and 4 * linear_progress^3 or 1 - (-2 * linear_progress + 2)^3 / 2
                            
                            -- ease-out quad: gentler curve
                            -- progress = 1 - (1 - linear_progress)^2
                            
                            -- ease-out exponential: very fast start, very slow end
                            -- progress = linear_progress == 1 and 1 or 1 - 2^(-10 * linear_progress)
                        end
                        
                        if animation.should_use_per_character() then
                            -- fade per-character shimmer to plain text
                            local hover_phase = shimmer_config.tag_phase + (tag.index or 1) * 0.3
                            local fade_options = { per_character_mode = animation.get_per_character_mode() }
                            
                            if progress >= 1.0 then
                                text_widget:set_markup('<span color="' .. fade_target .. '">' .. current .. '</span>')
                            else
                                -- gradually reduce shimmer intensity
                                local fade_alpha = 1.0 - progress
                                local shimmer_color = animation.get_color(nil, 1, hover_phase)
                                local interpolated = animation.interpolate_color(shimmer_color, fade_target, progress)
                                text_widget:set_markup('<span color="' .. interpolated .. '">' .. current .. '</span>') 
                            end
                        else
                            -- fade to proper foreground color using simple linear interpolation
                            if progress >= 1.0 then
                                text_widget:set_markup('<span color="' .. fade_target .. '">' .. current .. '</span>')
                            else
                                local hover_phase = shimmer_config.tag_phase + (tag.index or 1) * 0.3
                                local start_color = animation.get_color(nil, 1, hover_phase)
                                
                                -- simple linear RGB interpolation to target color
                                local function lerp_color(c1, c2, t)
                                    local function hex_to_rgb(hex)
                                        if not hex or type(hex) ~= "string" then
                                            return 192, 192, 192  -- fallback to light gray
                                        end
                                        hex = hex:gsub("#", "")
                                        if #hex ~= 6 then
                                            return 192, 192, 192  -- fallback to light gray
                                        end
                                        local r = tonumber(hex:sub(1,2), 16) or 192
                                        local g = tonumber(hex:sub(3,4), 16) or 192
                                        local b = tonumber(hex:sub(5,6), 16) or 192
                                        return r, g, b
                                    end
                                    local r1, g1, b1 = hex_to_rgb(c1)
                                    local r2, g2, b2 = hex_to_rgb(c2)
                                    local r = math_floor(r1 + (r2 - r1) * t)
                                    local g = math_floor(g1 + (g2 - g1) * t)
                                    local b = math_floor(b1 + (b2 - b1) * t)
                                    return string_format("#%02x%02x%02x", r, g, b)
                                end
                                
                                local interpolated = lerp_color(start_color, fade_target, progress)
                                text_widget:set_markup('<span color="' .. interpolated .. '">' .. current .. '</span>')
                            end
                        end
                        
                        if step >= fade_steps then
                            text_widget.__hover_fade_timer:stop()
                            text_widget.__hover_fade_timer = nil
                            text_widget.__hover_fade_lock = nil
                            -- final state: plain text with theme color
                            text_widget:set_markup(current)
                        end
                    end
                }
                
                text_widget.__hover_fade_lock = true
            end
        end
    elseif mode == "dnd_enter" then
        text_widget.__hover_lock = true
        text_widget:set_markup('<span color="' .. base_gold .. '">' .. current .. '</span>')
        tag_widget.__dnd_hover_active = true
        
    elseif mode == "dnd_leave" then
        if tag_widget.__dnd_hover_active then
            text_widget.__hover_lock = nil
            tag_widget.__dnd_hover_active = nil
            if tag.selected then
                local options = {
                    phase_offset = shimmer_config.tag_phase,
                    per_letter = shimmer_config.per_letter.tags
                }
                animation.apply_to_widget(text_widget, current, nil, options)
            else
                if text_widget.__hover_fade_timer and text_widget.__hover_fade_timer.stop then
                    text_widget.__hover_fade_timer:stop()
                end
                text_widget:set_markup(current)
            end
        end
    end
end

-- // MARK: STATIC TEXT CACHE MANAGEMENT

-- clear static text cache (useful when changing presets or settings)
function M.clear_static_cache()
    static_text_cache = {}
    static_cache_stats = { hits = 0, misses = 0, size = 0 }
end

-- get static cache statistics
function M.get_static_cache_stats()
    local hit_rate = static_cache_stats.hits + static_cache_stats.misses > 0 
        and (static_cache_stats.hits / (static_cache_stats.hits + static_cache_stats.misses) * 100) or 0
    return {
        hits = static_cache_stats.hits,
        misses = static_cache_stats.misses,
        size = static_cache_stats.size,
        hit_rate = string_format("%.1f%%", hit_rate),
        max_entries = STATIC_CACHE_MAX_ENTRIES
    }
end

-- // MARK: WIDGET UPDATE SYSTEM

-- update all registered widgets with current shimmer on each animation frame application
-- batch updates for focused screen; one redraw to keep things smooth
function M.update_widgets()
    local animation = get_animation()
    
    -- visibility culling: only process tags on currently focused screen
    local focused_screen = awful.screen.focused()
    if not focused_screen then return end  -- no focused screen, skip all updates
    
    -- batch collection: collect all widget updates before applying
    local batch_updates = {}
    
    -- collect tag widget updates for focused screen
    local screen_index = focused_screen.index
    local tag_widgets = registered_widgets.taglist[screen_index]
    if tag_widgets then
        for _, tag in pairs(focused_screen.tags) do
            local widget = tag_widgets[tag]  -- get specific widget for this tag
            if widget then
                local text_widget = widget:get_children_by_id('text_role')[1]
                if text_widget and not text_widget.__hover_lock and not text_widget.__hover_fade_lock then
                    if tag.selected then
                        -- use static cache for selected tag (tag names rarely change)
                        local options = {
                            phase_offset = shimmer_config.tag_phase
                            -- removed per_letter override to allow global toggle
                        }
                        local markup = get_cached_static_markup(tag.name or "", options.phase_offset, options)
                        table.insert(batch_updates, {widget = text_widget, markup = markup})
                    else
                        -- collect plain text for unselected tags
                        table.insert(batch_updates, {widget = text_widget, markup = tag.name or ""})
                    end
                end
            end
        end
    end
    
    -- collect focused client update if it's on the focused screen
    local focused = client.focus
    if focused and focused.screen == focused_screen then
        local text_widget = registered_widgets.tasklist_clients[focused]
        if text_widget and not text_widget.__hover_lock then
            local title = focused.name or focused.class or ""
            if title ~= "" then
                local options = {
                    phase_offset = shimmer_config.task_phase
                    -- removed per_letter override to allow global toggle
                }
                local markup = animation.get_letter_shimmer_markup(title, options.phase_offset, options)
                table.insert(batch_updates, {widget = text_widget, markup = markup})
            end
        end
    end
    
    -- collect launcher update if registered (use static cache - 'gear' text never changes)
    if registered_widgets.launcher then
        local launcher_options = {
            phase_offset = shimmer_config.launcher_phase,
            per_letter = false  -- force solid color for launcher
        }
        local markup = get_cached_static_markup('gear', launcher_options.phase_offset, launcher_options)
        table.insert(batch_updates, {widget = registered_widgets.launcher, markup = markup})
    end
    
    -- batch apply: apply all collected updates in single pass
    for _, update in ipairs(batch_updates) do
        local widget = update.widget
        local markup = update.markup
        
        -- use original method if widget is protected, otherwise use normal method
        if widget.__original_set_markup then
            widget.__original_set_markup(widget, markup)
        else
            widget:set_markup(markup)
        end
    end
    
    -- single tasklist redraw after all updates are complete
    if focused and focused.screen == focused_screen then
        local focused_tasklist = registered_widgets.tasklist[screen_index]
        if focused_tasklist then
            -- defer redraw slightly to allow batch updates to complete first
            gears.timer.start_new(0.01, function()
                focused_tasklist:emit_signal("widget::redraw_needed")
                return false
            end)
        end
    end
end

-- initialize shimmer for currently focused client (called after system startup)
function M.initialize_focused_client()
    local focused = client.focus
    if focused then
        -- manually scan tasklist widgets to find focused client widget
        for _, tasklist in pairs(registered_widgets.tasklist) do
            -- force tasklist to rebuild by triggering client property changes
            focused:emit_signal("property::name")
            focused:emit_signal("property::class")
            tasklist:emit_signal("widget::redraw_needed")
        end
        
        -- immediate direct widget application attempt
        local text_widget = registered_widgets.tasklist_clients[focused]
        if text_widget then
            local title = focused.name or focused.class or ""
            if title ~= "" then
                local animation = get_animation()
                local options = {
                    phase_offset = shimmer_config.task_phase
                }
                animation.apply_to_widget(text_widget, title, nil, options)
            end
        else
            -- fallback with reasonable delay to prevent blocking
            -- gears.timer.start_new(0.15, function()
                local text_widget = registered_widgets.tasklist_clients[focused]
                if text_widget then
                    local title = focused.name or focused.class or ""
                    if title ~= "" then
                        local animation = get_animation()
                        local options = {
                            phase_offset = shimmer_config.task_phase
                        }
                        animation.apply_to_widget(text_widget, title, nil, options)
                    end
                end
                return false
            -- end)
        end
    end
end

-- setup client focus signal handling to ensure shimmer on focus changes
function M.setup_focus_signals()
    -- connect to client focus signal to ensure shimmer is applied
    client.connect_signal("focus", function(c)
        -- immediate update without delay
        M.update_widgets()
        
        -- force tasklist content update by triggering property changes
        if c then
            c:emit_signal("property::name")
            c:emit_signal("property::urgent")
            c:emit_signal("property::minimized")
        end
        
        -- also force tasklist redraw to ensure widget mapping
        for _, tasklist in pairs(registered_widgets.tasklist) do
            tasklist:emit_signal("widget::redraw_needed")
        end
    end)
    
    -- also connect to unfocus to maintain color consistency for unfocused clients
    client.connect_signal("unfocus", function(c)
        local text_widget = registered_widgets.tasklist_clients[c]
        if text_widget then
            local title = c.name or c.class or ""
            if title ~= "" then
                -- use current shimmer color instead of plain text to avoid white flash
                local animation = get_animation()
                local current_color = animation.get_color(nil, #title, shimmer_config.task_phase)
                apply_color_safe(text_widget, title, current_color, false)
            end
        end
    end)
    
    -- connect to client property changes to handle title updates smoothly
    client.connect_signal("property::name", function(c)
        local text_widget = registered_widgets.tasklist_clients[c]
        if text_widget and not text_widget.__hover_lock then
            local title = c.name or c.class or ""
            if title ~= "" then
                local is_focused = (c == client.focus)
                if is_focused then
                    apply_color_safe(text_widget, title, nil, true) -- shimmer mode
                else
                    -- use current shimmer color for unfocused to avoid white flash
                    local animation = get_animation()
                    local current_color = animation.get_color(nil, #title, shimmer_config.task_phase)
                    apply_color_safe(text_widget, title, current_color, false)
                end
            end
        end
    end)
    
    -- connect to client list changes to handle startup scenarios
    client.connect_signal("list", function()
        -- gears.timer.start_new(0.1, function()
            M.update_widgets()
            return false
        -- end)
    end)
end

-- getter function for registered tasklists
function M.get_registered_tasklists()
    return registered_widgets.tasklist
end

-- // MARK: CONFIGURATION FUNCTIONS

-- phase offset configuration functions
function M.set_phase_offsets(config)
    if config.tag_phase ~= nil then shimmer_config.tag_phase = config.tag_phase end
    if config.task_phase ~= nil then shimmer_config.task_phase = config.task_phase end
    if config.launcher_phase ~= nil then shimmer_config.launcher_phase = config.launcher_phase end
end

function M.get_phase_offsets()
    return {
        tag_phase = shimmer_config.tag_phase,
        task_phase = shimmer_config.task_phase,
        launcher_phase = shimmer_config.launcher_phase
    }
end

-- per-letter mode configuration functions
function M.set_per_letter_modes(config)
    if config.tags ~= nil then shimmer_config.per_letter.tags = config.tags end
    if config.tasks ~= nil then shimmer_config.per_letter.tasks = config.tasks end
    if config.launcher ~= nil then shimmer_config.per_letter.launcher = config.launcher end
end

function M.get_per_letter_modes()
    return {
        tags = shimmer_config.per_letter.tags,
        tasks = shimmer_config.per_letter.tasks,
        launcher = shimmer_config.per_letter.launcher
    }
end

-- internal accessor for registered widgets map (for cooperating modules)
-- intentionally underscored to signify internal use
function M._get_registered_widgets()
    return registered_widgets
end

return M
