-- plugins/shimmer/animation.lua
-- Core animation and color generation for shimmer system
--
-- ARCHITECTURE:
-- This module handles the core shimmer animation logic including:
-- • Color palette generation using sine wave gradients
-- • Per-character and solid color shimmer modes
-- • Preset management with cycling support
-- • Global per-character toggle independent of presets
-- • Color interpolation for smooth transitions
-- • Animation timing and widget application
--
-- PRESET SYSTEM:
-- Each preset defines speed, gradient parameters, and per_character_default
-- Presets with per_character_default=true: candle, cloud, char_flicker, debug
-- 
-- PER-CHARACTER LOGIC:
-- - Global toggle (per_character_enabled) overrides preset defaults
-- - When switching presets, per_character_default applies if not manually set
-- - Each character gets phase offset based on position (i * 3.0 for wave mode)
-- - should_use_per_character() determines final per-character state

local gears = require("gears")
local gfs = require("gears.filesystem")
local bit = require("bit")
-- local awful = require("awful")  -- unused
local guarded = require("error_guard")

-- import modular components
local constants = require("plugins.shimmer.constants")
local strategies = require("plugins.shimmer.strategies")
local helpers = require("plugins.shimmer.helpers")

local M = {}

-- // MARK: CORE STATE VARIABLES

-- base gold color palette
local base_gold = "#FFD700"

-- // MARK: CHARACTER ANIMATION LIMITING SYSTEM
local char_animation_rotation_step = 0
local CHAR_ROTATION_SPEED = 1  -- how fast to rotate animated character selection

-- cached math functions for performance
local math_sin, math_cos, math_floor, math_abs, math_max, math_min = 
      math.sin, math.cos, math.floor, math.abs, math.max, math.min
local math_exp, math_sqrt, math_deg, math_ceil = math.exp, math.sqrt, math.deg, math.ceil

-- separate color/shine progression timing
local color_step = 0.1    -- separate color progression timing
local shine_step = 0.1    -- separate shine progression timing

-- global override for max animated characters (nil = use preset defaults)
local global_max_animated_chars = nil

-- forward declaration: the preset table is defined below but referenced by
-- the config setters above it
local shimmer_config

-- character selection strategies for max_animated_chars feature
local function select_animated_chars(text_length, max_chars, strategy, text_seed)
    strategy = strategy or "wave"
    max_chars = max_chars or text_length
    
    if max_chars <= 0 or max_chars >= text_length then
        -- animate all characters if limit is disabled or too high
        local all_chars = {}
        for i = 1, text_length do
            all_chars[i] = true
        end
        return all_chars
    end
    
    local selected = {}
    -- rotate one position per step; multiplying by text_length first made the
    -- offset always a multiple of n, so the selection never actually rotated
    local rotation_offset = math_floor(char_animation_rotation_step) % text_length
    
    if strategy == "wave" then
        -- rolling wave of animated characters
        for i = 1, max_chars do
            local pos = ((rotation_offset + i - 1) % text_length) + 1
            selected[pos] = true
        end
    elseif strategy == "random" then
        -- random selection of characters (with text-based seed for consistency)
        local rng_state = (text_seed or 0) + math_floor(char_animation_rotation_step * 100)
        local positions = {}
        for i = 1, text_length do
            positions[i] = i
        end
        
        -- simple deterministic shuffle based on rng_state
        for i = text_length, 2, -1 do
            rng_state = (rng_state * 1103515245 + 12345) % (2^31)
            local j = (rng_state % i) + 1
            positions[i], positions[j] = positions[j], positions[i]
        end
        
        for i = 1, math_min(max_chars, text_length) do
            selected[positions[i]] = true
        end
    elseif strategy == "center_out" then
        -- animate from center outward
        local center = math_ceil(text_length / 2)
        local offset = rotation_offset % text_length
        
        for i = 1, max_chars do
            local distance = math_floor((i - 1) / 2)
            local direction = ((i - 1) % 2 == 0) and 1 or -1
            local pos = center + (direction * distance) + offset
            pos = ((pos - 1) % text_length) + 1
            selected[pos] = true
        end
    elseif strategy == "edges_in" then
        -- animate from edges inward
        local left_count = math_ceil(max_chars / 2)
        local right_count = max_chars - left_count
        local offset = rotation_offset % text_length
        
        for i = 1, left_count do
            local pos = ((i - 1 + offset) % text_length) + 1
            selected[pos] = true
        end
        for i = 1, right_count do
            local pos = ((text_length - i + offset) % text_length) + 1
            selected[pos] = true
        end
    end
    
    return selected
end

-- update character rotation state
local function update_char_rotation()
    char_animation_rotation_step = char_animation_rotation_step + CHAR_ROTATION_SPEED
    if char_animation_rotation_step >= 100 then
        char_animation_rotation_step = char_animation_rotation_step - 100
    end
end

-- // MARK: PERFORMANCE CACHING SYSTEMS
-- high-performance caching to avoid expensive per-character processing
-- legacy full-markup cache removed: its keys bucketed the animation steps,
-- but the steps advance every tick so entries could never be reused

-- HSV lookup table for shine-modified colors
-- cache: base color + quantized shine -> final color; quantization boosts hit rate
local hsv_shine_cache = {}
local SHINE_QUANTIZATION = 0.1  -- quantize shine modifiers to reduce cache size
local MAX_HSV_CACHE_ENTRIES = 2048  -- 256 colors × 8 shine levels
local hsv_cache_stats = { hits = 0, misses = 0, size = 0 }

-- performance control: configurable FPS
-- timer base rate; presets/global adjust effective tick interval, not this
-- local target_fps = 60  -- default 60fps, can be reduced to 30fps for performance
-- local target_fps = 30
local target_fps = 20
-- local target_fps = 15
-- local target_fps = 10
-- local target_fps = 7

-- // MARK: CONSTANT FOLDING & MATH OPTIMIZATION
-- pre-calculated mathematical constants
local TWO_PI = 2 * math.pi
local HALF = 0.5

-- cached string functions for performance
local string_format, string_byte, string_sub, string_len = 
      string.format, string.byte, string.sub, string.len

-- cached table functions for performance
local table_concat, table_insert =
      table.concat, table.insert

-- additional mathematical constants
local THREE_QUARTERS = 0.75
local RGB_MAX = 255

-- // MARK: HSV COLOR CONVERSION FUNCTIONS
-- move these functions up to be available for caching system

-- convert hex color to HSV for brightness modulation
local function hex_to_hsv(hex)
    hex = hex:gsub("#", "")
    local r = tonumber(hex:sub(1,2), 16) / 255
    local g = tonumber(hex:sub(3,4), 16) / 255
    local b = tonumber(hex:sub(5,6), 16) / 255
    local maxc = math.max(r, g, b)
    local minc = math.min(r, g, b)
    local h, s, v = 0, 0, maxc
    local d = maxc - minc
    s = maxc == 0 and 0 or d / maxc
    if maxc ~= minc then
        if maxc == r then
            h = (g - b) / d + (g < b and 6 or 0)
        elseif maxc == g then
            h = (b - r) / d + 2
        else
            h = (r - g) / d + 4
        end
        h = h / 6
    end
    return h * 360, s, v
end

local function hsv_to_rgb(h, s, v)
    -- h in [0,360), s,v in [0,1]
    local c = v * s
    local x = c * (1 - math.abs(((h / 60) % 2) - 1))
    local m = v - c
    local r1, g1, b1 = 0, 0, 0
    if h < 60 then r1, g1, b1 = c, x, 0
    elseif h < 120 then r1, g1, b1 = x, c, 0
    elseif h < 180 then r1, g1, b1 = 0, c, x
    elseif h < 240 then r1, g1, b1 = 0, x, c
    elseif h < 300 then r1, g1, b1 = x, 0, c
    else r1, g1, b1 = c, 0, x end
    local r = math_floor((r1 + m) * RGB_MAX)
    local g = math_floor((g1 + m) * RGB_MAX)
    local b = math_floor((b1 + m) * RGB_MAX)
    return string_format("#%02x%02x%02x", r, g, b)
end

-- quantize shine modifier to reduce cache variants
local function quantize_shine(modifier)
    return math.floor((modifier or 1.0) / SHINE_QUANTIZATION + 0.5) * SHINE_QUANTIZATION
end

-- high-performance HSV lookup with caching
local function get_shine_modified_color(base_color, shine_modifier)
    -- quantize modifier for better cache hits
    local quantized_modifier = quantize_shine(shine_modifier)
    local cache_key = base_color .. "_" .. quantized_modifier
    
    -- check cache first
    if hsv_shine_cache[cache_key] then
        hsv_cache_stats.hits = hsv_cache_stats.hits + 1
        return hsv_shine_cache[cache_key]
    end
    
    -- cache miss - compute HSV conversion once
    hsv_cache_stats.misses = hsv_cache_stats.misses + 1
    local h, s, v = hex_to_hsv(base_color)
    v = math.max(0, math.min(1, v * quantized_modifier))
    local result = hsv_to_rgb(h, s, v)
    
    -- store in cache
    hsv_shine_cache[cache_key] = result
    hsv_cache_stats.size = hsv_cache_stats.size + 1
    
    -- cleanup if needed
    if hsv_cache_stats.size > MAX_HSV_CACHE_ENTRIES then
        -- clear 25% of cache when limit exceeded
        local new_cache = {}
        local count = 0
        local keep_count = math_floor(MAX_HSV_CACHE_ENTRIES * THREE_QUARTERS)
        
        for key, value in pairs(hsv_shine_cache) do
            if count < keep_count then
                new_cache[key] = value
                count = count + 1
            end
        end
        
        hsv_shine_cache = new_cache
        hsv_cache_stats.size = count
    end
    
    return result
end

-- import constants from constants module (proper way)
local PHASE_MULTIPLIERS = constants.PHASE_MULTIPLIERS
local SHINE_MODIFIERS = constants.SHINE_MODIFIERS

-- current animation mode
local shimmer_mode = "gold_crumble"

-- legacy unified mode (kept for backwards compatibility)
local current_per_character_mode = "wave"

-- separate progression systems
local current_colour_prog_mode = "wave"
local current_shine_prog_mode = "wave"

-- preset cycling state - ordered by energy level (low to high activity)
-- local preset_list = {
--     -- minimal energy - static/very low activity
--     "static_gold",
--     "dull_pastel",
--     "warm_light", 
--     "sepia_soft",
--     "redgreenyello",
--     "copper",
--     -- low-medium energy - gentle shimmer
--     "gold_crumble",
--     "dull_gold",
--     "border_sync",
--     -- medium energy - rhythmic effects
--     "amber_pulse",
--     "cloud",
--     "temp_flux",
--     -- medium-high energy - dynamic movement
--     "candy_furnace",
--     "plasma_drift",
--     -- high energy - intense/chaotic effects
--     "electric_buzz",
--     "aurora_scatter",
--     "digital_chaos",
--     "debug"
-- }

local current_preset_index = 2  -- start with gold_crumble (index 2 in preset_list)

-- color palette cache and generation
local color_palettes = {}
-- local palette_length = 256  -- increased for longer animation cycles
local palette_length = 1024  -- increased for longer animation cycles

-- animation state
local shimmer_step = 0.1  -- legacy unified step (kept for compatibility)
local shimmer_timer = nil
local animation_direction = 1  -- 1 for forward, -1 for reverse

-- speed multipliers for independent control
local color_speed_multiplier = 1.0
local shine_speed_multiplier = 1.0


-- progression mode cycling order - ordered by energy level (low to high activity)
local colour_progression_modes_list = {
    -- minimal energy
    "colour_prog_off",
    -- low energy - simple patterns
    "alternating",
    "wave", 
    "reverse_wave",
    "sine_wave",
    -- medium energy - rhythmic and geometric
    "pulse",
    "center_out",
    "edges_in", 
    "fibonacci",
    "spiral",
    "heartbeat",
    -- medium-high energy - organic movement
    "drift",
    "ripple",
    "flow",
    "breathing",
    "cascade",
    "typewriter",
    "gradient_sweep",
    "mirror",
    "plasma",
    -- high energy - chaotic/random effects
    "scatter",
    "chaos",
    "strobe",
    "spotlight",
    "flicker",
    "random",
    "rainbow"
}

local shine_progression_modes_list = {
    -- minimal energy
    "shine_prog_off",
    "uniform",
    -- low energy - simple patterns
    "alternating",
    "wave", 
    "reverse_wave",
    "sine_wave",
    -- medium energy - rhythmic and geometric
    "pulse",
    "center_out",
    "edges_in", 
    "fibonacci",
    "spiral",
    "heartbeat",
    -- medium-high energy - organic movement
    "drift",
    "ripple",
    "flow",
    "breathing",
    "cascade",
    "typewriter",
    "gradient_sweep",
    "mirror",
    "plasma",
    -- high energy - chaotic/random effects
    "scatter",
    "chaos",
    "strobe",
    "spotlight",
    "flicker",
    "random"
}

-- legacy compatibility - defaults to colour progression modes
local progression_modes_list = colour_progression_modes_list

-- progression indices for separate systems
local current_progression_index = 2  -- legacy unified index (start with alternating)
local current_colour_prog_index = 2  -- start with alternating for colour
local current_shine_prog_index = 2  -- start with uniform for shine


--[[

FPS PERFORMANCE FACTORS:
The animation FPS is determined by multiple interconnected factors:
1. Timer Interval (primary): Fixed at ~16ms (60fps) in M.start()
2. Global Speed Multiplier: Lower values = smoother but slower animation
3. Per-preset Speed: Individual preset speeds compound with global multiplier
4. Palette Length: More colors (256 vs 200) = more memory/computation per step
5. Animation Mode: 
    - per_character modes process each character individually (higher CPU)
    - full-text modes process entire strings at once (lower CPU)
6. Color Generation: 
    - sine wave gradients are computationally lighter
    - HSV conversions and complex gradients add overhead
7. Text Length: More characters = more processing per frame
8. Gradient Complexity: Multi-color gradients vs simple color shifts

--]]


-- global speed multiplier (applied to all presets)
local global_speed_multiplier = 1

-- forward declarations for functions referenced before their definitions
-- avoids accidental global lookups during early calls
local get_dynamic_timer_interval
local get_preset_config

