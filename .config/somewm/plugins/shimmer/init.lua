-- plugins/shimmer/init.lua
-- Unified shimmer animation system for AwesomeWM
-- facade module: flattens exports from animation/integrations/border
-- Main interface module - flattened API for easy access
--
-- SYSTEM OVERVIEW:
-- This module provides a unified shimmer system with the following components:
-- • Text shimmer effects (solid color or per-character)
-- • Window border shimmer animation
-- • Widget integration (tags, tasks, launcher)
-- • Preset management with cycling support
-- • Per-character toggle independent of presets
--
-- USAGE:
-- shimmer.configure({ preset = "debug", border = { smoothness = 3 }, disable_shine = false, disable_color = false, max_animated_chars = 5 })
-- shimmer.cycle_preset()                 -- cycle through presets
-- shimmer.set_mode("candle")             -- set specific preset
-- shimmer.cycle_colour_prog_mode(±1)     -- cycle colour progression modes
-- shimmer.cycle_shine_prog_mode(±1)      -- cycle shine progression modes
-- shimmer.set_shine_speed(0)             -- disable shine aspect (0 = disabled)
-- shimmer.set_color_speed(0)             -- disable color aspect (0 = disabled)
-- shimmer.set_global_max_animated_chars(5)  -- limit animated characters globally (nil = use preset defaults)
--
-- HOTKEYS (defined in keybindings.lua):
-- Mod4+Shift+Alt+c         = cycle presets
-- Mod4+Shift+Alt+[         = colour prog back;   Mod4+Shift+Alt+] = colour prog forward
-- Mod4+Shift+Alt+{         = shine prog back;    Mod4+Shift+Alt+} = shine prog forward
-- Mod4+Shift+Alt+1-5,0     = specific presets
-- Mod4+Shift+Alt+F1/F2     = decrease/increase colour speed
-- Mod4+Shift+Alt+F3/F4     = decrease/increase shine speed

local gears = require("gears")
local naughty = require("naughty")
local animation = require("plugins.shimmer.animation")
local border = require("plugins.shimmer.border") 
local integrations = require("plugins.shimmer.integrations")
local beautiful = require("beautiful")  -- Theme handling library

local M = {}

-- // MARK: CONSTANT FOLDING & MATH OPTIMIZATION
-- cached string functions for performance
local string_format = string.format


-- // MARK: NOTIFICATION MANAGEMENT

-- single notification tracking to prevent clutter during rapid cycling
local current_notification = nil
local notification_persistent = false  -- toggle for persistent notifications
local notification_width = 530  -- notification width matches rc.lua NOTIFICATION_WIDTH

-- single-shot notifier; always clears previous to avoid stacking
local function show_shimmer_notification(title, text, timeout)
    -- dismiss any existing shimmer notification
    if current_notification and current_notification.destroy then
        current_notification:destroy()
        current_notification = nil
    end
    
    -- use persistent timeout if enabled, otherwise use provided timeout
    local actual_timeout = notification_persistent and 0 or (timeout or 3)
    
    -- show new notification and track it
    current_notification = naughty.notify({
        title = title,
        text = text,
        timeout = actual_timeout,
        bg = (beautiful.main_purple and beautiful.main_purple.base) or "#5330EA",     -- darker, more purple background
        fg = beautiful.fg_normal or "#f1f5f9",     -- slightly brighter text for better contrast
        border_color = beautiful.main_orange or "#f97316",  -- orange border
        border_width = 1,
        font = "monospace 9",
        width = notification_width,        -- even wider notification to prevent line wrapping
        -- position = "top_middle"  -- force top position for visibility
    })
    
    return current_notification
end

-- run a tiny deferred init once awesome has built early widgets
function M.post_startup_init()
    -- defer a frame to allow tasklists to exist
    gears.timer.start_new(0.05, function()
        -- trigger tasklist redraws to establish widget mappings
        for s in screen do
            if s.mytasklist then
                s.mytasklist:emit_signal("widget::redraw_needed")
            end
        end
        -- force shimmer update for focused client
        if M.initialize_focused_client then
            M.initialize_focused_client()
        end
        return false
    end)
end

