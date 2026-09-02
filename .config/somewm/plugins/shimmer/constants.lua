-- shimmer animation constants module
-- tuning knobs: small deltas change visuals/cpu noticeably; adjust cautiously
-- extracted from animation.lua for better organization

local M = {}

-- // MARK: PROGRESSION CONSTANTS

-- phase offset multipliers for different progression patterns
M.PHASE_MULTIPLIERS = {
    WAVE_STEP = 0.4,           -- standard wave progression step
    SINE_AMPLITUDE = 4.0,      -- sine wave amplitude
    CENTER_OUT_STEP = 0.8,     -- center-out progression step
    EDGES_IN_STEP = 0.6,       -- edges-in progression step
    PULSE_AMPLITUDE = 3.0,     -- pulse effect amplitude
    ALTERNATING_OFFSET = 6.0,  -- alternating pattern offset
    FIBONACCI_SCALE = 0.2,     -- fibonacci sequence scaling
    SPIRAL_BASE = 0.8,         -- spiral base angle increment
    SPIRAL_SINE_SCALE = 2.0,   -- spiral sine wave scaling
    RAINBOW_SCALE = 20.0,      -- rainbow progression scaling
    DRIFT_SCALE = 0.8,         -- drift randomness scaling
    SCATTER_SCALE = 2.5,       -- scatter randomness scaling
    CHAOS_SCALE = 10.0,        -- chaos randomness scaling
    RANDOM_SCALE = 15.0,       -- random progression scaling
    RIPPLE_FREQ = 0.8,         -- ripple frequency
    RIPPLE_DECAY = 0.3,        -- ripple decay rate
    RIPPLE_AMPLITUDE = 3.0,    -- ripple amplitude
    FLOW_SCALE = 4.0,          -- flow base scaling
    FLOW_TURBULENCE = 0.6,     -- flow turbulence scaling
    BREATHING_PRIMARY = 0.3,   -- breathing primary frequency
    BREATHING_SECONDARY = 0.1, -- breathing secondary frequency
    BREATHING_AMPLITUDE = 2.0, -- breathing primary amplitude
    BREATHING_SECONDARY_AMP = 0.5, -- breathing secondary amplitude
    CASCADE_STEP = 0.8,        -- cascade delay step
    CASCADE_SINE_FREQ = 0.4,   -- cascade sine frequency
    CASCADE_SINE_AMP = 1.5,    -- cascade sine amplitude
    TYPEWRITER_SCALE = 8.0,    -- typewriter reveal scaling
    TYPEWRITER_SINE_FREQ = 6.0, -- typewriter sine frequency
    TYPEWRITER_SINE_AMP = 2.0, -- typewriter sine amplitude
    GRADIENT_SWEEP_SCALE = 12.0, -- gradient sweep scaling
    MIRROR_STEP = 0.6,         -- mirror progression step
    MIRROR_SINE_FREQ = 0.8,    -- mirror sine frequency
    MIRROR_SINE_AMP = 1.2,     -- mirror sine amplitude
    ZIGZAG_FREQ = 0.7,         -- zigzag frequency
    ZIGZAG_AMP = 3.0,          -- zigzag amplitude
    ZIGZAG_BASE_STEP = 0.2,    -- zigzag base step
    SPOTLIGHT_DECAY = 0.4,     -- spotlight decay rate
    SPOTLIGHT_SCALE = 6.0,     -- spotlight intensity scaling
    FLICKER_BASE_AMP = 2.0,    -- flicker base amplitude
    FLICKER_RANDOM_AMP = 1.5   -- flicker random amplitude
}

-- shine progression modifier ranges and steps
M.SHINE_MODIFIERS = {
    BASE_MIN = 0.7,            -- base minimum shine
    BASE_MAX = 1.0,            -- base maximum shine
    RANGE_VARIATION = 0.3,     -- range for wave-like variations (0.7 to 1.0)
    MIRROR_BASE = 0.6,         -- mirror/center effects base
    MIRROR_VARIATION = 0.4,    -- mirror variation range
    ALTERNATING_DIM = 0.8,     -- alternating pattern dim value
    FIBONACCI_BASE = 0.75,     -- fibonacci base brightness
    FIBONACCI_STEP = 0.05,     -- fibonacci step increment
    DRIFT_BASE = 0.8,          -- drift base brightness
    DRIFT_VARIATION = 0.15,    -- drift random variation
    RANDOM_BASE = 0.6,         -- random base brightness
    RANDOM_RANGE = 0.4,        -- random brightness range
    RIPPLE_BASE = 0.5,         -- ripple base brightness
    RIPPLE_RANGE = 0.5,        -- ripple brightness range
    FLOW_BASE = 0.7,           -- flow base brightness
    BREATHING_BASE = 0.85,     -- breathing base brightness
    BREATHING_VARIATION = 0.15, -- breathing variation range
    CASCADE_BASE = 0.8,        -- cascade base brightness
    CASCADE_VARIATION = 0.2,   -- cascade variation range
    TYPEWRITER_BASE = 0.3,     -- typewriter base brightness
    TYPEWRITER_RANGE = 0.7,    -- typewriter brightness range
    GRADIENT_BASE = 0.4,       -- gradient sweep base
    GRADIENT_RANGE = 0.6,      -- gradient sweep range
    ZIGZAG_BASE = 0.8,         -- zigzag base brightness
    ZIGZAG_VARIATION = 0.2,    -- zigzag variation range
    STROBE_BRIGHT = 1.0,       -- strobe bright value
    STROBE_DIM = 0.3,          -- strobe dim value
    SPOTLIGHT_BASE = 0.3,      -- spotlight base brightness
    SPOTLIGHT_RANGE = 0.7,     -- spotlight brightness range
    FLICKER_BASE = 0.85,       -- flicker base brightness
    FLICKER_VARIATION = 0.3,   -- flicker variation range
    CLAMP_MIN = 0.3,           -- minimum clamp value
    CLAMP_MAX = 1.0            -- maximum clamp value
}

return M