-- update timer interval when speed changes
local function update_timer_interval()
    if shimmer_timer then
        shimmer_timer.timeout = get_dynamic_timer_interval()
    end
end
-- speed multiplier control functions
-- old: allowed user to change global tick multiplier
-- function M.set_speed_multiplier(multiplier)
--     global_speed_multiplier = multiplier or 1.0
--     update_timer_interval()
-- end
-- function M.get_speed_multiplier()
--     return global_speed_multiplier
-- end

-- set the global user speed multiplier; affects timer interval and all
-- progression speeds. 1.0 = default, 0.5 = half speed, 2.0 = double.
function M.set_speed_multiplier(multiplier)
    global_speed_multiplier = multiplier or 1.0
    update_timer_interval()
end

function M.get_speed_multiplier()
    return global_speed_multiplier
end

-- get detailed speed breakdown for notifications
-- rate report for notifications: base from target_fps; actual from gears.timer
function M.get_speed_breakdown()
    -- base interval derives from target_fps so display matches the actual timer semantics
    local base_interval_ms = 1000 / target_fps
    local global_multiplier = global_speed_multiplier
    
    local preset_config = get_preset_config(shimmer_mode)
    local preset_multiplier = preset_config and preset_config.speed or 0.0  -- handle "off" presets
    
    -- compute actual timer interval if available
    local actual_timer_ms = shimmer_timer and (shimmer_timer.timeout * 1000) or base_interval_ms
    local max_fps = 1000 / base_interval_ms
    
    -- handle off/inactive presets
    if preset_multiplier == 0 then
        return {
            base_interval_ms = base_interval_ms,
            global_multiplier = global_multiplier,
            preset_multiplier = preset_multiplier,
            color_speed = color_speed_multiplier,
            shine_speed = shine_speed_multiplier,
            effective_multiplier = 0,
            effective_interval_ms = 0,
            fps = 0,
            max_fps = max_fps,
            actual_timer_ms = actual_timer_ms,
            is_active = false
        }
    end
    
    local effective_multiplier = global_multiplier * preset_multiplier
    local effective_interval_ms = base_interval_ms / (effective_multiplier > 0 and effective_multiplier or 1)
    local desired_fps = 1000 / effective_interval_ms
    
    return {
        base_interval_ms = base_interval_ms,
        global_multiplier = global_multiplier,
        preset_multiplier = preset_multiplier,
        color_speed = color_speed_multiplier,
        shine_speed = shine_speed_multiplier,
        effective_multiplier = effective_multiplier,
        effective_interval_ms = effective_interval_ms,
        fps = math.min(desired_fps, max_fps),
        max_fps = max_fps,
        actual_timer_ms = actual_timer_ms,
        is_active = true
    }
end

-- debug function to check timer status
function M.get_debug_status()
    local preset_config = get_preset_config(shimmer_mode)
    local max_chars = M.get_max_animated_chars()  -- use function to get global override if set
    return {
        mode = shimmer_mode,
        step = shimmer_step,
        color_step = color_step,
        shine_step = shine_step,
        color_speed = color_speed_multiplier,
        shine_speed = shine_speed_multiplier,
        timer_running = shimmer_timer and shimmer_timer.started or false,
        palette_cached = color_palettes[shimmer_mode] and true or false,
        palette_length = color_palettes[shimmer_mode] and #color_palettes[shimmer_mode] or 0,
        max_animated_chars = max_chars or "unlimited",
        max_animated_chars_global_override = global_max_animated_chars,
        char_selection_strategy = preset_config and preset_config.char_selection_strategy or "wave",
        char_rotation_step = char_animation_rotation_step
    }
end

-- character animation control functions
function M.set_max_animated_chars(count)
    -- write through to the real preset; get_preset_config returns a fresh
    -- normalized table each call, so writing to it would be lost
    local preset = shimmer_config[shimmer_mode]
    if not preset then return end
    if preset.animation then
        preset.animation.max_animated_chars = count
    else
        preset.max_animated_chars = count
    end
end

function M.get_max_animated_chars()
    -- global override takes precedence
    if global_max_animated_chars ~= nil then
        return global_max_animated_chars
    end
    local preset_config = get_preset_config(shimmer_mode)
    return preset_config and preset_config.max_animated_chars
end

function M.set_char_selection_strategy(strategy)
    local preset = shimmer_config[shimmer_mode]
    if not preset then return end
    if preset.animation then
        preset.animation.char_selection_strategy = strategy
    else
        preset.char_selection_strategy = strategy
    end
end

function M.get_char_selection_strategy()
    local preset_config = get_preset_config(shimmer_mode)
    return preset_config and preset_config.char_selection_strategy or "wave"
end


-- // MARK: COLOR PALETTE GEN

-- sine wave gradient generator: creates smooth RGB transitions via frequency modulation
-- each color channel oscillates independently, center/width control shine range
local function makeSineGradient(length, opts)
    opts = opts or {}
    local frequency1 = opts.redFrequency or 0.3
    local frequency2 = opts.grnFrequency or 0.3
    local frequency3 = opts.bluFrequency or 0.3
    local phase1 = opts.phase1 or 0
    local phase2 = opts.phase2 or 2
    local phase3 = opts.phase3 or 4
    local center = opts.center or 110  -- higher center for brighter colors
    local width = opts.width or 65     -- reduced width for less contrast
    length = length or palette_length
    
    local palette = {}
    local expanded_length = length * 2
    for i = 0, expanded_length - 1 do
        local r = math_floor(math_sin(frequency1 * i * HALF + phase1) * width + center)
        local g = math_floor(math_sin(frequency2 * i * HALF + phase2) * width + center)
        local b = math_floor(math_sin(frequency3 * i * HALF + phase3) * width + center)
        -- clamp values to valid range
        r = math_max(0, math_min(255, r))
        g = math_max(0, math_min(255, g))
        b = math_max(0, math_min(255, b))
        -- only store every other color to maintain original palette size but with smoother transitions
        if i % 2 == 0 and (i / 2) < length then
            palette[(i / 2) + 1] = string.format("#%02x%02x%02x", r, g, b)
        end
    end
    return palette
end

-- duplicate hsv_to_rgb removed here; using the earlier definition above


-- duplicate hex_to_hsv function removed - now defined earlier for cache system


local function makeGoldShinePalette(length, opts)
    length = length or palette_length
    opts = opts or {}
    local hue_base = opts.hue_base or 50       -- ~gold hue
    local hue_var = opts.hue_variation or 8    -- slightly more hue wobble for visibility
    local sat_base = opts.sat_base or 0.95
    local sat_var = opts.sat_variation or 0.15  -- more saturation variation
    local val_min = opts.value_min or 0.5      -- lower floor for more contrast
    local val_max = opts.value_max or 0.98      -- higher ceiling for more contrast
    local shine_freq = opts.shine_frequency or 2.0  -- more cycles for visible shimmer
    local hue_freq = opts.hue_frequency or 0.5
    local sat_freq = opts.sat_frequency or 0.77
    
    local palette = {}
    for i = 1, length do
        local t = (i - 1) / length
        local hue = hue_base + hue_var * math_sin(TWO_PI * t * hue_freq)
        local sat = sat_base - sat_var * math_sin(TWO_PI * t * sat_freq)
        local shine = HALF + HALF * math_sin(TWO_PI * t * shine_freq)
        local val = val_min + (val_max - val_min) * shine
        
        palette[i] = hsv_to_rgb((hue % 360 + 360) % 360, math_max(0, math_min(1, sat)), math_max(0, math_min(1, val)))
    end
    return palette
end


-- preset cycling state - ordered by energy level (low to high activity)
local preset_list = {
    -- minimal energy - static/very low activity
    "static_gold",
    "gold_crumble",
    -- low-medium energy - gentle shimmer
    "dull_gold",
    -- medium energy - rhythmic effects
    "copper",
    "amber_pulse",
    "redgreenyello",
    "dull_pastel",
    "sepia_soft",
    "warm_light", 
    "cloud",
    "temp_flux",
    -- medium-high energy - dynamic movement
    "candy_furnace",
    "plasma_drift",
    -- high energy - intense/chaotic effects
    "electric_buzz",
    "aurora_scatter",
    "digital_chaos",
    "border_sync",
    "debug"
}


