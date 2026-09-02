-- plugins/shimmer/border.lua
-- Border animation system for window shimmer effects
--
-- BORDER ARCHITECTURE:
-- This module provides continuous shimmer animation for window borders:
-- • Independent animation loop with configurable timing
-- • Synchronized with main shimmer palette colors  
-- • Phase offset system for variety (default 3.0)
-- • Smoothness control for animation quality
-- • Start/stop/pause controls for performance
--
-- INTEGRATION:
-- • Uses shared color palette from animation module
-- • Responds to mode changes via on_mode_changed()
-- • Border colors cycle through current shimmer preset
-- • Phase offset creates timing variety vs text shimmer
--
-- PERFORMANCE:
-- • Independent timer (0.06s default) for smooth borders
-- • Can be paused/stopped when not needed
-- • Smoothness setting controls update frequency

local gears = require("gears")

local M = {}

-- // MARK: CONSTANT FOLDING & MATH OPTIMIZATION
-- pre-calculated mathematical constants
local HALF = 0.5

-- cached math functions for performance
local math_floor = math.floor
local string_format = string.format

-- // MARK: BORDER STATE VARIABLES

-- border animation state
local border_loop = 1.0
local border_step = 1.0
local border_paused = false
local border_timer = nil
local border_params = {
    speed = 0.15,         -- animation timer interval (default smoothness 1)
    step_size = 1.0,      -- animation step increment (default smoothness 1)
    phase_offset = 3.0,   -- border gets its own phase offset for variety
    follow_text_style = false,  -- if true, border uses same progression strategy as text
    use_shimmer_palette = true   -- if true, use shimmer colors; if false, use default gradient
}

-- default gradient palette (original border animation colors)
local default_palette = {}
local default_palette_length = 1500

-- // MARK: PALETTE INTEGRATION

-- generate default gradient palette (original border colors)
local function generate_default_palette()
    -- original gradient parameters from old border_animation.lua
    local redFrequency = 0.1
    local grnFrequency = 0.2
    local bluFrequency = 0.1
    local phase1 = 1
    local phase2 = 260
    local phase3 = 50
    local center = 180
    local width = 75
    local length = default_palette_length
    
    default_palette = {}
    for i = 0, length - 1 do
        local r = math_floor(math.sin(redFrequency * i + phase1) * width + center)
        local g = math_floor(math.sin(grnFrequency * i + phase2) * width + center)
        local b = math_floor(math.sin(bluFrequency * i + phase3) * width + center)
        default_palette[i + 1] = string_format("#%02x%02x%02x", r, g, b)
    end
end

-- get current palette from animation module (lazy loading)
local function get_current_palette()
    local animation = require("plugins.shimmer.animation")
    return animation.get_palette()
end

-- get current progression strategy from animation module
local function get_current_strategy()
    local animation = require("plugins.shimmer.animation")
    return animation.get_current_strategy()
end

-- get active palette based on configuration
local function get_active_palette()
    if border_params.use_shimmer_palette then
        return get_current_palette()
    else
        return default_palette
    end
end

-- // MARK: ANIMATION CONTROL

