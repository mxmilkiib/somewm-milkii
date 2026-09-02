-- shimmer progression strategy classes module
-- extracted from animation.lua for better organization

local constants = require("plugins.shimmer.constants")
local PHASE_MULTIPLIERS = constants.PHASE_MULTIPLIERS
local SHINE_MODIFIERS = constants.SHINE_MODIFIERS

local M = {}

-- simple strategy objects; each returns spatial/brightness offsets
-- prefer deterministic noise over rng to keep timing stable and cheap

-- // MARK: BASE STRATEGY INTERFACE

-- local deterministic noise to avoid global RNG reseeding
local function _fract(x) return x - math.floor(x) end
local function _noise1(x) return _fract(math.sin(x) * 43758.5453123) end
-- cheap hash-noise; no global state

-- base strategy interface
local ProgressionStrategy = {}
ProgressionStrategy.__index = ProgressionStrategy

function ProgressionStrategy:new()
    local obj = {}
    setmetatable(obj, self)
    return obj
end

function ProgressionStrategy:calculate_color_offset(char_index, total_chars, text_seed)
    error("calculate_color_offset must be implemented by subclass")
end

function ProgressionStrategy:calculate_shine_modifier(char_index, total_chars, text_seed)
    error("calculate_shine_modifier must be implemented by subclass")
end


-- // MARK: CONCRETE STRATEGY IMPLEMENTATIONS

-- // MARK -- wave progression strategy
local WaveStrategy = ProgressionStrategy:new()
WaveStrategy.__index = WaveStrategy
setmetatable(WaveStrategy, ProgressionStrategy)

function WaveStrategy:new()
    local obj = ProgressionStrategy.new(self)
    setmetatable(obj, self)
    return obj
end

function WaveStrategy:calculate_color_offset(char_index, total_chars, text_seed)
    return (char_index - 1) * PHASE_MULTIPLIERS.WAVE_STEP
end

function WaveStrategy:calculate_shine_modifier(char_index, total_chars, text_seed)
    return SHINE_MODIFIERS.BASE_MIN + SHINE_MODIFIERS.RANGE_VARIATION * math.sin((char_index - 1) / total_chars * 2 * math.pi)
end


-- // MARK -- reverse wave progression strategy
local ReverseWaveStrategy = ProgressionStrategy:new()
ReverseWaveStrategy.__index = ReverseWaveStrategy
setmetatable(ReverseWaveStrategy, ProgressionStrategy)

function ReverseWaveStrategy:new()
    local obj = ProgressionStrategy.new(self)
    setmetatable(obj, self)
    return obj
end

function ReverseWaveStrategy:calculate_color_offset(char_index, total_chars, text_seed)
    return (total_chars - char_index + 1) * PHASE_MULTIPLIERS.WAVE_STEP
end

function ReverseWaveStrategy:calculate_shine_modifier(char_index, total_chars, text_seed)
    return SHINE_MODIFIERS.BASE_MIN + SHINE_MODIFIERS.RANGE_VARIATION * math.sin(((total_chars - char_index + 1) - 1) / total_chars * 2 * math.pi)
end


-- // MARK -- sine wave progression strategy
local SineWaveStrategy = ProgressionStrategy:new()
SineWaveStrategy.__index = SineWaveStrategy
setmetatable(SineWaveStrategy, ProgressionStrategy)

function SineWaveStrategy:new()
    local obj = ProgressionStrategy.new(self)
    setmetatable(obj, self)
    return obj
end

function SineWaveStrategy:calculate_color_offset(char_index, total_chars, text_seed)
    return math.sin((char_index - 1) * 0.6) * PHASE_MULTIPLIERS.SINE_AMPLITUDE
end

function SineWaveStrategy:calculate_shine_modifier(char_index, total_chars, text_seed)
    return SHINE_MODIFIERS.BASE_MIN + SHINE_MODIFIERS.RANGE_VARIATION * math.sin((char_index - 1) * 0.6)
end


-- // MARK -- spiral progression strategy
local SpiralStrategy = ProgressionStrategy:new()
SpiralStrategy.__index = SpiralStrategy
setmetatable(SpiralStrategy, ProgressionStrategy)

function SpiralStrategy:new()
    local obj = ProgressionStrategy.new(self)
    setmetatable(obj, self)
    return obj
end