-- // MARK: PRESET CONF
-- normalized shimmer preset structure
-- each preset defines: color generation, progression modes, and animation settings
shimmer_config = {
    -- PRESETS ORDERED BY ACCESS SEQUENCE (matching preset_list)
    
    -- no animation - static gold color
    -- fallback mode, good for performance or when animation is unwanted

    static_gold = {
        -- color generation
        color_gen = {
            type = "static",
            color = base_gold
        },
        -- progression modes
        progression = {
            color_mode = "colour_prog_off",
            shine_mode = "shine_prog_off"
        },
        -- animation settings
        animation = {
            speed = 0,
            color_speed = 1.0,
            shine_speed = 1.0,
            per_character_default = false
        }
    },

    -- gold_crumble: high-contrast gold shine with wide shine range (0.6-0.98)
    -- uses HSV generator with drift progression mode, fast speed (0.8)
    gold_crumble = {
        -- color generation
        color_gen = {
            type = "hsv",
            params = {
                hue_base = 50,
                hue_variation = 6,
                sat_base = 1.0,
                sat_variation = 0.20,
                value_min = 0.9,
                value_max = 0.98,
                shine_frequency = 2.4
            }
        },
        -- progression modes
        progression = {
            color_mode = "spiral",
            shine_mode = "fibonacci"
        },
        -- animation settings
        animation = {
            speed = 0.8,
            color_speed = 0.3,
            shine_speed = 0.3,  -- slightly faster shine for contrast
            per_character_default = false
        }
    },

    -- dull_gold: vivid golden shimmer with high minimum brightness (0.75-0.98)
    -- uses HSV generator with per-character mode, fast speed (0.8), tighter hue variation
    dull_gold = {
        -- color generation
        color_gen = {
            type = "hsv",
            params = {
                hue_base = 48,
                hue_variation = 8,
                sat_base = 1.0,
                sat_variation = 0.08,
                value_min = 0.91,
                value_max = 0.98,
                shine_frequency = 0.6
            }
        },
        -- progression modes
        progression = {
            color_mode = "breathing",
            shine_mode = "breathing"
        },
        -- animation settings
        animation = {
            speed = 0.2,
            color_speed = 0.4,
            shine_speed = 0.1,  -- faster pulse effect
            per_character_default = true,
            max_animated_chars = 8,  -- limit to 8 characters animating at once
            char_selection_strategy = "wave"  -- rolling wave effect
        }
    },


    -- amber_pulse: slow pulsing amber with drift progression mode
    -- uses HSV generator, per-character drift mode, medium speed (0.28), wide shine range
    amber_pulse = {
        -- color generation
        color_gen = {
            type = "hsv",
            params = {
                hue_base = 38,
                hue_variation = 4,
                sat_base = 1.0,
                sat_variation = 0.04,
                value_min = 0.68,
                value_max = 0.96,
                shine_frequency = 1.2
            }
        },
        -- progression modes
        progression = {
            color_mode = "drift",
            shine_mode = "breathing"
        },
        -- animation settings
        animation = {
            speed = 0.78,
            color_speed = 0.9,  -- slightly slower color drift
            shine_speed = 0.6,  -- slow breathing effect
            per_character_default = true
        }
    },

    -- redgreenyello: rich RGB gradient amber with deep red/orange tones
    -- uses sine wave generator, uniform mode, slower speed (0.28), wide contrast (150±90)
    redgreenyello = {
        -- color generation
        color_gen = {
            type = "gradient",
            params = {
                redFrequency = 0.055,
                grnFrequency = 0.028,
                bluFrequency = 0.0003,
                phase1 = 0.2,
                phase2 = 0.8,
                phase3 = 6.0,
                center = 170,
                width = 80
            }
        },
        -- progression modes
        progression = {
            color_mode = "colour_prog_off",
            shine_mode = "shine_prog_off"
        },
        -- animation settings
        animation = {
            speed = 0.28,
            color_speed = 0.7,  -- slower warm transitions
            shine_speed = 0.4,  -- very gentle shine
            per_character_default = true
        }
    },

    -- copper: warm reddish-gold metallic with bronze tones (0.40-0.98)
    -- uses HSV generator, uniform mode, fast speed (0.40), red-shifted hue (25°)
    copper = {
        -- color generation
        color_gen = {
            type = "hsv",
            params = {
                hue_base = 32,
                hue_variation = 8,
                sat_base = 0.85,
                sat_variation = 0.08,
                value_min = 0.6,
                value_max = 0.98,
                shine_frequency = 0.2
            }
        },
        -- progression modes
        progression = {
            color_mode = "colour_prog_off",
            shine_mode = "shine_prog_off"
        },
        -- animation settings
        animation = {
            speed = 0.40,
            color_speed = 0.8,  -- moderate metallic transitions
            shine_speed = 0.3,  -- subtle copper gleam
            per_character_default = true
        }
    },

    -- golden hour warm light - hotter white light with bright intensity
    -- produces bright white shimmer with warm undertones
    warm_light = {
        -- color generation
        color_gen = {
            type = "gradient",
            params = {
                redFrequency = 0.038,
                grnFrequency = 0.038,
                bluFrequency = 0.035,
                phase1 = 0.0,
                phase2 = 0.3,
                phase3 = 1.2,
                center = 238,
                width = 22
            }
        },
        -- progression modes
        progression = {
            color_mode = "colour_prog_off",
            shine_mode = "shine_prog_off"
        },
        -- animation settings
        animation = {
            speed = 0.25,
            color_speed = 0.6,  -- gentle warm light shifts
            per_character_default = false
        }
    },

    -- sepia soft - rich sepia tones with warm brown undertones
    sepia_soft = {
        -- color generation
        color_gen = {
            type = "gradient",
            params = {
                redFrequency = 0.028,
                grnFrequency = 0.022,
                bluFrequency = 0.005,
                phase1 = 0.0,
                phase2 = 0.3,
                phase3 = 3.5,
                center = 165,
                width = 40
            }
        },
        -- progression modes
        progression = {
            color_mode = "colour_prog_off",
            shine_mode = "shine_prog_off"
        },
        -- animation settings
        animation = {
            speed = 0.32,
            color_speed = 0.5,  -- slow sepia transitions
            shine_speed = 0.2,  -- minimal shine variation
            per_character_default = false
        }
    },

    -- cloud: ethereal warm white with blue accents and sky-like appearance
    -- uses RGB gradient, per-character mode, medium speed (0.30), enhanced blue channel
    cloud = {
        -- color generation
        color_gen = {
            type = "gradient",
            params = {
                redFrequency = 0.025,
                grnFrequency = 0.030,
                bluFrequency = 0.055,
                phase1 = 2.8,
                phase2 = 2.8,
                phase3 = 0.5,
                center = 218,
                width = 28
            }
        },
        -- progression modes
        progression = {
            color_mode = "drift",
            shine_mode = "breathing"
        },
        -- animation settings
        animation = {
            speed = 0.30,
            color_speed = 0.8,  -- gentle cloud drift
            shine_speed = 0.4,  -- slow breathing effect
            per_character_default = true,
            max_animated_chars = 5,  -- limit to 5 characters for ethereal effect
            char_selection_strategy = "random"  -- random sparkle pattern
        }
    },

    -- candy: warm flickering candlelight with organic flame colors
    -- uses RGB gradient generator, per-character mode, slow speed (0.25), authentic candle tones
    candy_furnace = {
        -- color generation
        color_gen = {
            type = "gradient",
            params = {
                redFrequency = 0.175,
                grnFrequency = 0.165,
                bluFrequency = 0.08,
                phase1 = 0.2,
                phase2 = 1.8,
                phase3 = 5.2,
                center = 215,
                width = 38
            }
        },
        -- progression modes
        progression = {
            color_mode = "heartbeat",
            shine_mode = "flicker"
        },
        -- animation settings
        animation = {
            speed = 0.1,
            color_speed = 1.2,  -- dynamic flame colors
            shine_speed = 1.8,  -- active flickering
            per_character_default = true
        }
    },

    -- rich deep gold - sophisticated luxury with vibrant golden intensity
    -- slower, more refined animation with richer golden tones
    dull_pastel = {
        -- color generation
        color_gen = {
            type = "gradient",
            params = {
                redFrequency = 0.05,
                grnFrequency = 0.042,
                bluFrequency = 0.0008,
                phase1 = 0.1,
                phase2 = 0.4,
                phase3 = 4.8,
                center = 200,
                width = 40
            }
        },
        -- progression modes
        progression = {
            color_mode = "colour_prog_off",
            shine_mode = "shine_prog_off"
        },
        -- animation settings
        animation = {
            speed = 0.6,
            color_speed = 0.8,  -- slower color transitions
            shine_speed = 0.5,  -- very slow shine for sophistication
            per_character_default = false
        }
    },

    -- temp_flux variant - less contrast, brighter
    temp_flux = {
        -- color generation
        color_gen = {
            type = "gradient",
            params = {
                redFrequency = 0.05,
                grnFrequency = 0.07,
                bluFrequency = 0.015,
                phase1 = 0.8,
                phase2 = 2.2,
                phase3 = 4.2,
                center = 218,
                width = 28
            }
        },
        -- progression modes
        progression = {
            color_mode = "reverse_wave",
            shine_mode = "center_out"
        },
        -- animation settings
        animation = {
            speed = 0.5,
            per_character_default = true
        }
    },

    -- plasma drift - granular drift mode
    plasma_drift = {
        -- color generation
        color_gen = {
            type = "gradient",
            params = {
                redFrequency = 0.08,
                grnFrequency = 0.12,
                bluFrequency = 0.15,
                phase1 = 1.2,
                phase2 = 3.8,
                phase3 = 0.5,
                center = 180,
                width = 65
            }
        },
        -- progression modes
        progression = {
            color_mode = "gradient_sweep",
            shine_mode = "reverse_wave"
        },
        -- animation settings
        animation = {
            speed = 0.35,
            color_speed = 1.1,  -- flowing plasma colors
            shine_speed = 0.8,  -- uniform shine drift
            per_character_default = true
        }
    },

    -- rapid electric buzz - high-energy, attention-grabbing with more saturation
    -- fast animation speed with high frequency changes, best for short bursts
    electric_buzz = {
        -- color generation
        color_gen = {
            type = "gradient",
            params = {
                redFrequency = 0.08,
                grnFrequency = 0.08,
                bluFrequency = 0.03,
                phase1 = 0,
                phase2 = 0.5,
                phase3 = 2.5,
                center = 210,
                width = 50
            }
        },
        -- progression modes
        progression = {
            color_mode = "chaos",
            shine_mode = "strobe"
        },
        -- animation settings
        animation = {
            speed = 0.5,
            color_speed = 0.8,  -- rapid electric changes
            shine_speed = 0.5,  -- intense strobing
            per_character_default = true
        }
    },

    -- aurora scatter - granular scatter mode
    aurora_scatter = {
        -- color generation
        color_gen = {
            type = "hsv",
            params = {
                hue_base = 180,
                hue_variation = 35,
                sat_base = 0.95,
                sat_variation = 0.15,
                value_min = 0.75,
                value_max = 0.98,
                shine_frequency = 1.5
            }
        },
        -- progression modes
        progression = {
            color_mode = "scatter",
            shine_mode = "spotlight"
        },
        -- animation settings
        animation = {
            speed = 0.4,
            color_speed = 1.3,  -- scattered aurora colors
            shine_speed = 1.0,  -- spotlight effects
            per_character_default = true
        }
    },

    -- digital chaos - granular chaos mode
    digital_chaos = {
        -- color generation
        color_gen = {
            type = "gradient",
            params = {
                redFrequency = 0.35,
                grnFrequency = 0.28,
                bluFrequency = 0.42,
                phase1 = 0,
                phase2 = 1.5,
                phase3 = 3.0,
                center = 160,
                width = 95
            }
        },
        -- progression modes
        progression = {
            color_mode = "random",
            shine_mode = "random"
        },
        -- animation settings
        animation = {
            speed = 0.4,
            color_speed = 0.8,  -- chaotic digital shifts
            shine_speed = 0.2,  -- aggressive strobing
            per_character_default = true
        }
    },

    -- border sync mode - coordinates with window border animation
    -- designed to complement border colors, wider color range for variety
    border_sync = {
        -- color generation
        color_gen = {
            type = "gradient",
            params = {
                redFrequency = 0.1,
                grnFrequency = 0.2,
                bluFrequency = 0.1,
                phase1 = 1,
                phase2 = 260,
                phase3 = 50,
                center = 175,
                width = 60
            }
        },
        -- progression modes
        progression = {
            color_mode = "colour_prog_off",
            shine_mode = "shine_prog_off"
        },
        -- animation settings
        animation = {
            speed = 0.06,
            color_speed = 1.0,  -- synchronized with border
            shine_speed = 1.0,  -- synchronized coordination
            per_character_default = false
        }
    },

    -- debug rainbow - obvious color cycling for testing/development
    -- cycles through red->green->blue->yellow->magenta->cyan for easy visibility
    debug = {
        -- color generation
        color_gen = {
            type = "gradient",
            params = {
                redFrequency = 0.3,
                grnFrequency = 0.2,
                bluFrequency = 0.4,
                phase1 = 0,
                phase2 = 2.1,
                phase3 = 4.2,
                center = 127,
                width = 127
            }
        },
        -- progression modes
        progression = {
            color_mode = "rainbow",
            shine_mode = "gradient_sweep"
        },
        -- animation settings
        animation = {
            speed = 1,
            color_speed = 1.0,  -- slowed debug cycling
            shine_speed = 1.0,  -- slowed sweep effects
            per_character_default = true  -- debug mode shows per-character clearly
        }
    },


    -- ADDITIONAL PRESETS (not in preset_list cycling)
    
    -- static amber - stable highlight without animation
    static_amber = {
        -- color generation
        color_gen = {
            type = "static",
            color = "#FFC107"
        },
        -- progression modes
        progression = {
            color_mode = "colour_prog_off",
            shine_mode = "shine_prog_off"
        },
        -- animation settings
        animation = {
            speed = 0,
            color_speed = 1.0,
            shine_speed = 1.0,
            per_character_default = false
        }
    },

    -- honey_glow: softer gold shine with wide shine range (0.35-0.98)
    -- uses HSV generator, uniform mode, medium speed (0.30), gentle hue variation
    honey_glow = {
        -- color generation
        color_gen = {
            type = "hsv",
            params = {
                hue_base = 55,
                hue_variation = 2,
                sat_base = 0.98,
                sat_variation = 0.02,
                value_min = 0.35,
                value_max = 0.98,
                shine_frequency = 1.0
            }
        },
        -- progression modes
        progression = {
            color_mode = "colour_prog_off",
            shine_mode = "shine_prog_off"
        },
        -- animation settings
        animation = {
            speed = 0.30,
            color_speed = 0.7,  -- gentle honey flow
            shine_speed = 0.5,  -- soft glow variation
            per_character_default = true
        }
    }
}


-- // MARK: USER PRESETS
-- presets saved from the popup live in the XDG data dir rather than the
-- config tree, so they survive dotfiles churn without polluting the repo
local USER_PRESETS_PATH = gfs.get_xdg_data_home() .. "/somewm/shimmer_user_presets.lua"
local user_presets = {}