-- toggle notification persistence
function M.toggle_notification_persistence()
    notification_persistent = not notification_persistent
    local status = notification_persistent and "persistent" or "5 second timeout"
    
    if notification_persistent then
        -- when turning persistent on, show status immediately (it will be persistent)
        M.show_current_state_notify()
        -- then briefly show the toggle message as a temporary overlay
        gears.timer.start_new(0.2, function()
            naughty.notify({
                title = "shimmer notifications",
                text = "notifications now: " .. status,
                timeout = 3,
                bg = (beautiful.main_purple and beautiful.main_purple.base) or "#5330CA",
                fg = beautiful.fg_normal or "#f1f5f9",
                border_color = beautiful.main_orange or "#f97316",
                border_width = 1,
                font = "monospace 9",
                width = notification_width,
                -- position = "top_middle"  -- force top position for visibility
            })
            return false  -- don't repeat
        end)
    else
        -- when turning persistent off, just show the toggle message
        show_shimmer_notification("shimmer notifications", "notifications now: " .. status, 3)
    end
    
    return notification_persistent
end
-- unified notification function that dismisses previous notifications




-- // MARK: USER-FACING FUNCTIONS
-- primary interface functions for end users

-- unified shimmer control with notification: direction -1=back, 0=show, 1=forward
-- central control entry: direction -1=back, 0=show-only, 1=forward  
function M.shimmer_control_notify(control_type, direction)
    direction = direction or 0  -- default to show only
    
    -- special case: if control_type is "copyable_preset", show copyable state
    if control_type == "copyable_preset" then
        M.show_state_as_copyable_preset()
        return
    end
    
    -- perform the cycling action if direction is not 0
    if direction ~= 0 then
        if control_type == "preset" then
            animation.cycle_preset(direction)
        elseif control_type == "color_prog" then
            animation.cycle_colour_prog_mode(direction)
        elseif control_type == "shine_prog" then
            animation.cycle_shine_prog_mode(direction)
        elseif control_type == "progression" then
            -- legacy: cycle both color and shine together
            animation.cycle_per_character_mode(direction)
        end
    end
    
    -- always show current state after any change
    M.show_current_state_notify()
end

-- show current shimmer state without cycling

-- show current shimmer state as copyable preset text
function M.show_state_as_copyable_preset()
    -- gather all current state information
    local current_preset = animation.get_current_preset()
    local preset_config = animation.get_preset_config(current_preset)
    local colour_mode = animation.get_colour_prog_mode()
    local shine_mode = animation.get_shine_prog_mode()
    local per_char_mode = animation.get_per_character_mode()
    local should_use_per_char = animation.should_use_per_character()
    
    -- format as proper lua preset definition
    local preset_name = current_preset and (current_preset .. "_custom") or "custom_preset"
    local comment = string.format("-- exported from: %s (color: %s, shine: %s)", 
        current_preset or "unknown", colour_mode or "off", shine_mode or "off")
    
    local preset_text = string.format([[%s
%s = {
    -- color generation
    color_gen = {
        type = "%s",
        params = {%s
        }
    },
    -- progression modes
    progression = {
        color_mode = "%s",
        shine_mode = "%s"
    },
    -- animation settings
    animation = {
        speed = %s,
        color_speed = %s,
        shine_speed = %s,
        per_character_default = %s%s%s
    }
},]], 
        comment,
        preset_name,
        preset_config and preset_config.color_gen_type or "gradient",
        preset_config and preset_config.color_gen_params and 
            M.format_color_params({type = preset_config.color_gen_type, params = preset_config.color_gen_params}) or "\n            -- params not available",
        colour_mode or "uniform",
        shine_mode or "uniform", 
        preset_config and preset_config.speed or "0.15",
        preset_config and preset_config.color_speed or "1.0",
        preset_config and preset_config.shine_speed or "1.0",
        preset_config and tostring(preset_config.per_character_default) or "false",
        preset_config and preset_config.max_animated_chars and 
            string.format(",\n        max_animated_chars = %s", preset_config.max_animated_chars) or "",
        preset_config and preset_config.char_selection_strategy and 
            string.format(",\n        char_selection_strategy = \"%s\"", preset_config.char_selection_strategy) or ""
    )
    
    -- show as notification for copying
    naughty.notify({
        title = "shimmer preset (right-click to copy)",
        text = preset_text,
        timeout = 0,  -- persistent until clicked
        bg = (beautiful.main_purple and beautiful.main_purple.base) or "#623997",
        fg = beautiful.fg_normal or "#f1f5f9",
        border_color = beautiful.main_orange or "#f97316",
        border_width = 2,
        font = "monospace 7",
        width = notification_width + 150,  -- wider for config text
        position = "top_middle"  -- prominent position for copying
    })