-- start border animation timer
function M.start()
    if border_timer then return end
    
    border_timer = gears.timer {
        timeout = border_params.speed,
        autostart = true,
        callback = function()
            if border_paused then return end
            local c = client.focus
            if not c then
                border_timer:stop()
                return
            end
            if c._dnd_dragging then return end
            
            -- get active palette (shimmer or default)
            local palette = get_active_palette()
            if not palette then return end
            
            local len = #palette
            
            -- ping-pong across palette indices with fractional step (smooth)
            border_loop = border_loop + border_step
            if border_loop >= (len - 1) then
                border_loop = len - 1
                border_step = -(border_params.step_size or HALF)
            elseif border_loop <= 0 then
                border_loop = 0
                border_step = (border_params.step_size or HALF)
            end
            
            -- calculate index with optional strategy-based offset
            local phase_adjusted_loop
            if border_params.follow_text_style then
                -- use same progression strategy as text animation
                local strategy = get_current_strategy()
                if strategy and strategy.calculate_color_offset then
                    -- treat border as single character at position 1 for strategy calculation
                    local strategy_offset = strategy:calculate_color_offset(1, 1, 0)
                    phase_adjusted_loop = border_loop + strategy_offset
                else
                    -- fallback to phase offset if strategy not available
                    phase_adjusted_loop = border_loop + (border_params.phase_offset or 0)
                end
            else
                -- use traditional phase offset for variety
                phase_adjusted_loop = border_loop + (border_params.phase_offset or 0)
            end
            
            local base_index = math_floor(phase_adjusted_loop)
            local index = (base_index % len) + 1
            local fraction = phase_adjusted_loop - base_index
            local next_index = (index % len) + 1
            
            local color1 = palette[index] or "#00000000"
            local color2 = palette[next_index] or "#00000000"
            
            -- simple rgb lerp between adjacent palette colors for smoothness
            local color = color1
            if fraction > 0 and color1 ~= color2 then
                local r1, g1, b1 = color1:match("#(%x%x)(%x%x)(%x%x)")
                local r2, g2, b2 = color2:match("#(%x%x)(%x%x)(%x%x)")
                if r1 and g1 and b1 and r2 and g2 and b2 then
                    r1, g1, b1 = tonumber(r1, 16), tonumber(g1, 16), tonumber(b1, 16)
                    r2, g2, b2 = tonumber(r2, 16), tonumber(g2, 16), tonumber(b2, 16)
                    local r = math_floor(r1 + (r2 - r1) * fraction)
                    local g = math_floor(g1 + (g2 - g1) * fraction)
                    local b = math_floor(b1 + (b2 - b1) * fraction)
                    color = string_format("#%02x%02x%02x", r, g, b)
                end
            end
            
            c.border_color = color
            awesome.emit_signal("shimmer::border_tick", border_loop, len, color)
        end
    }
end

-- stop border animation and cleanup timer
function M.stop()
    if border_timer then 
        border_timer:stop()
        border_timer = nil
    end
end

-- pause/unpause border animation without stopping timer
function M.pause()
    border_paused = true
end

-- resume border animation from paused state
function M.resume()
    border_paused = false
    M.start()
end

-- set border animation smoothness (1-5, higher = smoother)
function M.set_smoothness(smoothness)
    local smoothness_levels = {
        [1] = {speed = 0.15, step_size = 1.0},    -- original (jittery)
        [2] = {speed = 0.08, step_size = 0.8},    -- slightly smoother
        [3] = {speed = 0.06, step_size = 0.5},    -- smooth (default)
        [4] = {speed = 0.04, step_size = 0.3},    -- very smooth
        [5] = {speed = 0.03, step_size = 0.2},    -- ultra smooth
    }
    
    local settings = smoothness_levels[smoothness] or smoothness_levels[3]
    for k, v in pairs(settings) do 
        if k ~= "phase_offset" then  -- preserve phase_offset
            border_params[k] = v 
        end
    end
    if border_timer then border_timer.timeout = border_params.speed end
end

-- // MARK: CONFIGURATION

-- set border phase offset for timing variety
function M.set_phase_offset(offset)
    border_params.phase_offset = offset or 3.0
end

-- get current border phase offset
function M.get_phase_offset()
    return border_params.phase_offset
end

-- set whether border follows text animation style
function M.set_follow_text_style(follow)
    border_params.follow_text_style = follow or false
end

-- get whether border follows text animation style
function M.get_follow_text_style()
    return border_params.follow_text_style
end

-- set whether border uses shimmer palette or default gradient
function M.set_use_shimmer_palette(use_shimmer)
    border_params.use_shimmer_palette = use_shimmer
    if use_shimmer == false then
        -- generate default palette if switching to it
        generate_default_palette()
    end
end

-- get whether border uses shimmer palette
function M.get_use_shimmer_palette()
    return border_params.use_shimmer_palette
end

function M.get_state()
    return {
        running = border_timer and border_timer.started or false,
        paused = border_paused,
        index = border_loop
    }
end

-- initialize default palette on module load
generate_default_palette()

-- set up client signals
client.connect_signal("focus", function(c)
    border_loop = 0.0
    border_step = border_params.step_size or 0.5
    local palette = get_active_palette()
    if palette and palette[1] then
        c.border_color = palette[1]
        awesome.emit_signal("shimmer::border_tick", border_loop, #palette, palette[1])
    end
    if not border_paused then M.start() end
end)

client.connect_signal("unfocus", function(c)
    c.border_color = "#00000000"
end)

-- listen for external pause/resume requests (e.g., DnD)
awesome.connect_signal("shimmer::border_pause", function() M.pause() end)
awesome.connect_signal("shimmer::border_resume", function() M.resume() end)

-- respond to shimmer mode changes
function M.on_mode_changed(mode)
    if border_timer then
        M.stop()
        M.start()
    end
end

return M