-- serialize a plain-data table (strings/numbers/booleans/nested tables) back
-- to Lua source; keys are sorted so the file diffs cleanly between saves
local function serialize_value(v)
    local t = type(v)
    if t == "string" then return string.format("%q", v) end
    if t == "number" or t == "boolean" then return tostring(v) end
    if t ~= "table" then return "nil" end
    local parts = {}
    for k, val in pairs(v) do
        local key = (type(k) == "string" and k:match("^[%a_][%w_]*$"))
            and k or "[" .. serialize_value(k) .. "]"
        parts[#parts + 1] = key .. " = " .. serialize_value(val)
    end
    table.sort(parts)
    return "{ " .. table.concat(parts, ", ") .. " }"
end

local function persist_user_presets()
    gfs.make_parent_directories(USER_PRESETS_PATH)
    local f = io.open(USER_PRESETS_PATH, "w")
    if not f then return end
    f:write("return " .. serialize_value(user_presets) .. "\n")
    f:close()
end

local function register_preset(name, preset)
    shimmer_config[name] = preset
    for _, n in ipairs(preset_list) do
        if n == name then return end
    end
    preset_list[#preset_list + 1] = name
end

do
    local ok, loaded = pcall(dofile, USER_PRESETS_PATH)
    if ok and type(loaded) == "table" then
        for name, preset in pairs(loaded) do
            user_presets[name] = preset
            register_preset(name, preset)
        end
    end
end

-- snapshot the effective current configuration into a normalized preset
-- named `name`, persist it to USER_PRESETS_PATH, and register it in the
-- selectable list. returns the name on success
function M.save_preset_as(name)
    local cur = get_preset_config(shimmer_mode)
    if not cur then return nil end
    local preset = {
        color_gen = {
            type = cur.color_gen_type,
            params = gears.table.clone(cur.color_gen_params, true),
            color = cur.static_color,
        },
        progression = {
            color_mode = current_colour_prog_mode,
            shine_mode = current_shine_prog_mode,
        },
        animation = {
            speed = cur.speed,
            color_speed = color_speed_multiplier,
            shine_speed = shine_speed_multiplier,
            per_character_default = cur.per_character_default,
            max_animated_chars = global_max_animated_chars or cur.max_animated_chars,
            char_selection_strategy = M.get_char_selection_strategy(),
        },
    }
    user_presets[name] = preset
    register_preset(name, preset)
    persist_user_presets()
    return name
end


-- extract configuration values from normalized preset structure
function get_preset_config(preset_name)
    local preset = shimmer_config[preset_name or shimmer_mode]
    if not preset then return nil end
    
    -- handle both old and new structure for backwards compatibility
    if preset.color_gen then
        -- new normalized structure - ordered logically: color_gen, progression, animation
        return {
            -- color generation (what we're working with)
            color_gen_type = preset.color_gen.type,
            color_gen_params = preset.color_gen.params,
            static_color = preset.color_gen.color,
            -- progression modes (how it behaves)
            colour_prog_mode = preset.progression.color_mode,
            shine_prog_mode = preset.progression.shine_mode,
            -- animation settings (timing control)
            speed = preset.animation.speed,
            color_speed = preset.animation.color_speed or 1.0,
            shine_speed = preset.animation.shine_speed or 1.0,
            per_character_default = preset.animation.per_character_default,
            -- character limiting (was silently dropped, so the limit never applied)
            max_animated_chars = preset.animation.max_animated_chars,
            char_selection_strategy = preset.animation.char_selection_strategy,
            -- legacy compatibility
            use_gold_shine = preset.color_gen.type == "hsv",
            gold_shine_opts = preset.color_gen.type == "hsv" and preset.color_gen.params or nil,
            gradient = preset.color_gen.type == "gradient" and preset.color_gen.params or nil
        }
    else
        -- old structure - return as-is for backwards compatibility
        return preset
    end
end

-- calculate dynamic timer interval based on speed multipliers and target FPS
function get_dynamic_timer_interval()
    local base_fps_interval = 1.0 / target_fps  -- base interval from target FPS
    local global_multiplier = global_speed_multiplier
    
    local preset_config = get_preset_config(shimmer_mode)
    local preset_multiplier = preset_config and preset_config.speed or 1.0
    
    local effective_multiplier = global_multiplier * preset_multiplier
    -- safeguard: avoid zero/negative effective speed (e.g., static presets)
    if not effective_multiplier or effective_multiplier <= 0 then
        return base_fps_interval
    end
    -- floor at 1/120s so stacked multipliers can't run the tick arbitrarily fast
    return math_max(base_fps_interval / effective_multiplier, 1 / 120)
end

-- // MARK: MARKUP TEMPLATE CACHING
-- cache complete markup templates with placeholders for common patterns
local template_cache = {}
local TEMPLATE_CACHE_MAX_ENTRIES = 256
local template_stats = { hits = 0, misses = 0, size = 0 }

-- // MARK: MEMORY POOL FOR TEMPORARY TABLES
-- reuse temporary tables to reduce garbage collection pressure
local table_pool = {}
local TABLE_POOL_MAX_SIZE = 50
local pool_stats = { allocated = 0, reused = 0, size = 0 }

-- // MARK: WIDGET LOCK OPTIMIZATION
-- efficient widget locking using weak references and bitmaps
local widget_locks = setmetatable({}, { __mode = "k" })  -- weak key table
local lock_bitmap = {}  -- bitmap for fast lock checking
local LOCK_BITMAP_SIZE = 1024  -- support up to 1024 concurrent widgets
local next_widget_id = 1
local widget_id_map = setmetatable({}, { __mode = "k" })  -- widget -> id mapping
local lock_stats = { locks_set = 0, locks_cleared = 0, bitmap_hits = 0, table_fallbacks = 0 }

-- get or assign widget ID for bitmap tracking
local function get_widget_id(widget)
    local id = widget_id_map[widget]
    if not id then
        id = next_widget_id
        widget_id_map[widget] = id
        next_widget_id = (next_widget_id % LOCK_BITMAP_SIZE) + 1
    end
    return id
end

-- set widget lock using bitmap optimization
-- bitmap+weak-table lock; avoids double updates and racey interleaving
local function set_widget_lock(widget)
    if not widget then return false end
    
    local id = get_widget_id(widget)
    local byte_idx = math.floor((id - 1) / 8) + 1
    local bit_idx = (id - 1) % 8
    
    -- initialize byte if needed
    if not lock_bitmap[byte_idx] then
        lock_bitmap[byte_idx] = 0
    end
    
    -- set bit in bitmap
    lock_bitmap[byte_idx] = bit.bor(lock_bitmap[byte_idx], bit.lshift(1, bit_idx))
    
    -- also set in weak table as fallback
    widget_locks[widget] = true
    lock_stats.locks_set = lock_stats.locks_set + 1
    return true
end

-- check widget lock using bitmap optimization
local function is_widget_locked(widget)
    if not widget then return false end
    
    local id = widget_id_map[widget]
    if not id then return false end
    
    local byte_idx = math.floor((id - 1) / 8) + 1
    local bit_idx = (id - 1) % 8
    
    -- check bitmap first (fast path)
    if lock_bitmap[byte_idx] then
        local is_locked = bit.band(lock_bitmap[byte_idx], bit.lshift(1, bit_idx)) ~= 0
        if is_locked then
            lock_stats.bitmap_hits = lock_stats.bitmap_hits + 1
            return true
        end
    end
    
    -- fallback to weak table check
    if widget_locks[widget] then
        lock_stats.table_fallbacks = lock_stats.table_fallbacks + 1
        return true
    end
    
    return false
end

-- clear widget lock using bitmap optimization
local function clear_widget_lock(widget)
    if not widget then return false end
    
    local id = widget_id_map[widget]
    if id then
        local byte_idx = math.floor((id - 1) / 8) + 1
        local bit_idx = (id - 1) % 8
        
        -- clear bit in bitmap
        if lock_bitmap[byte_idx] then
            lock_bitmap[byte_idx] = bit.band(lock_bitmap[byte_idx], bit.bnot(bit.lshift(1, bit_idx)))
        end
    end
    
    -- clear from weak table
    widget_locks[widget] = nil
    lock_stats.locks_cleared = lock_stats.locks_cleared + 1
    return true
end

-- get a table from the pool or create new one
-- fast table pool: reuse small arrays to lower gc churn in hot paths
local function get_temp_table()
    if #table_pool > 0 then
        pool_stats.reused = pool_stats.reused + 1
        return table.remove(table_pool)
    else
        pool_stats.allocated = pool_stats.allocated + 1
        return {}
    end
end

-- return a table to the pool for reuse
local function return_temp_table(tbl)
    if #table_pool < TABLE_POOL_MAX_SIZE then
        -- clear the table and return to pool
        for k in pairs(tbl) do
            tbl[k] = nil
        end
        table.insert(table_pool, tbl)
        pool_stats.size = #table_pool
    end
end
-- cache for helper function results to reduce expensive calculations
local helper_cache = {}
local helper_cache_stats = { hits = 0, misses = 0, size = 0 }
local HELPER_CACHE_MAX_SIZE = 1024

-- // MARK: SHINE CALCULATION CACHING
-- cache for complete shine modifier calculations
local shine_calculation_cache = {}
local SHINE_CALC_CACHE_MAX_ENTRIES = 2048
local shine_calc_cache_stats = { hits = 0, misses = 0, size = 0 }

-- local SHINE_TIME_QUANTIZATION = 0.1  -- quantize time for better cache hits
-- local SHINE_TIME_QUANTIZATION = 0.25  -- quantize time for better cache hits
local SHINE_TIME_QUANTIZATION = 0.5  -- quantize time for better cache hits


-- // MARK: PER-TEXT MARKUP CACHE
-- per-text derived data cached across frames: escaped characters, whitespace
-- flags, colour phase offsets and shine modifiers. the animation steps advance
-- every tick so per-character change detection can never hit; instead the span
-- list is rebuilt each frame and only the step-independent data is cached.
local differential_markup_cache = {}
local differential_cache_size = 0
local DIFF_CACHE_MAX_ENTRIES = 256
local diff_cache_stats = { hits = 0, misses = 0, updates = 0, full_rebuilds = 0 }

-- precomputed lookup tables for common calculations
local heartbeat_pattern_cache = {}
local alternating_cache = {}
local color_progression_lut = {}  -- lookup tables for color progression patterns
local helper_optimization_initialized = false

-- initialize precomputed tables
local function init_helper_optimization()
    if helper_optimization_initialized then return end

    -- precompute heartbeat patterns for common character positions
    local heartbeat_pattern = {0, 3, 0.5, 0, 0, 2, 0.3, 0}
    for char_index = 1, 200 do
        local beat_pos = (char_index - 1) % 8
        heartbeat_pattern_cache[char_index] = heartbeat_pattern[beat_pos + 1]
    end
    
    -- precompute alternating patterns for common character positions
    for char_index = 1, 200 do
        alternating_cache[char_index] = (char_index % 2 == 0) and PHASE_MULTIPLIERS.ALTERNATING_OFFSET or 0
    end
    
    -- precompute color progression lookup tables for spatial patterns
    color_progression_lut.plasma = {}
    color_progression_lut.cascade = {}
    color_progression_lut.pulse = {}
    color_progression_lut.breathing = {}
    
    for char_index = 1, 200 do
        -- plasma pattern
        local plasma_wave = math_sin((char_index - 1) * PHASE_MULTIPLIERS.ZIGZAG_FREQ) * PHASE_MULTIPLIERS.ZIGZAG_AMP
        local plasma_base = (char_index - 1) * PHASE_MULTIPLIERS.ZIGZAG_BASE_STEP
        color_progression_lut.plasma[char_index] = plasma_base + plasma_wave
        
        -- cascade pattern
        local cascade_delay = (char_index - 1) * PHASE_MULTIPLIERS.CASCADE_STEP
        local cascade_wave = math_sin((char_index - 1) * PHASE_MULTIPLIERS.CASCADE_SINE_FREQ) * PHASE_MULTIPLIERS.CASCADE_SINE_AMP
        color_progression_lut.cascade[char_index] = cascade_delay + cascade_wave
        
        -- pulse pattern
        local pulse_freq = HALF
        color_progression_lut.pulse[char_index] = math_sin((char_index - 1) * pulse_freq) * PHASE_MULTIPLIERS.PULSE_AMPLITUDE
        
        -- breathing pattern
        local primary = math_sin((char_index - 1) * PHASE_MULTIPLIERS.BREATHING_PRIMARY) * PHASE_MULTIPLIERS.BREATHING_AMPLITUDE
        local secondary = math_sin((char_index - 1) * PHASE_MULTIPLIERS.BREATHING_SECONDARY) * PHASE_MULTIPLIERS.BREATHING_SECONDARY_AMP
        color_progression_lut.breathing[char_index] = primary + secondary
    end
    
    -- precompute spatial patterns for different text lengths
    color_progression_lut.center_out = {}
    color_progression_lut.edges_in = {}
    color_progression_lut.rainbow = {}
    color_progression_lut.mirror = {}
    color_progression_lut.typewriter = {}
    color_progression_lut.gradient_sweep = {}
    color_progression_lut.ripple = {}
    color_progression_lut.spotlight = {}
    
    for total_chars = 1, 100 do  -- reasonable limit for text lengths
        color_progression_lut.center_out[total_chars] = {}
        color_progression_lut.edges_in[total_chars] = {}
        color_progression_lut.rainbow[total_chars] = {}
        color_progression_lut.mirror[total_chars] = {}
        color_progression_lut.typewriter[total_chars] = {}
        color_progression_lut.gradient_sweep[total_chars] = {}
        color_progression_lut.ripple[total_chars] = {}
        color_progression_lut.spotlight[total_chars] = {}
        
        local center = (total_chars + 1) / 2
        
        for char_index = 1, total_chars do
            local distance = math_abs(char_index - center)
            
            -- center_out pattern
            color_progression_lut.center_out[total_chars][char_index] = distance * PHASE_MULTIPLIERS.CENTER_OUT_STEP
            
            -- edges_in pattern
            color_progression_lut.edges_in[total_chars][char_index] = (total_chars / 2 - distance) * PHASE_MULTIPLIERS.EDGES_IN_STEP
            
            -- rainbow pattern
            color_progression_lut.rainbow[total_chars][char_index] = ((char_index - 1) / math_max(1, total_chars - 1)) * PHASE_MULTIPLIERS.RAINBOW_SCALE
            
            -- mirror pattern
            local mirror_base = distance * PHASE_MULTIPLIERS.MIRROR_STEP
            local mirror_wave = math_sin(distance * PHASE_MULTIPLIERS.MIRROR_SINE_FREQ) * PHASE_MULTIPLIERS.MIRROR_SINE_AMP
            color_progression_lut.mirror[total_chars][char_index] = mirror_base + mirror_wave
            
            -- typewriter pattern
            local reveal_progress = (char_index - 1) / math_max(1, total_chars - 1)
            local typewriter_wave = math_sin(reveal_progress * PHASE_MULTIPLIERS.TYPEWRITER_SINE_FREQ) * PHASE_MULTIPLIERS.TYPEWRITER_SINE_AMP
            color_progression_lut.typewriter[total_chars][char_index] = reveal_progress * PHASE_MULTIPLIERS.TYPEWRITER_SCALE + typewriter_wave
            
            -- gradient_sweep pattern
            local sweep_progress = (char_index - 1) / math_max(1, total_chars - 1)
            color_progression_lut.gradient_sweep[total_chars][char_index] = sweep_progress * PHASE_MULTIPLIERS.GRADIENT_SWEEP_SCALE
            
            -- ripple pattern
            local ripple_wave = math_sin(distance * PHASE_MULTIPLIERS.RIPPLE_FREQ) * math_exp(-distance * PHASE_MULTIPLIERS.RIPPLE_DECAY)
            color_progression_lut.ripple[total_chars][char_index] = ripple_wave * PHASE_MULTIPLIERS.RIPPLE_AMPLITUDE
            
            -- spotlight pattern
            local spotlight_intensity = math_exp(-distance * PHASE_MULTIPLIERS.SPOTLIGHT_DECAY)
            color_progression_lut.spotlight[total_chars][char_index] = spotlight_intensity * PHASE_MULTIPLIERS.SPOTLIGHT_SCALE
        end
    end
    
    helper_optimization_initialized = true
end

-- generate cache key for helper function results
local function get_helper_cache_key(func_name, ...)
    local args = {...}
    local key_parts = {func_name}
    for i, arg in ipairs(args) do
        if type(arg) == "number" then
            -- quantize numbers to reduce cache key variations
            table_insert(key_parts, string_format("%.3f", arg))
        else
            table_insert(key_parts, tostring(arg))
        end
    end
    return table_concat(key_parts, "|")
end

-- generate cache key for shine calculations
local function get_shine_cache_key(char_index, total_chars, shine_prog_mode, text_seed, time_factor)
    local quantized_time = math.floor((time_factor or 0) / SHINE_TIME_QUANTIZATION + 0.5) * SHINE_TIME_QUANTIZATION
    return string_format("shine_%d_%d_%s_%s_%.1f", 
                        char_index, total_chars, shine_prog_mode or "off", 
                        text_seed or "0", quantized_time)
end

-- forward declarations for functions used in differential markup
local get_color_progression_offset
local get_shine_progression_modifier

-- cached helper function wrapper
local function cached_helper_call(func_name, func, ...)
    local cache_key = get_helper_cache_key(func_name, ...)
    
    -- check cache first
    if helper_cache[cache_key] then
        helper_cache_stats.hits = helper_cache_stats.hits + 1
        return helper_cache[cache_key]
    end
    
    -- cache miss - calculate result
    local result = func(...)
    
    -- store in cache with size limit
    if helper_cache_stats.size >= HELPER_CACHE_MAX_SIZE then
        -- simple cleanup: remove first 25% of entries
        local count = 0
        local target = math.floor(HELPER_CACHE_MAX_SIZE * 0.25)
        for k, _ in pairs(helper_cache) do
            helper_cache[k] = nil
            count = count + 1
            if count >= target then break end
        end
        helper_cache_stats.size = helper_cache_stats.size - count
    end
    
    helper_cache[cache_key] = result
    helper_cache_stats.size = helper_cache_stats.size + 1
    helper_cache_stats.misses = helper_cache_stats.misses + 1
    
    return result
end

-- forward declaration for internal shine calculation function
local calculate_shine_modifier_internal
local cached_shine_calculation

-- cached wrapper for complete shine calculations
cached_shine_calculation = function(char_index, total_chars, shine_prog_mode, text_seed, time_factor)
    local cache_key = get_shine_cache_key(char_index, total_chars, shine_prog_mode, text_seed, time_factor)
    
    if shine_calculation_cache[cache_key] then
        shine_calc_cache_stats.hits = shine_calc_cache_stats.hits + 1
        return shine_calculation_cache[cache_key]
    end
    
    -- cache miss - calculate shine modifier
    shine_calc_cache_stats.misses = shine_calc_cache_stats.misses + 1
    local modifier = calculate_shine_modifier_internal(char_index, total_chars, shine_prog_mode, text_seed, time_factor)
    
    -- store in cache
    shine_calculation_cache[cache_key] = modifier
    shine_calc_cache_stats.size = shine_calc_cache_stats.size + 1
    
    -- cleanup if cache gets too large
    if shine_calc_cache_stats.size > SHINE_CALC_CACHE_MAX_ENTRIES then
        -- clear 25% of entries
        local new_cache = {}
        local count = 0
        local keep_count = math.floor(SHINE_CALC_CACHE_MAX_ENTRIES * 0.75)
        
        for key, value in pairs(shine_calculation_cache) do
            if count < keep_count then
                new_cache[key] = value
                count = count + 1
            end
        end
        
        shine_calculation_cache = new_cache
        shine_calc_cache_stats.size = count
    end
    
    return modifier
end

-- // MARK: PALETTE GENERATION
-- palettes build lazily via ensure_palette on first use; pre-computing every
-- preset up front stalled the main loop by ~100-800ms on each start

local function ensure_palette(mode_name)
    -- reuse the already-generated palette if present
    if color_palettes[mode_name] then
        return color_palettes[mode_name]
    end
    
    local config = get_preset_config(mode_name)
    if not config then
        color_palettes[mode_name] = {base_gold}
        return color_palettes[mode_name]
    end
    
    -- runtime generation as fallback
    if config.color_gen_type == "hsv" or config.use_gold_shine then
        local params = config.color_gen_params or config.gold_shine_opts
        color_palettes[mode_name] = makeGoldShinePalette(palette_length, params)
    elseif config.color_gen_type == "gradient" or config.gradient then
        local g = config.color_gen_params or config.gradient
        color_palettes[mode_name] = makeSineGradient(palette_length, g)
    elseif config.color_gen_type == "static" then
        color_palettes[mode_name] = { config.static_color or base_gold }
    else
        color_palettes[mode_name] = { config.static_color or base_gold }
    end
    
    return color_palettes[mode_name]
end

-- // MARK: CLIENT STATUS HELPERS

-- get client status prefix symbols for window titles
local function get_client_status_prefix(c)
    if not c or not c.valid then return "" end
    
    local symbols = get_temp_table()
    if c.floating then table_insert(symbols, "✈") end
    if c.maximized then table_insert(symbols, "+")
    elseif c.maximized_horizontal then table_insert(symbols, "⬌")
    elseif c.maximized_vertical then table_insert(symbols, "⬍") end
    if c.sticky then table_insert(symbols, "▪") end
    if c.ontop then table_insert(symbols, "⌃")
    elseif c.above then table_insert(symbols, "▴")
    elseif c.below then table_insert(symbols, "▾") end
    
    local result = (#symbols > 0) and table_concat(symbols, "") .. " " or ""
    return_temp_table(symbols)
    return result
end

-- cached reference to avoid repeated require calls
local integrations_module = nil
local function get_integrations()
    if not integrations_module then
        integrations_module = require("plugins.shimmer.integrations")
    end
    return integrations_module
end

-- timer callback for shimmer animation
local function shimmer_tick()
    shimmer_step = shimmer_step + 1  -- legacy unified step
    color_step = color_step + color_speed_multiplier
    shine_step = shine_step + shine_speed_multiplier
    update_char_rotation()  -- update character animation rotation
    get_integrations().update_widgets()
end



-- import strategy registry from modular structure
local progression_strategies = strategies.get_registry()


-- helper functions now imported from helpers module



-- // MARK: TEST SWITCHES
-- testing toggles to isolate subsystems
local SHIMMER_SHINE_ONLY = false
local SHIMMER_DISABLE_SHINE = false  -- disable shine aspect entirely
local SHIMMER_DISABLE_COLOR = false  -- disable color mode entirely


-- // MARK: TEST SWITCH API
function M.set_shine_only(enabled)
    SHIMMER_SHINE_ONLY = not not enabled
end

function M.get_shine_only()
    return SHIMMER_SHINE_ONLY
end

-- disable shine aspect entirely (all shine modifiers = 1.0)
-- deprecated: use M.set_shine_speed(0) instead
function M.set_disable_shine(enabled)
    if enabled then
        M.set_shine_speed(0)
    else
        -- re-enable with default speed if disabled
        if shine_speed_multiplier == 0 then
            M.set_shine_speed(1.0)
        end
    end
    SHIMMER_DISABLE_SHINE = not not enabled
end

function M.get_disable_shine()
    return shine_speed_multiplier == 0 or SHIMMER_DISABLE_SHINE
end

-- disable color mode entirely (all color offsets = 0)
-- deprecated: use M.set_color_speed(0) instead
function M.set_disable_color(enabled)
    if enabled then
        M.set_color_speed(0)
    else
        -- re-enable with default speed if disabled
        if color_speed_multiplier == 0 then
            M.set_color_speed(1.0)
        end
    end
    SHIMMER_DISABLE_COLOR = not not enabled
end

function M.get_disable_color()
    return color_speed_multiplier == 0 or SHIMMER_DISABLE_COLOR
end

-- global max animated chars override (nil = use preset defaults)
function M.set_global_max_animated_chars(count)
    global_max_animated_chars = count
end

function M.get_global_max_animated_chars()
    return global_max_animated_chars
end

-- // MARK: COLOUR PROG

-- calculate color progression phase offset for a character
get_color_progression_offset = function(char_index, total_chars, colour_prog_mode, text_seed)
    if colour_prog_mode == "colour_prog_off" or colour_prog_mode == "uniform" then
        return 0 -- no phase offset
    end
    -- check if color speed is disabled (0 = disabled)
    if color_speed_multiplier == 0 then
        return 0
    end
    -- legacy: config option: disable color progression entirely
    if SHIMMER_DISABLE_COLOR then
        return 0
    end
    -- shine-only testing: disable color progression entirely
    if SHIMMER_SHINE_ONLY then
        return 0
    end
    
    local offset = 0
    
    -- LUTs are built lazily by start(); callers that render before start
    -- (e.g. the popup's per-mode previews) would otherwise hit nil tables
    init_helper_optimization()

    -- try strategy pattern first with caching
    local strategy = progression_strategies[colour_prog_mode]
    if strategy then
        offset = cached_helper_call("strategy_" .. colour_prog_mode, strategy.calculate_color_offset, strategy, char_index, total_chars, text_seed)
    elseif colour_prog_mode == "center_out" then
        offset = (color_progression_lut.center_out[total_chars] and color_progression_lut.center_out[total_chars][char_index]) or 
                 cached_helper_call("center_out_offset", helpers.calc_center_out_offset, char_index, total_chars)
    elseif colour_prog_mode == "edges_in" then
        offset = (color_progression_lut.edges_in[total_chars] and color_progression_lut.edges_in[total_chars][char_index]) or 
                 cached_helper_call("edges_in_offset", helpers.calc_edges_in_offset, char_index, total_chars)
    elseif colour_prog_mode == "pulse" then
        offset = color_progression_lut.pulse[char_index] or 
                 cached_helper_call("pulse_offset", helpers.calc_pulse_offset, char_index)
    elseif colour_prog_mode == "alternating" then
        offset = alternating_cache[char_index] or ((char_index % 2 == 0) and PHASE_MULTIPLIERS.ALTERNATING_OFFSET or 0)
    elseif colour_prog_mode == "fibonacci" then
        offset = cached_helper_call("fibonacci_offset", helpers.calc_fibonacci_offset, char_index)
    elseif colour_prog_mode == "spiral" then
        offset = cached_helper_call("spiral_offset", helpers.calc_spiral_offset, char_index)
    elseif colour_prog_mode == "rainbow" then
        offset = (color_progression_lut.rainbow[total_chars] and color_progression_lut.rainbow[total_chars][char_index]) or 
                 cached_helper_call("rainbow_offset", helpers.calc_rainbow_offset, char_index, total_chars)
    elseif colour_prog_mode == "heartbeat" then
        offset = heartbeat_pattern_cache[char_index] or (function()
            local beat_pos = (char_index - 1) % 8
            local heartbeat_pattern = {0, 3, 0.5, 0, 0, 2, 0.3, 0}
            return heartbeat_pattern[beat_pos + 1]
        end)()
    elseif colour_prog_mode == "drift" then
        offset = cached_helper_call("random_offset_drift", helpers.calc_random_offset, char_index, text_seed, PHASE_MULTIPLIERS.DRIFT_SCALE)
    elseif colour_prog_mode == "scatter" then
        offset = cached_helper_call("random_offset_scatter", helpers.calc_random_offset, char_index, text_seed, PHASE_MULTIPLIERS.SCATTER_SCALE)
    elseif colour_prog_mode == "chaos" then
        offset = cached_helper_call("random_offset_chaos", helpers.calc_random_offset, char_index, text_seed, PHASE_MULTIPLIERS.CHAOS_SCALE)
    elseif colour_prog_mode == "random" then
        offset = cached_helper_call("random_offset_random", helpers.calc_random_offset, char_index, text_seed, PHASE_MULTIPLIERS.RANDOM_SCALE)
    elseif colour_prog_mode == "ripple" then
        offset = (color_progression_lut.ripple[total_chars] and color_progression_lut.ripple[total_chars][char_index]) or 
                 cached_helper_call("ripple_offset", helpers.calc_ripple_offset, char_index, total_chars)
    elseif colour_prog_mode == "flow" then
        offset = cached_helper_call("flow_offset", helpers.calc_flow_offset, char_index, total_chars, text_seed)
    elseif colour_prog_mode == "breathing" then
        offset = color_progression_lut.breathing[char_index] or 
                 cached_helper_call("breathing_offset", helpers.calc_breathing_offset, char_index)
    elseif colour_prog_mode == "cascade" then
        offset = color_progression_lut.cascade[char_index] or 
                 cached_helper_call("cascade_offset", helpers.calc_cascade_offset, char_index)
    elseif colour_prog_mode == "typewriter" then
        offset = (color_progression_lut.typewriter[total_chars] and color_progression_lut.typewriter[total_chars][char_index]) or 
                 cached_helper_call("typewriter_offset", helpers.calc_typewriter_offset, char_index, total_chars)
    elseif colour_prog_mode == "gradient_sweep" then
        offset = (color_progression_lut.gradient_sweep[total_chars] and color_progression_lut.gradient_sweep[total_chars][char_index]) or 
                 cached_helper_call("gradient_sweep_offset", helpers.calc_gradient_sweep_offset, char_index, total_chars)
    elseif colour_prog_mode == "mirror" then
        offset = (color_progression_lut.mirror[total_chars] and color_progression_lut.mirror[total_chars][char_index]) or 
                 cached_helper_call("mirror_offset", helpers.calc_mirror_offset, char_index, total_chars)
    elseif colour_prog_mode == "plasma" then
        offset = color_progression_lut.plasma[char_index] or 
                 cached_helper_call("plasma_offset", helpers.calc_plasma_offset, char_index)
    elseif colour_prog_mode == "strobe" then
        offset = cached_helper_call("strobe_offset", helpers.calc_strobe_offset, char_index, text_seed)
    elseif colour_prog_mode == "spotlight" then
        offset = (color_progression_lut.spotlight[total_chars] and color_progression_lut.spotlight[total_chars][char_index]) or 
                 cached_helper_call("spotlight_offset", helpers.calc_spotlight_offset, char_index, total_chars)
    elseif colour_prog_mode == "flicker" then
        offset = cached_helper_call("flicker_offset", helpers.calc_flicker_offset, char_index, text_seed)
    end
    
    return offset
end


-- shine helper functions now imported from helpers module


-- // MARK: SHINE PROG

-- internal shine calculation (uncached)
calculate_shine_modifier_internal = function(char_index, total_chars, shine_prog_mode, text_seed, time_factor)
    if shine_prog_mode == "shine_prog_off" then
        return 1.0 -- no modification
    end
    -- check if shine speed is disabled (0 = disabled)
    if shine_speed_multiplier == 0 then
        return 1.0 -- no shine modification
    end
    -- legacy: config option: disable shine entirely
    if SHIMMER_DISABLE_SHINE then
        return 1.0 -- no shine modification
    end
    
    local modifier = 1.0
    local shine_time_factor = time_factor or shine_step
    
    -- old (commented): strategy-first branch produced static values for some modes (e.g. wave)
    --[[
    local strategy = progression_strategies[shine_prog_mode]
    if strategy then
        modifier = strategy:calculate_shine_modifier(char_index, total_chars, text_seed)
    end
    ]]

    -- new: prefer time-aware helpers per mode for visible animation
    if shine_prog_mode == "uniform" then
        modifier = SHINE_MODIFIERS.BASE_MAX
    elseif shine_prog_mode == "center_out" then
        -- old: static spatial only
        -- modifier = helpers.calc_center_out_shine(char_index, total_chars)
        modifier = cached_helper_call("center_out_shine", helpers.calc_center_out_shine, char_index, total_chars)
        -- add gentle time modulation so it breathes
        local overlay = 1.0 + 0.15 * math.sin(shine_time_factor * 0.6 + char_index * 0.10)
        modifier = modifier * overlay
    elseif shine_prog_mode == "edges_in" then
        -- old: static spatial only
        -- modifier = helpers.calc_edges_in_shine(char_index, total_chars)
        modifier = cached_helper_call("edges_in_shine", helpers.calc_edges_in_shine, char_index, total_chars)
        local overlay = 1.0 + 0.15 * math.sin(shine_time_factor * 0.6 + char_index * 0.12)
        modifier = modifier * overlay
    elseif shine_prog_mode == "pulse" then
        modifier = cached_helper_call("pulse_shine", helpers.calc_pulse_shine, char_index, shine_time_factor)
    elseif shine_prog_mode == "alternating" then
        -- old: static alternating by position
        -- modifier = (char_index % 2 == 0) and SHINE_MODIFIERS.BASE_MAX or SHINE_MODIFIERS.ALTERNATING_DIM
        -- new: flip parity over time steps
        local step = math.floor(shine_time_factor)
        local parity = ((char_index + step) % 2 == 0)
        modifier = parity and SHINE_MODIFIERS.BASE_MAX or SHINE_MODIFIERS.ALTERNATING_DIM
    elseif shine_prog_mode == "fibonacci" then
        -- old: static spatial only
        -- modifier = helpers.calc_fibonacci_shine(char_index)
        modifier = cached_helper_call("fibonacci_shine", helpers.calc_fibonacci_shine, char_index)
        local overlay = 1.0 + 0.12 * math_sin(shine_time_factor * HALF + char_index * 0.08)
        modifier = modifier * overlay
    elseif shine_prog_mode == "spiral" then
        -- old: static spatial only
        -- modifier = helpers.calc_spiral_shine(char_index)
        modifier = cached_helper_call("spiral_shine", helpers.calc_spiral_shine, char_index)
        local overlay = 1.0 + 0.12 * math_sin(shine_time_factor * HALF + char_index * 0.07)
        modifier = modifier * overlay
    elseif shine_prog_mode == "rainbow" then
        -- old: static gradient across text
        -- modifier = helpers.calc_rainbow_shine(char_index, total_chars)
        modifier = cached_helper_call("rainbow_shine", helpers.calc_rainbow_shine, char_index, total_chars)
        local overlay = 1.0 + 0.10 * math.sin(shine_time_factor * 0.9)
        modifier = modifier * overlay
    elseif shine_prog_mode == "heartbeat" then
        -- old: static per-character beat position
        -- local beat_pos = (char_index - 1) % 8
        -- local heartbeat_pattern = {1.0, 0.9, 1.0, 0.7, 0.7, 0.8, 0.7, 0.7}
        -- modifier = heartbeat_pattern[beat_pos + 1]
        local beat_step = math.floor(shine_time_factor * 2)
        local beat_pos = (beat_step + char_index - 1) % 8
        local heartbeat_pattern = {1.0, 0.9, 1.0, 0.7, 0.7, 0.8, 0.7, 0.7}
        modifier = heartbeat_pattern[beat_pos + 1]
    elseif shine_prog_mode == "drift" then
        modifier = cached_helper_call("drift_shine", helpers.calc_drift_shine, char_index, total_chars, text_seed, shine_time_factor)
    elseif shine_prog_mode == "scatter" or shine_prog_mode == "chaos" or shine_prog_mode == "random" then
        modifier = cached_helper_call("random_shine", helpers.calc_random_shine, char_index, text_seed, shine_time_factor)
    elseif shine_prog_mode == "ripple" then
        -- old: static spatial decay from center
        -- modifier = helpers.calc_ripple_shine(char_index, total_chars)
        modifier = cached_helper_call("ripple_shine", helpers.calc_ripple_shine, char_index, total_chars)
        local overlay = 1.0 + 0.14 * math.sin(shine_time_factor * 0.7 + char_index * 0.05)
        modifier = modifier * overlay
    elseif shine_prog_mode == "flow" then
        modifier = cached_helper_call("flow_shine", helpers.calc_flow_shine, char_index, total_chars, text_seed, shine_time_factor)
    elseif shine_prog_mode == "breathing" then
        modifier = cached_helper_call("breathing_shine", helpers.calc_breathing_shine, char_index, shine_time_factor)
    elseif shine_prog_mode == "cascade" then
        -- old: static tiered brightness
        -- modifier = helpers.calc_cascade_shine(char_index, total_chars)
        modifier = cached_helper_call("cascade_shine", helpers.calc_cascade_shine, char_index, total_chars)
        local overlay = 1.0 + 0.10 * math.sin(shine_time_factor * 0.8)
        modifier = modifier * overlay
    elseif shine_prog_mode == "typewriter" then
        -- old: static head/tail emphasis
        -- modifier = helpers.calc_typewriter_shine(char_index, total_chars)
        modifier = cached_helper_call("typewriter_shine", helpers.calc_typewriter_shine, char_index, total_chars)
        local overlay = 1.0 + 0.12 * math.sin(shine_time_factor * 0.8 + char_index * 0.2)
        modifier = modifier * overlay
    elseif shine_prog_mode == "gradient_sweep" then
        -- old: static sweep profile
        -- modifier = helpers.calc_gradient_sweep_shine(char_index, total_chars)
        modifier = cached_helper_call("gradient_sweep_shine", helpers.calc_gradient_sweep_shine, char_index, total_chars)
        local overlay = 1.0 + 0.10 * math.sin(shine_time_factor * 0.4)
        modifier = modifier * overlay
    elseif shine_prog_mode == "mirror" then
        -- old: static symmetry about center
        -- modifier = helpers.calc_mirror_shine(char_index, total_chars)
        modifier = cached_helper_call("mirror_shine", helpers.calc_mirror_shine, char_index, total_chars)
        local overlay = 1.0 + 0.12 * math.sin(shine_time_factor * 0.6)
        modifier = modifier * overlay
    elseif shine_prog_mode == "plasma" then
        -- old: static plasma by index
        -- modifier = helpers.calc_plasma_shine(char_index)
        modifier = cached_helper_call("plasma_shine", helpers.calc_plasma_shine, char_index)
        local overlay = 1.0 + 0.12 * math.sin(shine_time_factor * 1.1 + char_index * 0.15)
        modifier = modifier * overlay
    elseif shine_prog_mode == "strobe" then
        modifier = cached_helper_call("strobe_shine", helpers.calc_strobe_shine, char_index, text_seed, shine_time_factor)
    elseif shine_prog_mode == "spotlight" then
        -- old: static spatial spotlight
        -- modifier = helpers.calc_spotlight_shine(char_index, total_chars)
        modifier = cached_helper_call("spotlight_shine", helpers.calc_spotlight_shine, char_index, total_chars)
        local overlay = 1.0 + 0.10 * math.sin(shine_time_factor * 0.9)
        modifier = modifier * overlay
    elseif shine_prog_mode == "flicker" then
        modifier = cached_helper_call("flicker_shine", helpers.calc_flicker_shine, char_index, text_seed, shine_time_factor)
    elseif shine_prog_mode == "wave" then
        modifier = cached_helper_call("wave_shine", helpers.calc_wave_shine, char_index, total_chars, false, shine_time_factor)
    elseif shine_prog_mode == "reverse_wave" then
        modifier = cached_helper_call("wave_shine_reverse", helpers.calc_wave_shine, char_index, total_chars, true, shine_time_factor)
    elseif shine_prog_mode == "sine_wave" then
        modifier = cached_helper_call("sine_wave_shine", helpers.calc_sine_wave_shine, char_index, shine_time_factor)
    else
        -- fallback: use strategy if present for any other unhandled modes
        local strategy_fallback = progression_strategies[shine_prog_mode]
        if strategy_fallback then
            modifier = strategy_fallback:calculate_shine_modifier(char_index, total_chars, text_seed)
        end
    end
    
    return math.max(SHINE_MODIFIERS.CLAMP_MIN, math.min(SHINE_MODIFIERS.CLAMP_MAX, modifier))
end

-- calculate shine progression modifier for a character (with caching)
local function get_shine_progression_modifier(char_index, total_chars, shine_prog_mode, text_seed)
    return cached_shine_calculation(char_index, total_chars, shine_prog_mode, text_seed, shine_step)
end


-- generate markup without caching (internal function)
local function generate_letter_markup_internal(text, base_phase_offset, options)
    if not text or text == "" then return "" end
    
    options = options or {}
    local colour_prog_mode = options.colour_prog_mode or current_colour_prog_mode
    local shine_prog_mode = options.shine_prog_mode or current_shine_prog_mode
    local mode_name = shimmer_mode
    
    -- validate UTF-8 and escape XML before processing
    local escaped_text = gears.string.xml_escape(text)
    
    -- check for invalid UTF-8 sequences and replace with safe fallback
    local safe_text = escaped_text:gsub("[\128-\255]+", function(match)
        -- replace problematic UTF-8 sequences with safe ASCII
        return "*"
    end)
    
    local chars = get_temp_table()
    
    -- split into individual characters (handle utf-8 safely)
    for i = 1, safe_text:len() do
        local char = safe_text:sub(i, i)
        if char ~= "" then
            table.insert(chars, char)
        end
    end
    
    -- generate random seed based on text for consistent random phases
    local text_seed = 0
    for i = 1, #text do
        text_seed = text_seed + string.byte(text, i)
    end
    
    local colored_chars = get_temp_table()
    for i, char in ipairs(chars) do
        if char:match("%s") then
            -- preserve whitespace
            table.insert(colored_chars, char)
        else
            local letter_phase = base_phase_offset or 0
            
            -- calculate color progression phase offset using new function
            local color_phase_offset = get_color_progression_offset(i, #chars, colour_prog_mode, text_seed)
            letter_phase = letter_phase + color_phase_offset
            
            -- get base color from palette
            local color = M.get_color(mode_name, #chars, letter_phase)
            
            -- apply shine progression modifier
            local shine_mod = get_shine_progression_modifier(i, #chars, shine_prog_mode, text_seed)
            color = get_shine_modified_color(color, shine_mod)
            
            table_insert(colored_chars, string_format('<span foreground="%s">%s</span>', color, char))
        end
    end
    
    local result = table_concat(colored_chars)
    return_temp_table(chars)
    return_temp_table(colored_chars)
    return result
end

-- per-character markup generation backed by the per-text cache
-- animation steps advance every tick, so change detection per character can
-- never hit; instead each frame pays one color sample and one span format per
-- character, and everything step-independent lives in the cache entry.

-- single-character XML escaping without a gsub call per char
local xml_escape_char = {
    ["&"] = "&amp;", ["<"] = "&lt;", [">"] = "&gt;",
    ['"'] = "&quot;", ["'"] = "&apos;",
}

-- build a per-text cache entry: collapse multi-byte UTF-8 runs to a
-- placeholder, then split into single-byte characters, escaping each one
-- individually. escaping the whole string first (e.g. "&" -> "&amp;") and then
-- splitting by byte tears multi-character entities apart across separate
-- <span> tags, which Pango's markup parser rejects.
local function build_text_entry(text)
    local safe_text = text:gsub("[\128-\255]+", "*")
    local n = safe_text:len()
    local chars = {}
    local raw_chars = {}
    local is_space = {}
    for i = 1, n do
        local char = safe_text:sub(i, i)
        chars[i] = xml_escape_char[char] or char
        raw_chars[i] = char
        is_space[i] = char:match("%s") ~= nil
    end
    -- generate text seed for consistent random phases
    local text_seed = 0
    for i = 1, #text do
        text_seed = text_seed + string.byte(text, i)
    end
    return { raw = safe_text, n = n, chars = chars, raw_chars = raw_chars,
             is_space = is_space, text_seed = text_seed }
end

-- core frame generator: returns the sanitised text plus a flat span list
-- {text_run, color_hex_or_false, ...} and a signature covering colours and
-- run boundaries so callers can skip identical frames cheaply
local function generate_spans(text, base_phase_offset, options)
    if not text or text == "" then return nil end

    options = options or {}
    local colour_prog_mode = options.colour_prog_mode or current_colour_prog_mode
    local shine_prog_mode = options.shine_prog_mode or current_shine_prog_mode
    local mode_name = shimmer_mode

    -- fetch or build the per-text entry
    local entry = differential_markup_cache[text]
    if entry then
        diff_cache_stats.hits = diff_cache_stats.hits + 1
    else
        entry = build_text_entry(text)
        diff_cache_stats.misses = diff_cache_stats.misses + 1
        diff_cache_stats.full_rebuilds = diff_cache_stats.full_rebuilds + 1
        if differential_cache_size >= DIFF_CACHE_MAX_ENTRIES then
            -- evict ~25% of entries once the cap is reached
            local new_cache = {}
            local count = 0
            local keep_count = math_floor(DIFF_CACHE_MAX_ENTRIES * THREE_QUARTERS)
            for key, value in pairs(differential_markup_cache) do
                if count < keep_count then
                    new_cache[key] = value
                    count = count + 1
                end
            end
            differential_markup_cache = new_cache
            differential_cache_size = count
        end
        differential_markup_cache[text] = entry
        differential_cache_size = differential_cache_size + 1
    end

    local n = entry.n
    local raw_chars = entry.raw_chars
    local is_space = entry.is_space
    local text_seed = entry.text_seed

    -- colour progression offsets are step-independent; rebuild only when the
    -- mode or the colour-disabled state changes
    local colour_disabled = color_speed_multiplier == 0
        or SHIMMER_DISABLE_COLOR or SHIMMER_SHINE_ONLY
    if entry.phase_mode ~= colour_prog_mode or entry.phase_disabled ~= colour_disabled then
        if colour_disabled then
            entry.phase_off = nil
        else
            local offsets = entry.phase_off or {}
            for i = 1, n do
                offsets[i] = get_color_progression_offset(i, n, colour_prog_mode, text_seed)
            end
            entry.phase_off = offsets
        end
        entry.phase_mode = colour_prog_mode
        entry.phase_disabled = colour_disabled
        diff_cache_stats.updates = diff_cache_stats.updates + 1
    end
    local phase_off = entry.phase_off

    -- shine modifiers rebuild when the quantized shine step advances or the
    -- mode/disabled state changes; disabled shine stores no array at all
    local shine_disabled = shine_speed_multiplier == 0 or SHIMMER_DISABLE_SHINE
        or shine_prog_mode == "shine_prog_off"
    if shine_disabled then
        entry.shine_mods = nil
        entry.shine_mode = shine_prog_mode
        entry.shine_qtime = nil
    else
        local shine_qtime = math_floor(shine_step / SHINE_TIME_QUANTIZATION + 0.5) * SHINE_TIME_QUANTIZATION
        if entry.shine_mode ~= shine_prog_mode or entry.shine_qtime ~= shine_qtime then
            local mods = entry.shine_mods or {}
            for i = 1, n do
                mods[i] = calculate_shine_modifier_internal(i, n, shine_prog_mode, text_seed, shine_step)
            end
            entry.shine_mods = mods
            entry.shine_mode = shine_prog_mode
            entry.shine_qtime = shine_qtime
            diff_cache_stats.updates = diff_cache_stats.updates + 1
        end
    end
    local shine_mods = entry.shine_mods

    -- character animation limiting - rebuild the selection only when the
    -- effective rotation epoch or the limiting config changes
    local animated_chars
    local max_animated_chars = M.get_max_animated_chars()  -- use function to get global override if set
    if max_animated_chars and max_animated_chars > 0 and max_animated_chars < n then
        local preset_config = get_preset_config(shimmer_mode)
        local strategy = preset_config and preset_config.char_selection_strategy or "wave"
        -- step*100 granularity covers every strategy's rotation input
        local anim_epoch = math_floor(char_animation_rotation_step * 100)
        if entry.anim_epoch ~= anim_epoch or entry.anim_strategy ~= strategy
            or entry.anim_max ~= max_animated_chars then
            entry.animated = select_animated_chars(n, max_animated_chars, strategy, text_seed)
            entry.anim_epoch = anim_epoch
            entry.anim_strategy = strategy
            entry.anim_max = max_animated_chars
            diff_cache_stats.updates = diff_cache_stats.updates + 1
        end
        animated_chars = entry.animated
    else
        entry.animated = nil
    end

    -- emit spans: one entry per animated character, one entry per run of
    -- consecutive non-animated characters (they all share static_color).
    -- whitespace runs carry color=false so direct-render widgets skip them.
    local spans = {}
    local sig_parts = get_temp_table()
    local base_phase = base_phase_offset or 0
    local static_color  -- computed lazily on the first non-animated char
    local out, k = 0, 0
    local i = 1

    while i <= n do
        if is_space[i] then
            out = out + 2
            spans[out - 1] = raw_chars[i]
            spans[out] = false
            i = i + 1
        elseif not animated_chars or animated_chars[i] then
            local letter_phase = base_phase + (phase_off and phase_off[i] or 0)
            local color = M.get_color(mode_name, n, letter_phase)
            local shine_mod = shine_mods and shine_mods[i] or 1.0
            if shine_mod ~= 1.0 then
                color = get_shine_modified_color(color, shine_mod)
            end
            out = out + 2
            spans[out - 1] = raw_chars[i]
            spans[out] = color
            k = k + 1
            sig_parts[k] = color .. i
            i = i + 1
        else
            -- static character run - single entry covering i..j-1
            if not static_color then
                static_color = M.get_color(mode_name, n, 0)  -- phase 0 for static
            end
            local j = i + 1
            while j <= n and not is_space[j] and not animated_chars[j] do
                j = j + 1
            end
            out = out + 2
            spans[out - 1] = table_concat(raw_chars, "", i, j - 1)
            spans[out] = static_color
            k = k + 1
            sig_parts[k] = static_color .. i .. j
            i = j
        end
    end

    local sig = table_concat(sig_parts, "|")
    return_temp_table(sig_parts)
    return entry.raw, spans, sig
end

-- escape a raw span run for markup output; single bytes go through the
-- lookup table, longer runs through the shared escaper
local function escape_span_text(t)
    if #t == 1 then return xml_escape_char[t] or t end
    return gears.string.xml_escape(t)
end

-- per-letter shimmer markup formatted from the span list
-- prevents white flashes by ensuring atomic markup updates
function M.get_letter_shimmer_markup(text, base_phase_offset, options)
    local raw, spans = generate_spans(text, base_phase_offset, options or {})
    if not raw then return "" end
    local parts = get_temp_table()
    for i = 1, #spans, 2 do
        local t, color = spans[i], spans[i + 1]
        if color then
            parts[#parts + 1] = string_format('<span foreground="%s">%s</span>', color, escape_span_text(t))
        else
            parts[#parts + 1] = t
        end
    end
    local result = table_concat(parts)
    return_temp_table(parts)
    return result
end

-- span-list variant for direct-render widgets (plugins.shimmer.textwidget):
-- returns the sanitised text, the flat {text, color|false, ...} span list,
-- and a signature that changes whenever colours or run boundaries change
function M.get_letter_shimmer_spans(text, base_phase_offset, options)
    return generate_spans(text, base_phase_offset, options or {})
end


-- // MARK: CORE API FUNCTIONS

-- main animation control functions
function M.set_mode(mode)
    if shimmer_config[mode] then
        shimmer_mode = mode
        
        -- sync current_preset_index to match the mode
        for i, preset_name in ipairs(preset_list) do
            if preset_name == mode then
                current_preset_index = i
                break
            end
        end
        
        -- apply speed settings from preset
        local config = get_preset_config(mode)
        if config then
            if config.color_speed then
                M.set_color_speed(config.color_speed)
            end
            if config.shine_speed then
                M.set_shine_speed(config.shine_speed)
            end
        end
        
        -- clear all cached palettes to force regeneration with new preset
        color_palettes = {}

        -- clear markup cache to prevent stale cached markup with old preset
        M.clear_markup_cache()
        
        -- update progression modes based on preset defaults
        local preset_config = get_preset_config(mode)
        if preset_config then
            if preset_config.colour_prog_mode then
                current_colour_prog_mode = preset_config.colour_prog_mode
            end
            if preset_config.shine_prog_mode then
                current_shine_prog_mode = preset_config.shine_prog_mode
            end
        end
        
        -- border notification is synchronous; the old 0.1s deferral timer is
        -- commented out but its stray `return false` would end the block early
        local border = require("plugins.shimmer.border")
        border.on_mode_changed(mode)

        -- preset name feeds the wibar status tooltip; emit from here so
        -- direct animation.cycle_preset callers are covered too
        awesome.emit_signal("shimmer::state_changed", M.is_running())
    end
end

function M.get_mode()
    return shimmer_mode
end

--- core color calculation with palette sampling for progression modes
function M.get_color(mode_config, text_length, phase_offset)
    local mode_name = mode_config or shimmer_mode or "warm_light"
    local config = get_preset_config(mode_name)
    
    if not config then
        return base_gold
    end
    
    -- handle static colors
    if config.speed == 0 or config.static_color then
        return config.static_color or base_gold
    end
    
    -- get pre-generated palette
    local palette = ensure_palette(mode_name)
    if not palette or #palette == 0 then
        return base_gold
    end
    
    if #palette < 2 then
        return palette[1] or base_gold
    end
    
    -- shine-only testing: freeze color animation and phase
    if SHIMMER_SHINE_ONLY then
        return palette[1] or base_gold
    end

    -- calculate animation phase using color-specific timing
    -- old: multiplied by preset/global again, double-counting preset speed
    -- local effective_speed = config.speed * global_speed_multiplier * 0.5
    -- new: preset speed only influences timer tick rate; color speed controlled via color_step
    local effective_speed = 0.5
    local base_time = color_step * effective_speed * animation_direction
    local length_factor = (text_length or 1) * 0.1
    local phase_factor = (phase_offset or 0) * 0.3  -- phase offset affects palette position
    local animation_phase = base_time + length_factor + phase_factor
    
    -- sample from palette with ping-pong animation
    local palette_size = #palette
    
    -- guard against small palettes
    if palette_size < 2 then
        return palette[1] or base_gold
    end
    
    local cycle_length = palette_size * 2 - 2
    local raw_index = math.floor(math.abs(animation_phase) * 8) % cycle_length
    local palette_index
    
    if raw_index < palette_size then
        palette_index = raw_index
    else
        palette_index = cycle_length - raw_index
    end
    
    -- clamp palette_index to valid range [0, palette_size-1]
    palette_index = math.max(0, math.min(palette_size - 1, palette_index))
    
    return palette[palette_index + 1] or base_gold
end

function M.start()
    if shimmer_timer then return end
    
    -- helper LUTs are cheap; palettes build lazily per preset via
    -- ensure_palette so enabling shimmer doesn't stall the main loop
    init_helper_optimization()
    
    -- create timer with dynamic interval based on speed multipliers
    shimmer_timer = gears.timer {
        timeout = get_dynamic_timer_interval(),
        autostart = false,  -- manual start to avoid double-start error
        callback = guarded(shimmer_tick)
    }
    
    -- start timer after creation
    if shimmer_timer then
        shimmer_timer:start()
    end
end

function M.stop()
    if shimmer_timer then
        shimmer_timer:stop()
        shimmer_timer = nil
    end
end

function M.is_running()
    return shimmer_timer ~= nil
end

function M.restart()
    M.stop()
    shimmer_step = 0
    color_step = 0.1
    shine_step = 0.1
    M.start()
end


-- // MARK: SPEED CONTROL API

-- set color progression speed multiplier (0 = disabled)
function M.set_color_speed(speed)
    color_speed_multiplier = math.max(0, math.min(5.0, speed or 1.0))
end

-- set shine progression speed multiplier (0 = disabled)
function M.set_shine_speed(speed)
    shine_speed_multiplier = math.max(0, math.min(5.0, speed or 1.0))
end

-- get current speed multipliers
function M.get_color_speed()
    return color_speed_multiplier
end

function M.get_shine_speed()
    return shine_speed_multiplier
end

-- set both speeds at once
function M.set_progression_speeds(color_speed, shine_speed)
    M.set_color_speed(color_speed)
    M.set_shine_speed(shine_speed)
end

function M.get_base_gold()
    return base_gold
end

function M.get_status_prefix(client)
    return get_client_status_prefix(client)
end

function M.apply_to_widget(widget, text, status_symbols, options)
    if not widget or not widget.set_markup then return end
    if widget.__hover_lock or widget.__hover_fade_lock then return end
    -- note: no lazy-start here. this runs from signal handlers that fire even
    -- while shimmer is disabled; starting the timer from here would defeat
    -- the off state and keep the per-frame churn alive.
    
    local display_text = (status_symbols or "") .. (text or "")
    if display_text == "" then return end
    
    options = options or {}
    local phase_offset = options.phase_offset or 0
    
    -- use enhanced per-character logic
    local use_per_character = M.should_use_per_character(options)

    -- direct-render widgets take the span list and skip Pango markup parsing
    if use_per_character and widget.set_shimmer_frame then
        local raw, spans, sig = M.get_letter_shimmer_spans(display_text, phase_offset, options)
        if raw then widget:set_shimmer_frame(raw, spans, sig) end
        return
    end

    local markup

    if use_per_character then
        markup = M.get_letter_shimmer_markup(display_text, phase_offset, options)
    else
        -- old solid branch (kept for reference): applied base color only
        --[[
        local solid_phase = (options and options.use_phase_when_solid) and (options.phase_offset or 0) or 0
        local shimmer_color = M.get_color(nil, #display_text, solid_phase)
        local markup = '<span foreground="' .. shimmer_color .. '">' ..
                       gears.string.xml_escape(display_text) .. '</span>'
        if widget.__original_set_markup then
            widget.__original_set_markup(widget, markup)
        else
            widget:set_markup(markup)
        end
        ]]

        -- new solid branch: also apply shine progression uniformly to whole string
        -- when per-character is off, optionally allow phase_offset for targeted variance
        local solid_phase = (options and options.use_phase_when_solid) and (options.phase_offset or 0) or 0
        local shimmer_color = M.get_color(nil, #display_text, solid_phase)
        -- derive a deterministic seed from the text
        local text_seed = 0
        for i = 1, #display_text do
            text_seed = text_seed + string.byte(display_text, i)
        end
        -- pick a representative index (middle character) for solid shine
        local mid_index = math.max(1, math.floor(#display_text / 2))
        local shine_prog_mode = (options and options.shine_prog_mode) or current_shine_prog_mode
        local shine_mod = get_shine_progression_modifier(mid_index, #display_text, shine_prog_mode, text_seed)
        if shine_mod ~= 1.0 then
            -- use cached HSV conversion for solid colors too
            shimmer_color = get_shine_modified_color(shimmer_color, shine_mod)
        end

        markup = '<span foreground="' .. shimmer_color .. '">' ..
                 gears.string.xml_escape(display_text) .. '</span>'
    end

    -- skip the write (and the Pango re-parse it triggers) when nothing changed
    if markup == widget.__last_shimmer_markup then return end
    -- use original method if widget is protected, otherwise use normal method
    if widget.__original_set_markup then
        widget.__original_set_markup(widget, markup)
    else
        widget:set_markup(markup)
    end
    widget.__last_shimmer_markup = markup
end

function M.get_palette(mode_name)
    local mode = mode_name or shimmer_mode
    return ensure_palette(mode)
end

function M.get_gradient_params(mode_name)
    local cfg = get_preset_config(mode_name or shimmer_mode)
    if not cfg then return nil end
    if cfg.color_gen_type == "gradient" then
        return cfg.color_gen_params or cfg.gradient
    end
    return nil
end

function M.set_gradient_params(mode_name, params)
    if not shimmer_config[mode_name] then return false end
    
    local preset = shimmer_config[mode_name]
    if preset.color_gen and preset.color_gen.type == "gradient" then
        preset.color_gen.params = params
    else
        -- backward compatibility with legacy structure
        preset.gradient = params
    end
    -- clear cached palette so the new gradient takes effect immediately
    color_palettes[mode_name] = nil
    
    return true
end

function M.clear_palette_cache(mode_name)
    if mode_name then
        color_palettes[mode_name] = nil
    else
        color_palettes = {}
    end
end

-- cache management and debugging functions
-- the per-text cache replaced the old step-bucketed markup cache
function M.clear_markup_cache()
    M.clear_diff_cache()
end

function M.get_cache_stats()
    return M.get_diff_cache_stats()
end

-- HSV cache management
function M.clear_hsv_cache()
    hsv_shine_cache = {}
    hsv_cache_stats = { hits = 0, misses = 0, size = 0 }
end

function M.get_hsv_cache_stats()
    local hit_rate = hsv_cache_stats.hits + hsv_cache_stats.misses > 0 
        and (hsv_cache_stats.hits / (hsv_cache_stats.hits + hsv_cache_stats.misses) * 100) or 0
    return {
        hits = hsv_cache_stats.hits,
        misses = hsv_cache_stats.misses,
        size = hsv_cache_stats.size,
        hit_rate = string.format("%.1f%%", hit_rate),
        max_entries = MAX_HSV_CACHE_ENTRIES
    }
end

-- markup template cache management
function M.clear_template_cache()
    template_cache = {}
    template_stats = { hits = 0, misses = 0, size = 0 }
end

function M.get_template_cache_stats()
    local hit_rate = template_stats.hits + template_stats.misses > 0 
        and (template_stats.hits / (template_stats.hits + template_stats.misses) * 100) or 0
    return {
        hits = template_stats.hits,
        misses = template_stats.misses,
        size = template_stats.size,
        hit_rate = string.format("%.1f%%", hit_rate),
        max_entries = TEMPLATE_CACHE_MAX_ENTRIES
    }
end

-- memory pool management
function M.clear_table_pool()
    table_pool = {}
    pool_stats = { allocated = 0, reused = 0, size = 0 }
end

function M.get_table_pool_stats()
    local reuse_rate = pool_stats.allocated > 0 
        and (pool_stats.reused / pool_stats.allocated * 100) or 0
    return {
        allocated = pool_stats.allocated,
        reused = pool_stats.reused,
        pool_size = pool_stats.size,
        max_pool_size = TABLE_POOL_MAX_SIZE,
        reuse_rate = string.format("%.1f%%", reuse_rate)
    }
end

-- widget lock optimization management
function M.clear_widget_locks()
    widget_locks = setmetatable({}, { __mode = "k" })
    lock_bitmap = {}
    widget_id_map = setmetatable({}, { __mode = "k" })
    next_widget_id = 1
    lock_stats = { locks_set = 0, locks_cleared = 0, bitmap_hits = 0, table_fallbacks = 0 }
end

function M.get_widget_lock_stats()
    local bitmap_efficiency = lock_stats.bitmap_hits + lock_stats.table_fallbacks > 0
        and (lock_stats.bitmap_hits / (lock_stats.bitmap_hits + lock_stats.table_fallbacks) * 100) or 0
    return {
        locks_set = lock_stats.locks_set,
        locks_cleared = lock_stats.locks_cleared,
        bitmap_hits = lock_stats.bitmap_hits,
        table_fallbacks = lock_stats.table_fallbacks,
        bitmap_efficiency = string.format("%.1f%%", bitmap_efficiency),
        active_widgets = next_widget_id - 1
    }
end

-- expose lock functions for integrations module
M.set_widget_lock = set_widget_lock
M.is_widget_locked = is_widget_locked
M.clear_widget_lock = clear_widget_lock

-- performance control: FPS management
function M.set_target_fps(fps)
    fps = fps or 60
    target_fps = math.max(15, math.min(120, fps))  -- clamp to reasonable range
    
    -- update timer interval if running
    if shimmer_timer then
        shimmer_timer.timeout = get_dynamic_timer_interval()
    end
    
    return target_fps
end

function M.get_target_fps()
    return target_fps
end

function M.add_preset(preset_config)
    local name = preset_config.name or "custom"
    local preset = {
        speed = preset_config.speed or 0.3,
        gradient = preset_config.gradient or {
            redFrequency = 0.05,
            grnFrequency = 0.08,
            bluFrequency = 0.02,
            phase1 = 0, phase2 = 2, phase3 = 4,
            center = 200, width = 50
        }
    }
    shimmer_config[name] = preset
    
    -- add to preset list if not already there
    local found = false
    for _, preset_name in ipairs(preset_list) do
        if preset_name == name then
            found = true
            break
        end
    end
    if not found then
        table.insert(preset_list, name)
    end
end

function M.get_preset_list()
    return preset_list
end

function M.get_progression_modes_list()
    -- legacy: returns colour list for compatibility
    return progression_modes_list
end

-- explicit mode lists for ui/notifications
function M.get_colour_progression_modes_list()
    return colour_progression_modes_list
end

function M.get_shine_progression_modes_list()
    return shine_progression_modes_list
end

function M.get_current_preset()
    return shimmer_mode
end

function M.get_preset_config(preset_name)
    return get_preset_config(preset_name)
end

function M.cycle_preset(direction)
    direction = direction or 1  -- default to forward
    
    if direction > 0 then
        current_preset_index = current_preset_index + 1
        if current_preset_index > #preset_list then
            current_preset_index = 1
        end
    else
        current_preset_index = current_preset_index - 1
        if current_preset_index < 1 then
            current_preset_index = #preset_list
        end
    end
    
    local new_preset = preset_list[current_preset_index]
    M.set_mode(new_preset)
    
    -- update timer interval since preset speed may have changed
    update_timer_interval()
    
    -- force immediate palette regeneration and widget update
    gears.timer.start_new(0.05, guarded(function()
        get_integrations().update_widgets()
        return false
    end))
    
    return new_preset, current_preset_index, #preset_list
end

-- backwards compatibility wrapper
function M.cycle_preset_reverse()
    return M.cycle_preset(-1)
end

-- // MARK: PER-CHARACTER CONTROLS


-- direct progression mode setter: applies specific granular mode with visual refresh
-- validates mode exists before applying, returns success status
function M.set_per_character_mode(mode)
    -- validate mode exists in progression_modes_list
    for _, valid_mode in ipairs(progression_modes_list) do
        if valid_mode == mode then
            current_per_character_mode = mode
            -- force immediate widget update to apply new progression
            get_integrations().update_widgets()
            return true
        end
    end
    return false
end

function M.get_per_character_mode()
    return current_per_character_mode
end

-- progression mode cycling: steps through granular animation modes
-- forces widget refresh to immediately show new character phase patterns
function M.cycle_per_character_mode(direction)
    direction = direction or 1  -- default to forward
    local modes = progression_modes_list
    local current_index = current_progression_index
    
    for i, mode in ipairs(modes) do
        if mode == current_per_character_mode then
            current_index = i
            break
        end
    end
    
    if direction > 0 then
        current_index = current_index + 1
        if current_index > #modes then
            current_index = 1
        end
    else
        current_index = current_index - 1
        if current_index < 1 then
            current_index = #modes
        end
    end
    
    current_per_character_mode = modes[current_index]
    current_progression_index = current_index
    
    -- force immediate widget update to show new progression
    get_integrations().update_widgets()
    
    return current_per_character_mode, current_index, #modes
end

-- separate color and shine progression cycling functions
function M.cycle_colour_prog_mode(direction)
    direction = direction or 1
    local modes = colour_progression_modes_list
    
    if direction > 0 then
        current_colour_prog_index = (current_colour_prog_index % #modes) + 1
    else
        current_colour_prog_index = current_colour_prog_index - 1
        if current_colour_prog_index < 1 then
            current_colour_prog_index = #modes
        end
    end
    
    current_colour_prog_mode = modes[current_colour_prog_index]
    get_integrations().update_widgets()
    return current_colour_prog_mode, current_colour_prog_index, #modes
end

function M.cycle_shine_prog_mode(direction)
    direction = direction or 1  -- default to forward
    
    local modes = shine_progression_modes_list
    
    if direction > 0 then
        current_shine_prog_index = current_shine_prog_index + 1
        if current_shine_prog_index > #modes then
            current_shine_prog_index = 1
        end
    else
        current_shine_prog_index = current_shine_prog_index - 1
        if current_shine_prog_index < 1 then
            current_shine_prog_index = #modes
        end
    end
    
    current_shine_prog_mode = modes[current_shine_prog_index]
    get_integrations().update_widgets()
    return current_shine_prog_mode, current_shine_prog_index, #modes
end


function M.get_colour_prog_mode()
    return current_colour_prog_mode
end

function M.get_shine_prog_mode()
    return current_shine_prog_mode
end

-- backwards compatibility aliases
function M.get_color_progression_mode()
    return current_colour_prog_mode
end

function M.get_shine_progression_mode()
    return current_shine_prog_mode
end

function M.get_color_progression_offset_sample(mode)
    return get_color_progression_offset(5, 10, mode or current_colour_prog_mode, 0)
end

function M.get_shine_progression_offset_sample(mode)
    return get_shine_progression_modifier(5, 10, mode or current_shine_prog_mode, 0)
end

-- get sample progression offsets for display (using middle character of a 10-char string)
function M.get_colour_prog_offset_sample(mode)
    return get_color_progression_offset(5, 10, mode or current_colour_prog_mode, 0)
end

-- (deduped) get_shine_progression_offset_sample is defined above

function M.set_colour_prog_mode(mode)
    for i, prog_mode in ipairs(colour_progression_modes_list) do
        if prog_mode == mode then
            current_colour_prog_mode = mode
            current_colour_prog_index = i
            get_integrations().update_widgets()
            return true
        end
    end
    return false
end

function M.set_shine_prog_mode(mode)
    for i, prog_mode in ipairs(shine_progression_modes_list) do
        if prog_mode == mode then
            current_shine_prog_mode = mode
            current_shine_prog_index = i
            get_integrations().update_widgets()
            return true
        end
    end
    return false
end

-- backwards compatibility wrapper
function M.cycle_per_character_mode_reverse()
    return M.cycle_per_character_mode(-1)
end

function M.get_per_character_modes()
    return progression_modes_list
end

-- per-character shimmer logic: applies granular progression modes to text
-- each character gets phase offset based on position and selected progression mode
-- modes range from uniform (all same) to chaos (high randomness)
function M.should_use_per_character(options)
    options = options or {}
    
    -- explicit override in options takes precedence
    if options.per_letter ~= nil then
        return options.per_letter
    end
    
    -- use per-character only if at least one axis varies across characters
    -- colour off + shine uniform/off => no need for per-letter spans
    local color_is_off = (current_colour_prog_mode == "colour_prog_off")
    local shine_is_uniform = (current_shine_prog_mode == "uniform" or current_shine_prog_mode == "shine_prog_off")
    return not (color_is_off and shine_is_uniform)
end

-- // MARK: COLOR UTILITIES

-- enhanced color interpolation for smoother fade transitions
function M.interpolate_color(color1, color2, factor)
    -- parse hex colors
    local function parse_hex(hex)
        hex = hex:gsub("#", "")
        return {
            r = tonumber(hex:sub(1,2), 16) or 0,
            g = tonumber(hex:sub(3,4), 16) or 0, 
            b = tonumber(hex:sub(5,6), 16) or 0
        }
    end
    
    -- convert RGB to HSL for better color interpolation
    local function rgb_to_hsl(r, g, b)
        r, g, b = r/255, g/255, b/255
        local max = math.max(r, g, b)
        local min = math.min(r, g, b)
        local h, s, l = 0, 0, (max + min) / 2

        if max == min then
            h, s = 0, 0 -- achromatic
        else
            local d = max - min
            s = l > 0.5 and d / (2 - max - min) or d / (max + min)
            if max == r then
                h = (g - b) / d + (g < b and 6 or 0)
            elseif max == g then
                h = (b - r) / d + 2
            elseif max == b then
                h = (r - g) / d + 4
            end
            h = h / 6
        end
        return h, s, l
    end

    -- convert HSL back to RGB
    local function hsl_to_rgb(h, s, l)
        local function hue_to_rgb(p, q, t)
            if t < 0 then t = t + 1 end
            if t > 1 then t = t - 1 end
            if t < 1/6 then return p + (q - p) * 6 * t end
            if t < 1/2 then return q end
            if t < 2/3 then return p + (q - p) * (2/3 - t) * 6 end
            return p
        end

        local r, g, b
        if s == 0 then
            r, g, b = l, l, l -- achromatic
        else
            local q = l < 0.5 and l * (1 + s) or l + s - l * s 
            local p = 2 * l - q
            r = hue_to_rgb(p, q, h + 1/3)
            g = hue_to_rgb(p, q, h)
            b = hue_to_rgb(p, q, h - 1/3)
        end
        return math.floor(r * 255), math.floor(g * 255), math.floor(b * 255)
    end
    
    local c1 = parse_hex(color1)
    local c2 = parse_hex(color2)
    
    -- use HSL interpolation for more natural color transitions
    local h1, s1, l1 = rgb_to_hsl(c1.r, c1.g, c1.b)
    local h2, s2, l2 = rgb_to_hsl(c2.r, c2.g, c2.b)
    
    -- interpolate in HSL space
    local h = h1 + (h2 - h1) * factor
    local s = s1 + (s2 - s1) * factor
    local l = l1 + (l2 - l1) * factor
    
    -- convert back to RGB
    local r, g, b = hsl_to_rgb(h, s, l)
    
    -- clamp values
    r = math.max(0, math.min(255, r))
    g = math.max(0, math.min(255, g))
    b = math.max(0, math.min(255, b))
    
    return string_format("#%02x%02x%02x", r, g, b)
end

-- // MARK: HELPER FUNCTION OPTIMIZATION API

-- clear helper function cache
M.clear_helper_cache = function()
    helper_cache = {}
    helper_cache_stats = { hits = 0, misses = 0, size = 0 }
end

-- get helper cache statistics
M.get_helper_cache_stats = function()
    local hit_rate = helper_cache_stats.hits + helper_cache_stats.misses > 0 
        and (helper_cache_stats.hits / (helper_cache_stats.hits + helper_cache_stats.misses)) * 100 or 0
    return {
        hits = helper_cache_stats.hits,
        misses = helper_cache_stats.misses,
        size = helper_cache_stats.size,
        hit_rate = hit_rate,
        max_size = HELPER_CACHE_MAX_SIZE
    }
end

-- clear shine calculation cache
M.clear_shine_cache = function()
    shine_calculation_cache = {}
    shine_calc_cache_stats = { hits = 0, misses = 0, size = 0 }
end

-- get shine calculation cache statistics
M.get_shine_cache_stats = function()
    local hit_rate = shine_calc_cache_stats.hits + shine_calc_cache_stats.misses > 0 
        and (shine_calc_cache_stats.hits / (shine_calc_cache_stats.hits + shine_calc_cache_stats.misses)) * 100 or 0
    return {
        hits = shine_calc_cache_stats.hits,
        misses = shine_calc_cache_stats.misses,
        size = shine_calc_cache_stats.size,
        hit_rate = hit_rate,
        max_size = SHINE_CALC_CACHE_MAX_ENTRIES,
        time_quantization = SHINE_TIME_QUANTIZATION
    }
end

-- clear per-text markup cache
M.clear_diff_cache = function()
    differential_markup_cache = {}
    differential_cache_size = 0
    diff_cache_stats = { hits = 0, misses = 0, updates = 0, full_rebuilds = 0 }
end

-- get differential markup cache statistics
M.get_diff_cache_stats = function()
    local total_operations = diff_cache_stats.hits + diff_cache_stats.misses
    local hit_rate = total_operations > 0 and (diff_cache_stats.hits / total_operations) * 100 or 0
    local update_rate = total_operations > 0 and (diff_cache_stats.updates / total_operations) * 100 or 0
    return {
        hits = diff_cache_stats.hits,
        misses = diff_cache_stats.misses,
        updates = diff_cache_stats.updates,
        full_rebuilds = diff_cache_stats.full_rebuilds,
        hit_rate = hit_rate,
        update_rate = update_rate,
        max_size = DIFF_CACHE_MAX_ENTRIES
    }
end

-- get current progression strategy for external use (e.g., border animation)
M.get_current_strategy = function()
    local strategy = progression_strategies[current_colour_prog_mode]
    return strategy
end

return M