end

-- helper to format color generation parameters
function M.format_color_params(color_gen)
    if not color_gen or not color_gen.params then
        return "\n            -- params not available"
    end
    
    local params = color_gen.params
    local formatted = {}
    
    -- format different parameter types
    if color_gen.type == "gradient" then
        if params.redFrequency then table.insert(formatted, string.format("redFrequency = %s", params.redFrequency)) end
        if params.grnFrequency then table.insert(formatted, string.format("grnFrequency = %s", params.grnFrequency)) end  
        if params.bluFrequency then table.insert(formatted, string.format("bluFrequency = %s", params.bluFrequency)) end
        if params.phase1 then table.insert(formatted, string.format("phase1 = %s", params.phase1)) end
        if params.phase2 then table.insert(formatted, string.format("phase2 = %s", params.phase2)) end
        if params.phase3 then table.insert(formatted, string.format("phase3 = %s", params.phase3)) end
        if params.center then table.insert(formatted, string.format("center = %s", params.center)) end
        if params.width then table.insert(formatted, string.format("width = %s", params.width)) end
    elseif color_gen.type == "hsv" then
        if params.hue_base then table.insert(formatted, string.format("hue_base = %s", params.hue_base)) end
        if params.hue_variation then table.insert(formatted, string.format("hue_variation = %s", params.hue_variation)) end
        if params.sat_base then table.insert(formatted, string.format("sat_base = %s", params.sat_base)) end
        if params.sat_variation then table.insert(formatted, string.format("sat_variation = %s", params.sat_variation)) end
        if params.value_min then table.insert(formatted, string.format("value_min = %s", params.value_min)) end
        if params.value_max then table.insert(formatted, string.format("value_max = %s", params.value_max)) end
        if params.shine_frequency then table.insert(formatted, string.format("shine_frequency = %s", params.shine_frequency)) end
    end
    
    if #formatted > 0 then
        return "\n            " .. table.concat(formatted, ",\n            ")
    else
        return "\n            -- no params available"
    end
end

