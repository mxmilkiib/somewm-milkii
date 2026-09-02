-- shimmer helper functions module
-- provides color and shine progression calculation functions
-- separated for modularity and performance optimization

local M = {}

-- import constants from constants module (proper way to avoid circular dependency)
local constants = require("plugins.shimmer.constants")
local PHASE_MULTIPLIERS = constants.PHASE_MULTIPLIERS
local SHINE_MODIFIERS = constants.SHINE_MODIFIERS

-- // MARK: CONSTANT FOLDING & MATH OPTIMIZATION
-- pre-calculated mathematical constants
local TWO_PI = 2 * math.pi
local HALF = 0.5

-- cached math functions for performance
local math_sin, math_cos, math_floor, math_abs, math_max, math_min = 
      math.sin, math.cos, math.floor, math.abs, math.max, math.min
local math_exp, math_sqrt, math_random, math_randomseed = 
      math.exp, math.sqrt, math.random, math.randomseed
local math_pow = math.pow

-- deterministic noise function for time-based variation without seeding global RNG
local function _fract(x) return x - math_floor(x) end
local function _noise1(x)
    return _fract(math_sin(x) * 43758.5453123)
end
-- deterministic and cheap; keeps visuals stable without touching global rng

-- // MARK: COLOR PROGRESSION HELPERS
-- spatial/temporal offsets per char; balanced for variety vs cost

-- individual color progression calculation functions
local function calc_wave_offset(char_index, total_chars, reverse)
    if reverse then
        return (total_chars - char_index + 1) * PHASE_MULTIPLIERS.WAVE_STEP
    else
        return (char_index - 1) * PHASE_MULTIPLIERS.WAVE_STEP
    end
end

local function calc_sine_wave_offset(char_index)
    return math_sin((char_index - 1) * 0.6) * PHASE_MULTIPLIERS.SINE_AMPLITUDE
end

local function calc_center_out_offset(char_index, total_chars)
    local center = (total_chars + 1) / 2
    local distance = math_abs(char_index - center)
    return distance * PHASE_MULTIPLIERS.CENTER_OUT_STEP
end

local function calc_edges_in_offset(char_index, total_chars)
    local center = (total_chars + 1) / 2
    local distance = math_abs(char_index - center)
    return (total_chars / 2 - distance) * PHASE_MULTIPLIERS.EDGES_IN_STEP
end

local function calc_pulse_offset(char_index)
    local pulse_freq = HALF
    return math_sin((char_index - 1) * pulse_freq) * PHASE_MULTIPLIERS.PULSE_AMPLITUDE
end

local function calc_fibonacci_offset(char_index)
    local function fib(n)
        if n <= 1 then return n end
        local a, b = 0, 1
        for j = 2, n do a, b = b, a + b end
        return b
    end
    return fib(char_index % 12) * PHASE_MULTIPLIERS.FIBONACCI_SCALE
end

local function calc_spiral_offset(char_index)
    local angle = (char_index - 1) * PHASE_MULTIPLIERS.SPIRAL_BASE
    return math_sin(angle * 0.3) * PHASE_MULTIPLIERS.SPIRAL_SINE_SCALE
end

local function calc_rainbow_offset(char_index, total_chars)
    return ((char_index - 1) / math_max(1, total_chars - 1)) * PHASE_MULTIPLIERS.RAINBOW_SCALE
end

local function calc_random_offset(char_index, text_seed, scale)
    -- old rng-based implementation (commented out to avoid global rng reseeding)
    -- math_randomseed(text_seed + char_index)
    -- return math_random() * scale
    -- new: deterministic noise for stability and performance
    local n = _noise1((text_seed + char_index) * 0.47)
    return n * scale
end

local function calc_ripple_offset(char_index, total_chars)
    local center = (total_chars + 1) / 2
    local distance = math_abs(char_index - center)
    local ripple_wave = math_sin(distance * PHASE_MULTIPLIERS.RIPPLE_FREQ) * math_exp(-distance * PHASE_MULTIPLIERS.RIPPLE_DECAY)
    return ripple_wave * PHASE_MULTIPLIERS.RIPPLE_AMPLITUDE
end

