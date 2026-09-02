-- startup_profiler.lua
-- Performance profiling for awesome startup to identify blocking operations
local gears = require("gears")

local M = {}

-- profiling state
local start_time = os.clock()
local measurements = {}
local current_section = nil

-- start timing a section
function M.start(section_name)
    local timestamp = os.clock()
    current_section = {
        name = section_name,
        start_time = timestamp,
        elapsed_from_start = timestamp - start_time
    }
    print(string.format("[PROFILE] START %s (%.3fs from init)", section_name, current_section.elapsed_from_start))
end

-- end timing current section
function M.stop()
    if not current_section then return end
    
    local end_time = os.clock()
    local duration = end_time - current_section.start_time
    current_section.duration = duration
    current_section.end_elapsed = end_time - start_time
    
    table.insert(measurements, current_section)
    print(string.format("[PROFILE] END   %s (%.3fs duration, %.3fs total)", 
                       current_section.name, duration, current_section.end_elapsed))
    
    -- warn about blocking operations
    if duration > 0.05 then
        print(string.format("[PROFILE] WARNING: %s took %.3fs - potential blocking!", 
                           current_section.name, duration))
    end
    
    current_section = nil
end

-- measure a function execution
function M.measure(name, func)
    M.start(name)
    local result = func()
    M.stop()
    return result
end

-- report all measurements
function M.report()
    print("\n[PROFILE] === STARTUP PERFORMANCE REPORT ===")
    print(string.format("[PROFILE] Total startup time: %.3fs", os.clock() - start_time))
    print("[PROFILE] Section breakdown:")
    
    local total_measured = 0
    for _, measurement in ipairs(measurements) do
        print(string.format("[PROFILE]   %-30s %.3fs (at %.3fs)", 
                           measurement.name, measurement.duration, measurement.elapsed_from_start))
        total_measured = total_measured + measurement.duration
    end
    
    print(string.format("[PROFILE] Total measured: %.3fs", total_measured))
    print(string.format("[PROFILE] Unmeasured time: %.3fs", (os.clock() - start_time) - total_measured))
    
    -- identify slowest operations
    table.sort(measurements, function(a, b) return a.duration > b.duration end)
    print("[PROFILE] Slowest operations:")
    for i = 1, math.min(5, #measurements) do
        local m = measurements[i]
        print(string.format("[PROFILE]   %d. %-25s %.3fs", i, m.name, m.duration))
    end
    print("[PROFILE] ========================================\n")
end

-- schedule automatic report
gears.timer.start_new(2.0, function()
    M.report()
    return false
end)

return M