-- show current shimmer state without cycling
-- state reporter: fixed columns for clean alignment in monospace
function M.show_current_state_notify()
    local current_preset = animation.get_current_preset()
    
    -- get preset index
    local preset_list = animation.get_preset_list()
    local preset_index = 1
    for i, preset in ipairs(preset_list) do
        if preset == current_preset then preset_index = i break end
    end
    local preset_count = #preset_list
    
    -- get separate color and shine progression modes
    local color_mode = animation.get_color_progression_mode()
    local shine_mode = animation.get_shine_progression_mode()
    local color_modes_list = (animation.get_colour_progression_modes_list and animation.get_colour_progression_modes_list())
        or animation.get_progression_modes_list()
    local shine_modes_list = (animation.get_shine_progression_modes_list and animation.get_shine_progression_modes_list())
        or animation.get_progression_modes_list()
    
    local color_index, shine_index = 1, 1
    for i, mode in ipairs(color_modes_list) do
        if mode == color_mode then color_index = i break end
    end
    for i, mode in ipairs(shine_modes_list) do
        if mode == shine_mode then shine_index = i break end
    end
    
    -- build notification lines with aligned colons and 0-based indexing (0 = off)
    local preset_display_index = current_preset == "static_gold" and 0 or (preset_index - 1)
    local preset_total_count = preset_count - 1
    
    -- show separate color and shine progression modes
    local color_display_index = (color_mode == "colour_prog_off") and 0 or (color_index - 1)
    local color_total_count = #color_modes_list - 1
    
    local shine_display_index = (shine_mode == "shine_prog_off") and 0 or (shine_index - 1)
    local shine_total_count = #shine_modes_list - 1
    
    -- calculate dynamic padding based on maximum possible name lengths
    -- find longest preset name
    local max_preset_length = 0
    for _, preset in ipairs(preset_list) do
        max_preset_length = math.max(max_preset_length, #preset)
    end
    
    -- find longest mode name across both lists
    local max_mode_length = 0
    for _, mode in ipairs(color_modes_list) do max_mode_length = math.max(max_mode_length, #mode) end
    for _, mode in ipairs(shine_modes_list) do max_mode_length = math.max(max_mode_length, #mode) end
    
    local max_name_length = math.max(max_preset_length, max_mode_length)
    
    -- calculate maximum possible index width for proper alignment
    local max_possible_preset_index = preset_total_count
    local max_possible_mode_index = math.max(color_total_count, shine_total_count)
    local max_index = math.max(max_possible_preset_index, max_possible_mode_index)
    local max_total = math.max(preset_total_count, color_total_count, shine_total_count)
    local index_width = string.len(tostring(max_index))
    local total_width = string.len(tostring(max_total))
    
    -- calculate selection text with fixed width for alignment
    local selection_width = index_width + 1 + total_width  -- "N/NN" format
    local preset_selection = string_format("%" .. index_width .. "d/%d", preset_display_index, preset_total_count)
    local color_selection = string_format("%" .. index_width .. "d/%d", color_display_index, color_total_count)
    local shine_selection = string_format("%" .. index_width .. "d/%d", shine_display_index, shine_total_count)
    
    -- build lines with new format, include preset and progression speeds
    local preset_cfg = animation.get_preset_config and animation.get_preset_config(current_preset) or nil
    local preset_speed = (preset_cfg and preset_cfg.speed) and preset_cfg.speed or 0

    -- Build left portions (no speeds) to compute alignment column
    local preset_left = string_format("     preset %s: %s", preset_selection, current_preset)
    local color_left  = string_format("colour prog %s: %s", color_selection, color_mode)
    local shine_left  = string_format(" shine prog %s: %s", shine_selection, shine_mode)
    local left_width  = math.max(#preset_left, #color_left, #shine_left)

    -- Get speed info and effective timing/fps (see animation.get_speed_breakdown)
    local speed_breakdown = animation.get_speed_breakdown()
    local fps_display = speed_breakdown.fps >= (speed_breakdown.max_fps or speed_breakdown.fps)
        and string_format("%.1ffps", speed_breakdown.fps)
        or string_format("%.2ffps", speed_breakdown.fps)
    local effective_ms = math.floor((speed_breakdown.effective_interval_ms or 0) + 0.5)

    -- templating strings provided by user
    local BASE_PREFIX      = "        base rate: "
    local PRESET_LEFT_TPL  = "     preset {PRESET_SELECTION}: {PRESET_NAME}    "
    local COLOR_LEFT_TPL   = "colour prog {COLOR_SELECTION}: {COLOR_MODE}     "
    local SHINE_LEFT_TPL   = " shine prog {SHINE_SELECTION}: {SHINE_MODE}     "
    local SPEED_TAG        = "x"

    -- helper to fill placeholders in templates
    local function fill_template(tpl, kv)
        local s = tpl
        for k, v in pairs(kv) do
            s = s:gsub("%{" .. k .. "%}", v)
        end
        return s
    end

    -- rebuild left labels using templates
    preset_left = fill_template(PRESET_LEFT_TPL, {
        PRESET_SELECTION = preset_selection,
        PRESET_NAME = current_preset,
    })
    color_left = fill_template(COLOR_LEFT_TPL, {
        COLOR_SELECTION = color_selection,
        COLOR_MODE = color_mode,
    })
    shine_left = fill_template(SHINE_LEFT_TPL, {
        SHINE_SELECTION = shine_selection,
        SHINE_MODE = shine_mode,
    })

    -- recalc left column width based on templated labels
    left_width  = math.max(#preset_left, #color_left, #shine_left)

    -- compute visual (desired) effective and real (timer) metrics using consistent rate semantics
    local base_ms = speed_breakdown.base_interval_ms or 100
    local base_fps = 1000 / base_ms
    local preset_mult = (speed_breakdown.global_multiplier or 1.0) * (speed_breakdown.preset_multiplier or 1.0)
    
    -- rate semantics: multiplier affects fps directly, ms inversely
    local preset_eff_fps = base_fps * preset_mult
    local preset_eff_ms = math.floor((1000 / preset_eff_fps) + 0.5)
    
    local color_mult = preset_mult * (speed_breakdown.color_speed or 1.0)
    local shine_mult = preset_mult * (speed_breakdown.shine_speed or 1.0)

    -- helpers to avoid division-by-zero/NaN/inf in formatting
    local function safe_ms_from_fps(fps)
        if not fps or fps ~= fps or fps == math.huge or fps <= 0 then
            return 0, 0
        end
        return math.floor((1000 / fps) + 0.5), fps
    end

    local color_eff_fps = base_fps * color_mult
    local color_eff_ms, _ = safe_ms_from_fps(color_eff_fps)
    local shine_eff_fps = base_fps * shine_mult
    local shine_eff_ms, _ = safe_ms_from_fps(shine_eff_fps)

    local actual_ms = math.floor((speed_breakdown.actual_timer_ms or base_ms) + 0.5)

    -- capping only happens when progression wants faster updates than timer provides
    local color_clamped = color_eff_ms < actual_ms  -- wants faster than timer can give
    local shine_clamped = shine_eff_ms < actual_ms  -- wants faster than timer can give

    -- Define column positions for clearer layout
    local rate_col = left_width + 1   -- column where rate multiplier starts
    local result_col = rate_col + 8   -- column where resulting fps/ms starts
    
    -- Format function - show rate and result, with optional real timing constraint
    local function format_line(left_text, multiplier, result_fps, result_ms, real_ms)
        local rate_pad = math.max(1, rate_col - #left_text)
        local rate_text = string_format("×%.1f", multiplier or 1.0)
        local result_pad = math.max(1, result_col - (rate_col + #rate_text))
        
        -- ensure all values are valid numbers for format
        result_fps = result_fps and (result_fps == result_fps) and math.abs(result_fps) < math.huge and result_fps or 0  -- check for NaN and infinity
        result_ms = result_ms and (result_ms == result_ms) and math.abs(result_ms) < math.huge and math.floor(result_ms + 0.5) or 0  -- check for NaN/infinity then ensure integer
        real_ms = real_ms and (real_ms == real_ms) and math.abs(real_ms) < math.huge and math.floor(real_ms + 0.5) or nil  -- check for NaN/infinity then ensure integer if present
        
        local result_text
        if real_ms and real_ms ~= result_ms then
            -- Show wanted rate with actual timer rate
            if result_ms < real_ms then
                -- wants faster but limited by slower timer
                result_text = string_format("→ %.1f fps %dms (max %dms)", result_fps, result_ms, real_ms)
            else
                -- wants slower but driven by faster timer  
                result_text = string_format("→ %.1f fps %dms @%dms", result_fps, result_ms, real_ms)
            end
        else
            -- Just show the actual time without parens
            result_text = string_format("→ %.1f fps %dms", result_fps, result_ms)
        end
        
        return left_text .. string.rep(" ", rate_pad) .. rate_text .. string.rep(" ", result_pad) .. result_text
    end
    
    -- Base rate line - show just the calculation reference
    local base_label = BASE_PREFIX
    -- base_ms can be fractional (e.g., 1000/60). avoid %d on floats.
    local base_desc = string_format("%.0fms", base_ms)
    local base_line = base_label .. base_desc
    
    -- Format lines showing: rate multiplier → resulting fps/ms (use actual multiplier, not config display value)
    local preset_line = format_line(preset_left, preset_mult, preset_eff_fps, preset_eff_ms)
    -- Always show actual timer for color/shine since they're driven by preset timer
    local color_line = format_line(color_left, (speed_breakdown.color_speed or 1.0), color_eff_fps, color_eff_ms, actual_ms)
    local shine_line = format_line(shine_left, (speed_breakdown.shine_speed or 1.0), shine_eff_fps, shine_eff_ms, actual_ms)

    show_shimmer_notification("shimmer", base_line .. "\n" .. preset_line .. "\n" .. color_line .. "\n" .. shine_line)
end

-- wrapper functions for backwards compatibility
function M.cycle_preset_notify(direction)
    M.shimmer_control_notify("preset", direction or 1)
end

function M.cycle_preset_reverse_notify()
    M.shimmer_control_notify("preset", -1)
end

-- function M.cycle_per_character_mode_notify(direction)
--     M.shimmer_control_notify("progression", direction or 1)
-- end

-- function M.cycle_per_character_mode_reverse_notify()
--     M.shimmer_control_notify("progression", -1)
-- end

-- color progression mode cycling with integrated notifications
function M.cycle_colour_prog_mode_notify(direction)
    direction = direction or 1
    animation.cycle_colour_prog_mode(direction)
    -- show-only after cycling to avoid double step
    M.shimmer_control_notify("color_prog", 0)
end

function M.cycle_colour_prog_mode_reverse_notify()
    return M.cycle_colour_prog_mode_notify(-1)
end

-- shine progression mode cycling with integrated notifications
function M.cycle_shine_prog_mode_notify(direction)
    direction = direction or 1
    animation.cycle_shine_prog_mode(direction)
    -- show-only after cycling to avoid double step
    M.shimmer_control_notify("shine_prog", 0)
end

function M.cycle_shine_prog_mode_reverse_notify()
    return M.cycle_shine_prog_mode_notify(-1)
end


-- increase shimmer speed with notification
function M.increase_speed_notify()
    local current_speed = animation.get_speed_multiplier()
    local new_speed = math.min(current_speed * 1.2, 10.0)  -- larger increment, higher cap
    animation.set_speed_multiplier(new_speed)
    M.shimmer_control_notify("speed", 0)  -- show current state
    return new_speed
end

-- decrease shimmer speed with notification
function M.decrease_speed_notify()
    local current_speed = animation.get_speed_multiplier()
    local new_speed = math.max(current_speed / 1.2, 0.1)  -- larger decrement
    animation.set_speed_multiplier(new_speed)
    M.shimmer_control_notify("speed", 0)  -- show current state
    return new_speed
end

-- reset shimmer speed with notification
function M.reset_speed_notify()
    animation.set_speed_multiplier(1.0)
    M.shimmer_control_notify("speed", 0)  -- show current state
    return 1.0
end


-- colour progression speed controls with notification
function M.increase_color_speed_notify()
    local current = animation.get_color_speed()
    -- if currently disabled (0), jump to minimum active speed
    local new_speed = current == 0 and 0.1 or math.min(current * 1.2, 5.0)
    animation.set_color_speed(new_speed)
    M.shimmer_control_notify("speed", 0)
    return new_speed
end

function M.decrease_color_speed_notify()
    local current = animation.get_color_speed()
    local new_speed = math.max(current / 1.2, 0)  -- allow decreasing to 0 (disabled)
    animation.set_color_speed(new_speed)
    M.shimmer_control_notify("speed", 0)
    return new_speed
end


-- shine progression speed controls with notification
function M.increase_shine_speed_notify()
    local current = animation.get_shine_speed()
    -- if currently disabled (0), jump to minimum active speed
    local new_speed = current == 0 and 0.1 or math.min(current * 1.2, 5.0)
    animation.set_shine_speed(new_speed)
    M.shimmer_control_notify("speed", 0)
    return new_speed
end

function M.decrease_shine_speed_notify()
    local current = animation.get_shine_speed()
    local new_speed = math.max(current / 1.2, 0)  -- allow decreasing to 0 (disabled)
    animation.set_shine_speed(new_speed)
    M.shimmer_control_notify("speed", 0)
    return new_speed
end

-- // MARK: CONVENIENCE FUNCTIONS
-- direct control functions using unified notification system

-- preset controls
function M.preset_forward()
    M.shimmer_control_notify("preset", 1)
end

function M.preset_back()
    M.shimmer_control_notify("preset", -1)
end

-- color progression controls
function M.color_prog_forward()
    M.shimmer_control_notify("color_prog", 1)
end

function M.color_prog_back()
    M.shimmer_control_notify("color_prog", -1)
end

-- shine progression controls
function M.shine_prog_forward()
    M.shimmer_control_notify("shine_prog", 1)
end

function M.shine_prog_back()
    M.shimmer_control_notify("shine_prog", -1)
end

-- show current state
function M.show_status()
    M.shimmer_control_notify("show", 0)
end


-- // MARK: CORE ANIMATION FUNCTIONS
-- basic animation control
M.set_mode = animation.set_mode
M.get_mode = animation.get_mode
M.get_color = animation.get_color
M.start = animation.start
M.stop = animation.stop
M.restart = animation.restart
M.apply_to_widget = animation.apply_to_widget

-- // MARK: PRESET MANAGEMENT
-- preset cycling and management
M.add_preset = animation.add_preset
M.get_preset_list = animation.get_preset_list
M.get_current_preset = animation.get_current_preset
M.cycle_preset = animation.cycle_preset
M.cycle_preset_reverse = animation.cycle_preset_reverse

-- // MARK: PER-CHARACTER CONTROLS
-- character-level animation controls
-- legacy api (removed): toggle_per_character / set_per_character / get_per_character
-- kept commented to document deprecation and avoid accidental use
-- M.toggle_per_character = animation.toggle_per_character
-- M.set_per_character = animation.set_per_character
-- M.get_per_character = animation.get_per_character
M.should_use_per_character = animation.should_use_per_character
M.set_per_character_mode = animation.set_per_character_mode
M.get_per_character_mode = animation.get_per_character_mode
M.cycle_per_character_mode = animation.cycle_per_character_mode
M.cycle_per_character_mode_reverse = animation.cycle_per_character_mode_reverse
M.get_per_character_modes = animation.get_per_character_modes
M.get_letter_shimmer_markup = animation.get_letter_shimmer_markup

-- // MARK: ANIMATION UTILITIES
-- color and timing utilities
M.get_base_gold = animation.get_base_gold
M.get_status_prefix = animation.get_status_prefix
M.get_palette = animation.get_palette
M.get_gradient_params = animation.get_gradient_params
M.set_gradient_params = animation.set_gradient_params
M.clear_palette_cache = animation.clear_palette_cache
M.interpolate_color = animation.interpolate_color
M.set_speed_multiplier = animation.set_speed_multiplier
M.get_speed_multiplier = animation.get_speed_multiplier
M.get_debug_status = animation.get_debug_status
M.set_shine_only = animation.set_shine_only
M.get_shine_only = animation.get_shine_only
M.set_disable_shine = animation.set_disable_shine
M.get_disable_shine = animation.get_disable_shine
M.set_disable_color = animation.set_disable_color
M.get_disable_color = animation.get_disable_color
M.set_global_max_animated_chars = animation.set_global_max_animated_chars
M.get_global_max_animated_chars = animation.get_global_max_animated_chars

-- // MARK: PERFORMANCE CACHING
-- high-performance markup caching functions
M.clear_markup_cache = animation.clear_markup_cache
M.get_cache_stats = animation.get_cache_stats

-- HSV color conversion caching
M.clear_hsv_cache = animation.clear_hsv_cache
M.get_hsv_cache_stats = animation.get_hsv_cache_stats
M.set_target_fps = animation.set_target_fps
M.get_target_fps = animation.get_target_fps

-- // MARK: STATIC TEXT CACHE MANAGEMENT
-- static text caching for unchanging content
M.clear_static_cache = integrations.clear_static_cache
M.get_static_cache_stats = integrations.get_static_cache_stats

-- // MARK: STRING INTERNING MANAGEMENT
-- string interning for markup optimization
M.clear_string_intern_cache = animation.clear_string_intern_cache
M.get_string_intern_stats = animation.get_string_intern_stats

-- // MARK: MATH CACHE MANAGEMENT
-- trigonometric function caching
M.clear_math_cache = animation.clear_math_cache
M.get_math_cache_stats = animation.get_math_cache_stats

-- // MARK: PALETTE PRE-COMPUTATION MANAGEMENT
-- palette pre-computation for performance
M.clear_precomputed_palettes = animation.clear_precomputed_palettes
M.get_palette_precompute_stats = animation.get_palette_precompute_stats

-- // MARK: CHARACTER CLASSIFICATION CACHE MANAGEMENT
-- character type classification caching
M.clear_char_class_cache = animation.clear_char_class_cache
M.get_char_class_stats = animation.get_char_class_stats

-- // MARK: MARKUP TEMPLATE CACHE MANAGEMENT
-- markup template caching for performance
M.clear_template_cache = animation.clear_template_cache
M.get_template_cache_stats = animation.get_template_cache_stats

-- // MARK: MEMORY POOL MANAGEMENT
-- temporary table pooling    -- memory pool management
-- legacy names (deprecated): clear_memory_pool / get_memory_pool_stats
-- M.clear_memory_pool = animation.clear_memory_pool
-- M.get_memory_pool_stats = animation.get_memory_pool_stats
-- new names:
M.clear_table_pool = animation.clear_table_pool
M.get_table_pool_stats = animation.get_table_pool_stats

-- widget lock optimization
M.clear_widget_locks = animation.clear_widget_locks
M.get_widget_lock_stats = animation.get_widget_lock_stats

-- expose helper function optimization APIs
M.clear_helper_cache = animation.clear_helper_cache
M.get_helper_cache_stats = animation.get_helper_cache_stats
    
-- expose shine calculation cache APIs
M.clear_shine_cache = animation.clear_shine_cache
M.get_shine_cache_stats = animation.get_shine_cache_stats
    
-- expose differential markup cache APIs
M.clear_diff_cache = animation.clear_diff_cache
M.get_diff_cache_stats = animation.get_diff_cache_stats

-- // MARK: WIDGET INTEGRATION FUNCTIONS
-- functions for registering and managing widget shimmer
M.register_taglist = integrations.register_taglist
M.register_tasklist = integrations.register_tasklist
M.register_launcher = integrations.register_launcher
M.attach_tag_hover = integrations.attach_tag_hover
M.handle_tag_hover = integrations.handle_tag_hover
M.tasklist_update_callback = integrations.tasklist_update_callback
M.apply_tasklist_safety = integrations.apply_tasklist_safety
M.refresh_all_tasklists = integrations.refresh_all_tasklists
M.set_phase_offsets = integrations.set_phase_offsets
M.set_per_letter_modes = integrations.set_per_letter_modes
M.get_phase_offsets = integrations.get_phase_offsets
M.get_per_letter_modes = integrations.get_per_letter_modes
M.initialize_focused_client = integrations.initialize_focused_client
M.setup_focus_signals = integrations.setup_focus_signals

-- // MARK: BORDER ANIMATION FUNCTIONS
-- window border shimmer controls
M.set_border_phase_offset = border.set_phase_offset
M.get_border_phase_offset = border.get_phase_offset
M.set_border_smoothness = border.set_smoothness
M.pause_border = border.pause
M.resume_border = border.resume
M.get_border_state = border.get_state
M.border_on_mode_changed = border.on_mode_changed

-- // MARK: SYSTEM CONFIGURATION
-- main configuration function with preset and component setup
function M.configure(config)
    config = config or {}
    
    -- set preset if specified
    if config.preset then
        animation.set_mode(config.preset)
    end
    
    -- configure animation toggles
    if config.disable_shine ~= nil then
        animation.set_disable_shine(config.disable_shine)
    end
    if config.disable_color ~= nil then
        animation.set_disable_color(config.disable_color)
    end
    if config.max_animated_chars ~= nil then
        animation.set_global_max_animated_chars(config.max_animated_chars)
    end
    
    -- configure border animation if specified
    if config.border then
        if config.border.smoothness then
            border.set_smoothness(config.border.smoothness)
        end
        if config.border.follow_text_style ~= nil then
            border.set_follow_text_style(config.border.follow_text_style)
        end
        if config.border.use_shimmer_palette ~= nil then
            border.set_use_shimmer_palette(config.border.use_shimmer_palette)
        end
    end
    
    -- configure phase offsets
    if config.phase_offsets then
        integrations.set_phase_offsets(config.phase_offsets)
    end
    
    -- configure per-letter shimmer modes
    if config.per_letter then
        integrations.set_per_letter_modes(config.per_letter)
    end
    
    -- start systems
    animation.start()
    border.start()
    
    -- setup focus signal handling to ensure shimmer on focus changes
    integrations.setup_focus_signals()
end

-- initialize system (defer to avoid startup issues)
-- NOTE: removed automatic configure() call to prevent overriding rc.lua configuration
-- the system will be initialized by the explicit shimmer.configure() call in rc.lua

return M