local function calc_flow_offset(char_index, total_chars, text_seed)
    local flow_base = (char_index - 1) / math_max(1, total_chars - 1) * PHASE_MULTIPLIERS.FLOW_SCALE
    -- old rng-based turbulence (commented out to avoid global rng reseeding)
    -- math_randomseed(text_seed + char_index)
    -- local turbulence = (math_random() - HALF) * PHASE_MULTIPLIERS.FLOW_TURBULENCE
    -- return flow_base + turbulence
    -- new: deterministic noise-based turbulence
    local n = _noise1((text_seed + char_index * 7) * 0.31)
    local turbulence = (n - HALF) * PHASE_MULTIPLIERS.FLOW_TURBULENCE
    return flow_base + turbulence
end

local function calc_breathing_offset(char_index)
    local primary = math_sin((char_index - 1) * PHASE_MULTIPLIERS.BREATHING_PRIMARY) * PHASE_MULTIPLIERS.BREATHING_AMPLITUDE
    local secondary = math_sin((char_index - 1) * PHASE_MULTIPLIERS.BREATHING_SECONDARY) * PHASE_MULTIPLIERS.BREATHING_SECONDARY_AMP
    return primary + secondary
end

local function calc_cascade_offset(char_index)
    local cascade_delay = (char_index - 1) * PHASE_MULTIPLIERS.CASCADE_STEP
    local cascade_wave = math_sin((char_index - 1) * PHASE_MULTIPLIERS.CASCADE_SINE_FREQ) * PHASE_MULTIPLIERS.CASCADE_SINE_AMP
    return cascade_delay + cascade_wave
end

local function calc_typewriter_offset(char_index, total_chars)
    local reveal_progress = (char_index - 1) / math_max(1, total_chars - 1)
    local typewriter_wave = math_sin(reveal_progress * PHASE_MULTIPLIERS.TYPEWRITER_SINE_FREQ) * PHASE_MULTIPLIERS.TYPEWRITER_SINE_AMP
    return reveal_progress * PHASE_MULTIPLIERS.TYPEWRITER_SCALE + typewriter_wave
end

local function calc_gradient_sweep_offset(char_index, total_chars)
    local sweep_progress = (char_index - 1) / math_max(1, total_chars - 1)
    return sweep_progress * PHASE_MULTIPLIERS.GRADIENT_SWEEP_SCALE
end

local function calc_mirror_offset(char_index, total_chars)
    local center = (total_chars + 1) / 2
    local distance = math_abs(char_index - center)
    local mirror_base = distance * PHASE_MULTIPLIERS.MIRROR_STEP
    local mirror_wave = math_sin(distance * PHASE_MULTIPLIERS.MIRROR_SINE_FREQ) * PHASE_MULTIPLIERS.MIRROR_SINE_AMP
    return mirror_base + mirror_wave
end

local function calc_plasma_offset(char_index)
    local plasma_wave = math_sin((char_index - 1) * PHASE_MULTIPLIERS.ZIGZAG_FREQ) * PHASE_MULTIPLIERS.ZIGZAG_AMP
    local plasma_base = (char_index - 1) * PHASE_MULTIPLIERS.ZIGZAG_BASE_STEP
    return plasma_base + plasma_wave
end

local function calc_spotlight_offset(char_index, total_chars)
    local center = (total_chars + 1) / 2
    local distance = math_abs(char_index - center)
    local spotlight_intensity = math_exp(-distance * PHASE_MULTIPLIERS.SPOTLIGHT_DECAY)
    return spotlight_intensity * PHASE_MULTIPLIERS.SPOTLIGHT_SCALE
end

local function calc_strobe_offset(char_index, text_seed)
    -- old rng-based toggle (commented out to avoid global rng reseeding)
    -- math_randomseed(text_seed + char_index)
    -- return math_random() > HALF and 8.0 or 0
    -- new: deterministic strobe gate using noise threshold
    local n = _noise1((text_seed + char_index * 11) * 0.39)
    return (n > HALF) and 8.0 or 0
end

local function calc_flicker_offset(char_index, text_seed)
    -- old rng-based flicker (commented out to avoid global rng reseeding)
    -- math_randomseed(text_seed + char_index * 3)
    -- local flicker_base = (char_index - 1) * PHASE_MULTIPLIERS.FLICKER_BASE_AMP
    -- local flicker_random = (math_random() - HALF) * PHASE_MULTIPLIERS.FLICKER_RANDOM_AMP
    -- return flicker_base + flicker_random
    -- new: deterministic noise-based flicker
    local flicker_base = (char_index - 1) * PHASE_MULTIPLIERS.FLICKER_BASE_AMP
    local n = _noise1((text_seed + char_index * 13) * 0.27)
    local flicker_random = (n - HALF) * PHASE_MULTIPLIERS.FLICKER_RANDOM_AMP
    return flicker_base + flicker_random