function SpiralStrategy:calculate_color_offset(char_index, total_chars, text_seed)
    local angle = (char_index - 1) * PHASE_MULTIPLIERS.SPIRAL_BASE
    return angle + math.sin(angle * 0.3) * PHASE_MULTIPLIERS.SPIRAL_SINE_SCALE
end

function SpiralStrategy:calculate_shine_modifier(char_index, total_chars, text_seed)
    local angle = (char_index - 1) * PHASE_MULTIPLIERS.SPIRAL_BASE
    return SHINE_MODIFIERS.BASE_MIN + SHINE_MODIFIERS.RANGE_VARIATION * math.abs(math.sin(angle * 0.3))
end


-- // MARK -- fibonacci progression strategy
local FibonacciStrategy = ProgressionStrategy:new()
FibonacciStrategy.__index = FibonacciStrategy
setmetatable(FibonacciStrategy, ProgressionStrategy)

function FibonacciStrategy:new()
    local obj = ProgressionStrategy.new(self)
    setmetatable(obj, self)
    return obj
end

function FibonacciStrategy:calculate_color_offset(char_index, total_chars, text_seed)
    local function fib(n)
        if n <= 1 then return n end
        local a, b = 0, 1
        for j = 2, n do a, b = b, a + b end
        return b
    end
    return fib(char_index % 12) * PHASE_MULTIPLIERS.FIBONACCI_SCALE
end

function FibonacciStrategy:calculate_shine_modifier(char_index, total_chars, text_seed)
    local function fib(n)
        if n <= 1 then return n end
        local a, b = 0, 1
        for j = 2, n do a, b = b, a + b end
        return b
    end
    local fib_val = fib(char_index % 12)
    return SHINE_MODIFIERS.FIBONACCI_BASE + (fib_val % 5) * SHINE_MODIFIERS.FIBONACCI_STEP
end


-- // MARK -- random progression strategy
local RandomStrategy = ProgressionStrategy:new()
RandomStrategy.__index = RandomStrategy
setmetatable(RandomStrategy, ProgressionStrategy)

function RandomStrategy:new()
    local obj = ProgressionStrategy.new(self)
    setmetatable(obj, self)
    return obj
end

function RandomStrategy:calculate_color_offset(char_index, total_chars, text_seed)
    -- old rng-based implementation (commented out to avoid global rng reseeding)
    -- math.randomseed(text_seed + char_index)
    -- return math.random() * PHASE_MULTIPLIERS.RANDOM_SCALE
    -- new: deterministic noise-based offset
    local n = _noise1((text_seed + char_index) * 0.53)
    return n * PHASE_MULTIPLIERS.RANDOM_SCALE
end

function RandomStrategy:calculate_shine_modifier(char_index, total_chars, text_seed)
    -- old rng-based implementation (commented out to avoid global rng reseeding)
    -- math.randomseed(text_seed + char_index)
    -- return SHINE_MODIFIERS.RANDOM_BASE + (math.random() * SHINE_MODIFIERS.RANDOM_RANGE)
    -- new: deterministic noise-based brightness
    local n = _noise1((text_seed + char_index * 7) * 0.41)
    return SHINE_MODIFIERS.RANDOM_BASE + (n * SHINE_MODIFIERS.RANDOM_RANGE)
end


-- // MARK: STRATEGY REGISTRY

-- strategy registry for runtime lookup
local progression_strategies = {
    wave = WaveStrategy:new(),
    reverse_wave = ReverseWaveStrategy:new(),
    sine_wave = SineWaveStrategy:new(),
    spiral = SpiralStrategy:new(),
    fibonacci = FibonacciStrategy:new(),
    scatter = RandomStrategy:new(),
    chaos = RandomStrategy:new(),
    random = RandomStrategy:new()  -- alias: random family uses noise-backed randomness
}

-- expose strategy registry and classes
M.progression_strategies = progression_strategies
M.ProgressionStrategy = ProgressionStrategy
M.WaveStrategy = WaveStrategy
M.ReverseWaveStrategy = ReverseWaveStrategy
M.SineWaveStrategy = SineWaveStrategy
M.SpiralStrategy = SpiralStrategy
M.FibonacciStrategy = FibonacciStrategy
M.RandomStrategy = RandomStrategy

-- // MARK: REGISTRY ACCESS

-- get the strategy registry for external use
function M.get_registry()
    return progression_strategies
end

return M