end


-- // MARK: SHINE PROGRESSION HELPERS

-- individual shine progression calculation functions
local function calc_wave_shine(char_index, total_chars, reverse, time_factor)
    time_factor = time_factor or 0
    local base_phase = reverse and ((total_chars - char_index + 1) - 1) / total_chars * TWO_PI 
                                or (char_index - 1) / total_chars * TWO_PI
    local time_phase = time_factor * 0.1  -- scale time influence
    return SHINE_MODIFIERS.BASE_MIN + SHINE_MODIFIERS.RANGE_VARIATION * math_sin(base_phase + time_phase)
end

local function calc_sine_wave_shine(char_index, time_factor)
    time_factor = time_factor or 0
    local base_phase = (char_index - 1) * 0.6
    local time_phase = time_factor * 0.05
    return SHINE_MODIFIERS.BASE_MIN + SHINE_MODIFIERS.RANGE_VARIATION * math_sin(base_phase + time_phase)
end

local function calc_center_out_shine(char_index, total_chars)
    local center = (total_chars + 1) / 2
    local distance = math_abs(char_index - center) / (total_chars / 2)
    return SHINE_MODIFIERS.BASE_MAX - (distance * SHINE_MODIFIERS.MIRROR_VARIATION)
end

local function calc_edges_in_shine(char_index, total_chars)
    local center = (total_chars + 1) / 2
    local distance = math_abs(char_index - center) / (total_chars / 2)
    return SHINE_MODIFIERS.MIRROR_BASE + (distance * SHINE_MODIFIERS.MIRROR_VARIATION)
end

local function calc_pulse_shine(char_index, time_factor)
    time_factor = time_factor or 0
    local pulse_freq = HALF
    local base_phase = (char_index - 1) * pulse_freq
    local time_phase = time_factor * 0.2
    return SHINE_MODIFIERS.MIRROR_BASE + SHINE_MODIFIERS.MIRROR_VARIATION * math_abs(math_sin(base_phase + time_phase))
end

local function calc_fibonacci_shine(char_index)
    local function fib(n)
        if n <= 1 then return n end
        local a, b = 0, 1
        for j = 2, n do a, b = b, a + b end
        return b
    end
    local fib_val = fib(char_index % 12)
    return SHINE_MODIFIERS.FIBONACCI_BASE + (fib_val % 5) * SHINE_MODIFIERS.FIBONACCI_STEP
end

local function calc_spiral_shine(char_index)
    local angle = (char_index - 1) * PHASE_MULTIPLIERS.SPIRAL_BASE
    return SHINE_MODIFIERS.BASE_MIN + SHINE_MODIFIERS.RANGE_VARIATION * math_abs(math_sin(angle * 0.3))
end

local function calc_rainbow_shine(char_index, total_chars)
    return SHINE_MODIFIERS.BASE_MIN + SHINE_MODIFIERS.RANGE_VARIATION * ((char_index - 1) / math_max(1, total_chars - 1))
end

-- old (kept): static drift variation
--[[
local function calc_drift_shine(char_index, total_chars, text_seed)
    local flow_shine = (char_index - 1) / math.max(1, total_chars - 1)
    math.randomseed(text_seed + char_index)
    local variation = (math.random() - 0.5) * SHINE_MODIFIERS.DRIFT_VARIATION
    return SHINE_MODIFIERS.DRIFT_BASE + SHINE_MODIFIERS.RANGE_VARIATION * flow_shine + variation
end
]]
local function calc_drift_shine(char_index, total_chars, text_seed, time_factor)
    local flow_shine = (char_index - 1) / math.max(1, total_chars - 1)
    local n = _noise1((text_seed + char_index) * 0.73 + (time_factor or 0) * 0.5)
    local variation = (n - 0.5) * SHINE_MODIFIERS.DRIFT_VARIATION
    return SHINE_MODIFIERS.DRIFT_BASE + SHINE_MODIFIERS.RANGE_VARIATION * flow_shine + variation
end

-- old (kept): static random brightness
--[[
local function calc_random_shine(char_index, text_seed)
    math.randomseed(text_seed + char_index)
    return SHINE_MODIFIERS.RANDOM_BASE + (math.random() * SHINE_MODIFIERS.RANDOM_RANGE)
end
]]
local function calc_random_shine(char_index, text_seed, time_factor)
    local n = _noise1((text_seed + char_index * 13) * 0.51 + (time_factor or 0) * 1.3)
    return SHINE_MODIFIERS.RANDOM_BASE + n * SHINE_MODIFIERS.RANDOM_RANGE
end

local function calc_ripple_shine(char_index, total_chars)
    local center = (total_chars + 1) / 2
    local distance = math_abs(char_index - center)
    local decay = math_exp(-distance * 0.2)
    return SHINE_MODIFIERS.RIPPLE_BASE + SHINE_MODIFIERS.RIPPLE_RANGE * decay
end

-- old (kept): static flow variation
--[[
local function calc_flow_shine(char_index, total_chars, text_seed)
    local flow_brightness = (char_index - 1) / math.max(1, total_chars - 1)
    math.randomseed(text_seed + char_index)
    local variation = (math.random() - 0.5) * SHINE_MODIFIERS.DRIFT_VARIATION
    return SHINE_MODIFIERS.FLOW_BASE + SHINE_MODIFIERS.RANGE_VARIATION * flow_brightness + variation
end
]]
local function calc_flow_shine(char_index, total_chars, text_seed, time_factor)
    local flow_brightness = (char_index - 1) / math_max(1, total_chars - 1)
    local n = _noise1((text_seed + char_index * 7) * 0.29 + (time_factor or 0) * 0.7)
    local variation = (n - HALF) * SHINE_MODIFIERS.DRIFT_VARIATION
    return SHINE_MODIFIERS.FLOW_BASE + SHINE_MODIFIERS.RANGE_VARIATION * flow_brightness + variation
end

local function calc_breathing_shine(char_index, time_factor)
    time_factor = time_factor or 0
    local base_phase = (char_index - 1) * PHASE_MULTIPLIERS.BREATHING_PRIMARY
    local time_phase = time_factor * 0.03  -- slower breathing with time
    local breath_phase = math_sin(base_phase + time_phase) * SHINE_MODIFIERS.BREATHING_VARIATION
    return SHINE_MODIFIERS.BREATHING_BASE + breath_phase
end

local function calc_cascade_shine(char_index, total_chars)
    local cascade_pos = (char_index - 1) / math_max(1, total_chars - 1)
    local cascade_wave = math_sin(cascade_pos * 4.0) * SHINE_MODIFIERS.CASCADE_VARIATION
    return SHINE_MODIFIERS.CASCADE_BASE + cascade_wave
end

local function calc_typewriter_shine(char_index, total_chars)
    local reveal_pos = (char_index - 1) / math_max(1, total_chars - 1)
    return SHINE_MODIFIERS.TYPEWRITER_BASE + SHINE_MODIFIERS.TYPEWRITER_RANGE * reveal_pos
end

local function calc_gradient_sweep_shine(char_index, total_chars)
    local sweep_pos = (char_index - 1) / math_max(1, total_chars - 1)
    return SHINE_MODIFIERS.GRADIENT_BASE + SHINE_MODIFIERS.GRADIENT_RANGE * sweep_pos
end

local function calc_mirror_shine(char_index, total_chars)
    local center = (total_chars + 1) / 2
    local distance = math_abs(char_index - center)
    local mirror_brightness = SHINE_MODIFIERS.BASE_MAX - (distance / (total_chars / 2)) * SHINE_MODIFIERS.MIRROR_VARIATION
    return math_max(SHINE_MODIFIERS.MIRROR_BASE, mirror_brightness)
end

local function calc_plasma_shine(char_index)
    local plasma_brightness = math_sin((char_index - 1) * PHASE_MULTIPLIERS.ZIGZAG_FREQ) * SHINE_MODIFIERS.ZIGZAG_VARIATION
    return SHINE_MODIFIERS.ZIGZAG_BASE + plasma_brightness
end

-- old (kept): static strobe based on seeded RNG
--[[
local function calc_strobe_shine(char_index, text_seed)
    math_randomseed(text_seed + char_index)
    return math_random() > HALF and SHINE_MODIFIERS.STROBE_BRIGHT or SHINE_MODIFIERS.STROBE_DIM
end
]]
local function calc_strobe_shine(char_index, text_seed, time_factor)
    local t = (time_factor or 0)
    -- use integer time steps so default shine_speed toggles every tick
    -- adjust frequency by scaling the integer step if needed
    local freq = 1.0  -- toggles each tick at 1.0; set to 0.5 to toggle every 2 ticks, etc.
    local step = math_floor(t * freq)
    local phase = step + char_index
    return (phase % 2 == 0) and SHINE_MODIFIERS.STROBE_BRIGHT or SHINE_MODIFIERS.STROBE_DIM
end

local function calc_spotlight_shine(char_index, total_chars)
    local center = (total_chars + 1) / 2
    local distance = math_abs(char_index - center)
    local spotlight_brightness = math_exp(-distance * PHASE_MULTIPLIERS.SPOTLIGHT_DECAY)
    return SHINE_MODIFIERS.SPOTLIGHT_BASE + SHINE_MODIFIERS.SPOTLIGHT_RANGE * spotlight_brightness
end

-- old (kept): static flicker based on seeded RNG
--[[
local function calc_flicker_shine(char_index, text_seed)
    math_randomseed(text_seed + char_index * 3)
    local flicker_amount = (math_random() - HALF) * SHINE_MODIFIERS.FLICKER_VARIATION
    return SHINE_MODIFIERS.FLICKER_BASE + flicker_amount
end
]]
local function calc_flicker_shine(char_index, text_seed, time_factor)
    local n = _noise1((text_seed + char_index * 11) * 0.37 + (time_factor or 0) * 5.0)
    local flicker_amount = (n - HALF) * SHINE_MODIFIERS.FLICKER_VARIATION
    return SHINE_MODIFIERS.FLICKER_BASE + flicker_amount
end


-- // MARK: EXPORTS

-- expose constants (pass-through from constants module)
M.PHASE_MULTIPLIERS = PHASE_MULTIPLIERS
M.SHINE_MODIFIERS = SHINE_MODIFIERS

-- expose all helper functions
M.calc_wave_offset = calc_wave_offset
M.calc_sine_wave_offset = calc_sine_wave_offset
M.calc_center_out_offset = calc_center_out_offset
M.calc_edges_in_offset = calc_edges_in_offset
M.calc_pulse_offset = calc_pulse_offset
M.calc_fibonacci_offset = calc_fibonacci_offset
M.calc_spiral_offset = calc_spiral_offset
M.calc_rainbow_offset = calc_rainbow_offset
M.calc_random_offset = calc_random_offset
M.calc_ripple_offset = calc_ripple_offset
M.calc_flow_offset = calc_flow_offset
M.calc_breathing_offset = calc_breathing_offset
M.calc_cascade_offset = calc_cascade_offset
M.calc_typewriter_offset = calc_typewriter_offset
M.calc_gradient_sweep_offset = calc_gradient_sweep_offset
M.calc_mirror_offset = calc_mirror_offset
M.calc_plasma_offset = calc_plasma_offset
M.calc_strobe_offset = calc_strobe_offset
M.calc_spotlight_offset = calc_spotlight_offset
M.calc_flicker_offset = calc_flicker_offset

M.calc_wave_shine = calc_wave_shine
M.calc_sine_wave_shine = calc_sine_wave_shine
M.calc_center_out_shine = calc_center_out_shine
M.calc_edges_in_shine = calc_edges_in_shine
M.calc_pulse_shine = calc_pulse_shine
M.calc_fibonacci_shine = calc_fibonacci_shine
M.calc_spiral_shine = calc_spiral_shine
M.calc_rainbow_shine = calc_rainbow_shine
M.calc_drift_shine = calc_drift_shine
M.calc_random_shine = calc_random_shine
M.calc_ripple_shine = calc_ripple_shine
M.calc_flow_shine = calc_flow_shine
M.calc_breathing_shine = calc_breathing_shine
M.calc_cascade_shine = calc_cascade_shine
M.calc_typewriter_shine = calc_typewriter_shine
M.calc_gradient_sweep_shine = calc_gradient_sweep_shine
M.calc_mirror_shine = calc_mirror_shine
M.calc_plasma_shine = calc_plasma_shine
M.calc_strobe_shine = calc_strobe_shine
M.calc_spotlight_shine = calc_spotlight_shine
M.calc_flicker_shine = calc_flicker_shine

return M
