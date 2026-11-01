-- plugins/resource_popup.lua
-- Clickable popup anchored to the wibar CPU/GPU/RAM widgets. Shows a short
-- scrolling history graph per metric plus current readings: CPU usage/load/
-- temp with a per-core usage tapestry, GPU busy/temp/clock/power plus a
-- per-engine busy tapestry from fdinfo, RAM/swap usage, and temperatures.
-- A fan
-- section (tach input or PWM duty) is kept below but commented out: this
-- hardware exposes no fan speed source.
--
-- By default the popup ignores clicks elsewhere: it stays open until one of
-- the resource widgets is clicked again (clicking a different resource widget
-- re-anchors it), or on Escape/right-click. The pin toggle in the header
-- switches this to closing on any outside click, like the other popups; the
-- choice persists across reloads.
--
-- One shared popup is created lazily and re-anchored to whichever resource
-- widget is clicked (the wibar is built per-screen).

local awful   = require("awful")
local gears   = require("gears")
local wibox   = require("wibox")
local base    = require("wibox.widget.base")
local wclay   = require("wibox.clay")
local cairo   = require("lgi").cairo
local beautiful = require("beautiful")
local guarded = require("error_guard")
local popup_common = require("plugins.popup_common")
local style   = require("plugins.style")

local dpi = style.dpi

local COLOR_PURPLE = popup_common.theme.PURPLE
local COLOR_BLACK  = popup_common.theme.BLACK
local COLOR_WHITE  = popup_common.theme.WHITE
local COLOR_GOLD   = popup_common.theme.GOLD
local COLOR_GREY   = popup_common.theme.GREY
local FONT       = popup_common.fonts.FONT
local FONT_INFO  = popup_common.fonts.FONT_INFO
local FONT_VALUE = popup_common.fonts.FONT_VALUE
local FONT_HEAD  = popup_common.fonts.FONT_HEAD
-- alternate width: dpi(260)
-- module configuration; override via M.configure{...} before first use
local CFG = {
    content_w = dpi(300),
    content_h = dpi(700),  -- min-height floor; taller graphs fill most of it
    graph_h = dpi(44),
    graph_cap = 120,   -- samples kept per graph (4 min at the 2s interval)
    -- temp ramp: celsius thresholds and their colours
    temp_hot  = 90,   temp_hot_c  = "#FF6B6B",
    temp_warm = 75,   temp_warm_c = "#E8934A",
    temp_mild = 55,   -- at/above this, temp_colour yields COLOR_GOLD
    temp_ok_c = "#9FD64A",
}



local M = {}

function M.configure(opts) style.merge(CFG, opts) end

local popup
-- holder table: draggable_header reads popup from here so build_content can
-- run before the awful.popup is constructed (awful.popup requires a widget arg)
local popup_holder = {}
local sample_timer
local views          -- { cpu = {value,info,graph}, gpu = ..., ram = ..., temp = ... }
local core_count = 0
local cores_hist = {}  -- [core] = scrolling sample buffer for the per-core graph
local cores_graph      -- the custom-drawn per-core widget, for redraw emits
local eng_hist = {}    -- [engine] = scrolling buffer for the per-engine graph
local eng_names = {}   -- engine names in display order (gfx, compute, …)
local eng_usage = {}   -- [engine] = latest 0-100 busy figure
local eng_prev = {}    -- [engine] = summed busy-ns at the previous read
local eng_prev_uptime
local eng_graph        -- the per-engine tapestry widget, for redraw emits
local gpu_pdev         -- PCI slot of the card serving gpu_busy_percent
-- forward declarations: the draggable_header controller (built in
-- build_content once the popup exists) drives detach/drag/placement, and
-- `hide` is referenced by it before assignment
local hide
local ctrl


-- MARK: SYS READERS

local function read_file(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local s = f:read("*l")
    f:close()
    return s
end

local function read_num(path)
    return tonumber(read_file(path))
end

local prev_cpu_total, prev_cpu_idle
local prev_cores = {}    -- [core] = {total, idle} from the previous read
local core_usage = {}    -- [core] = latest 0-100 busy figure
local function read_cpu()
    local f = io.open("/proc/stat", "r")
    if not f then return nil end
    local total, idle, n = 0, 0, 0
    for line in f:lines() do
        if line:match("^cpu%d") then
            n = n + 1
            local values = {}
            -- "%s+%d+" skips the digit in the cpuN label itself
            for v in line:gmatch("%s+(%d+)") do values[#values + 1] = tonumber(v) end
            local ctotal = 0
            for _, v in ipairs(values) do ctotal = ctotal + v end
            local cidle = (values[4] or 0) + (values[5] or 0)
            local prev = prev_cores[n]
            core_usage[n] = prev and ctotal > prev.total
                and 100 * (1 - (cidle - prev.idle) / (ctotal - prev.total)) or nil
            prev_cores[n] = { total = ctotal, idle = cidle }
        elseif line:match("^cpu%s") then
            local values = {}
            for v in line:gmatch("%d+") do values[#values + 1] = tonumber(v) end
            for _, v in ipairs(values) do total = total + v end
            idle = (values[4] or 0) + (values[5] or 0)
        else
            break
        end
    end
    f:close()
    core_count = n
    local usage
    if prev_cpu_total and total > prev_cpu_total then
        usage = 100 * (1 - (idle - prev_cpu_idle) / (total - prev_cpu_total))
    end
    prev_cpu_total, prev_cpu_idle = total, idle
    return usage
end

local function read_ram()
    local f = io.open("/proc/meminfo", "r")
    if not f then return nil end
    local total, avail, swapt, swapf
    for line in f:lines() do
        total = total or tonumber(line:match("^MemTotal:%s+(%d+)"))
        avail = avail or tonumber(line:match("^MemAvailable:%s+(%d+)"))
        swapt = swapt or tonumber(line:match("^SwapTotal:%s+(%d+)"))
        swapf = swapf or tonumber(line:match("^SwapFree:%s+(%d+)"))
        if total and avail and swapt and swapf then break end
    end
    f:close()
    if not total or not avail then return nil end
    return 100 * (total - avail) / total,
        (total - avail) / 1048576, total / 1048576,
        ((swapt or 0) - (swapf or 0)) / 1048576, (swapt or 0) / 1048576
end

local function read_gpu()
    for card = 0, 7 do
        local v = read_num("/sys/class/drm/card" .. card .. "/device/gpu_busy_percent")
        if v then return v end
    end
end

local function read_loadavg()
    local line = read_file("/proc/loadavg")
    return line and line:match("^([%d%.]+ [%d%.]+ [%d%.]+)") or ""
end

-- engine names sorted for display: graphics first, then compute (the AI
-- workhorse), dma and the media blocks
local ENG_ORDER = { gfx = 1, compute = 2, sdma = 3, vcn = 4, jpeg = 5, enc = 6 }

-- per-engine busy from drm fdinfo. the kernel doesn't expose per-CU
-- occupancy, but every open drm fd keeps cumulative busy-ns counters per
-- hardware engine (gfx ring, compute rings, sdma, vcn/jpeg video blocks).
-- summing them across all clients of the card and dividing by elapsed wall
-- time is the closest thing to per-core GPU load that exists
local function read_gpu_engines()
    -- fd symlinks are the cheap filter: only processes holding a drm handle
    -- carry engine counters, so /proc/*/fdinfo mostly stays unopened. find
    -- does one pass of readlinks and hands us just the fds on /dev/dri nodes
    local p = io.popen("find /proc/[0-9]*/fd -lname '/dev/dri/*' 2>/dev/null")
    if not p then return end
    local totals = {}
    for path in p:lines() do
        local f = io.open(path:gsub("/fd/", "/fdinfo/"), "r")
        if f then
            local pdev_ok
            for line in f:lines() do
                local pdev = line:match("^drm%-pdev:%s+(%S+)")
                if pdev then pdev_ok = not gpu_pdev or pdev == gpu_pdev end
                local name, ns = line:match("^drm%-engine%-([%w_]+):%s+(%d+)")
                if name and ns and pdev_ok ~= false then
                    totals[name] = (totals[name] or 0) + tonumber(ns)
                end
            end
            f:close()
        end
    end
    p:close()

    -- busy% = engine-ns delta over the wall-clock delta (uptime has
    -- centisecond resolution); an engine can't be busier than elapsed
    local up = read_file("/proc/uptime")
    up = up and tonumber(up:match("^([%d%.]+)"))
    local elapsed = up and eng_prev_uptime and (up - eng_prev_uptime) * 1e9
    eng_prev_uptime = up
    local n_names = 0
    for name, ns in pairs(totals) do
        n_names = n_names + 1
        eng_names[n_names] = name
        local prev = eng_prev[name]
        eng_usage[name] = prev and elapsed and elapsed > 0 and ns >= prev
            and math.min(100, (ns - prev) / elapsed * 100) or nil
        eng_prev[name] = ns
    end
    for i = n_names + 1, #eng_names do eng_names[i] = nil end
    -- forget engines that went away so a reappearing one starts fresh
    -- instead of jumping to a clamped 100%
    for name in pairs(eng_prev) do
        if not totals[name] then
            eng_prev[name], eng_usage[name], eng_hist[name] = nil, nil, nil
        end
    end
    table.sort(eng_names, function(a, b)
        local oa = ENG_ORDER[a:match("^(%a+)")] or 9
        local ob = ENG_ORDER[b:match("^(%a+)")] or 9
        if oa ~= ob then return oa < ob end
        return a < b
    end)
end


-- MARK -- hwmon discovery

local CPU_CHIPS = { k10temp = true, coretemp = true, zenpower = true, cpu_thermal = true }
local GPU_CHIPS = { amdgpu = true, nvidia = true, i915 = true, radeon = true }
local CPU_TEMP_LABELS = { Tctl = true, Tdie = true, ["Package id 0"] = true, CPU = true }
local GPU_TEMP_LABELS = { edge = true, junction = true, mem = true }

local cpu_temp_path, gpu_temp_path, gpu_freq_path, gpu_power_path
local nvme_temp_paths = {}
local fan_paths = {}
local pwm_path
local temp_sensors = {}

-- acpitz temp inputs are unlabeled, but the matching thermal zones carry the
-- firmware's zone names (\_TZ_.CPUZ etc), which are far more meaningful
local acpi_zones = {}
for i = 0, 15 do
    local z = "/sys/class/thermal/thermal_zone" .. i
    if read_file(z .. "/type") == "acpitz" then
        acpi_zones[#acpi_zones + 1] =
            (read_file(z .. "/device/path") or ""):match("([%w_]+)$")
    end
end

-- first labeled temp matching `preferred`, else temp1_input.
-- returns the input path and its label ("tempN" when unlabeled)
local function pick_temp(dir, preferred)
    local fallback, fallback_label
    for n = 1, 8 do
        local inp = dir .. "/temp" .. n .. "_input"
        if read_num(inp) then
            local label = read_file(dir .. "/temp" .. n .. "_label") or ("temp" .. n)
            if not fallback then fallback, fallback_label = inp, label end
            if preferred[label] then return inp, label end
        end
    end
    return fallback, fallback_label
end

local function probe_hwmon()
    for i = 0, 15 do
        local dir = "/sys/class/hwmon/hwmon" .. i
        local name = read_file(dir .. "/name")
        if name then
            -- every temp input, for the NVMe section's sensor list
            for n = 1, 8 do
                local inp = dir .. "/temp" .. n .. "_input"
                if read_num(inp) then
                    -- acpitz gets the bare zone name (CPUZ etc); other chips
                    -- are prefixed so labels like "edge"/"Composite" make sense
                    local label = (name == "acpitz" and acpi_zones[n])
                        or (name:gsub("_phy0", "") .. " "
                            .. (read_file(dir .. "/temp" .. n .. "_label")
                                or ("temp" .. n)))
                    temp_sensors[#temp_sensors + 1] = { name = label, path = inp }
                end
            end
            for n = 1, 4 do
                local p = dir .. "/fan" .. n .. "_input"
                if read_num(p) then fan_paths[#fan_paths + 1] = p end
            end
            if not pwm_path and read_num(dir .. "/pwm1") then
                pwm_path = dir .. "/pwm1"
            end
            if CPU_CHIPS[name] and not cpu_temp_path then
                cpu_temp_path = pick_temp(dir, CPU_TEMP_LABELS)
            end
            if name == "nvme" then
                -- graph the hottest point on the drive: numbered sensors move
                -- visibly with activity while Composite sits flat, and a max
                -- stays meaningful on drives whose sensor labels differ
                for n = 1, 8 do
                    local inp = dir .. "/temp" .. n .. "_input"
                    if read_num(inp) then
                        nvme_temp_paths[#nvme_temp_paths + 1] = inp
                    end
                end
            end
            if GPU_CHIPS[name] then
                if not gpu_temp_path then
                    gpu_temp_path = pick_temp(dir, GPU_TEMP_LABELS)
                end
                for n = 1, 4 do
                    local inp = dir .. "/freq" .. n .. "_input"
                    if read_num(inp)
                        and read_file(dir .. "/freq" .. n .. "_label") == "sclk" then
                        gpu_freq_path = gpu_freq_path or inp
                    end
                end
                if not gpu_power_path then
                    if read_num(dir .. "/power1_average") then
                        gpu_power_path = dir .. "/power1_average"
                    elseif read_num(dir .. "/power1_input") then
                        gpu_power_path = dir .. "/power1_input"
                    end
                end
            end
        end
    end

    -- pdev of the card serving gpu_busy_percent: fdinfo engine counters are
    -- matched against it so a second GPU's traffic stays out of the totals
    for card = 0, 7 do
        local dev = "/sys/class/drm/card" .. card .. "/device"
        if read_num(dev .. "/gpu_busy_percent") then
            local f = io.open(dev .. "/uevent", "r")
            if f then
                for line in f:lines() do
                    gpu_pdev = gpu_pdev or line:match("^PCI_SLOT_NAME=(%S+)")
                end
                f:close()
            end
            break
        end
    end
end

-- value + mode: "rpm" from a tach input, "duty" as pwm percentage, or nil
-- when the hardware exposes no fan control surface at all
local function read_fan()
    for _, p in ipairs(fan_paths) do
        local v = read_num(p)
        if v and v > 0 then return v, "rpm" end
    end
    if #fan_paths > 0 then return 0, "rpm" end
    if pwm_path then
        local duty = read_num(pwm_path)
        if duty then return duty / 2.55, "duty" end
    end
end


-- MARK: SAMPLER

-- stepped ramp for the temp figures: green when cool, gold under normal
-- load, orange when warm, red when hot
local function temp_colour(celsius)
    if celsius >= CFG.temp_hot then return CFG.temp_hot_c end
    if celsius >= CFG.temp_warm then return CFG.temp_warm_c end
    if celsius >= CFG.temp_mild then return COLOR_GOLD end
    return CFG.temp_ok_c
end

-- the same ramp as a graph gradient: the fill's top edge takes the heat
-- colour, cooling to purple towards the baseline
local function temp_gradient(celsius)
    return "linear:0,0:0," .. CFG.graph_h .. ":0," .. temp_colour(celsius)
        .. ":0.5," .. COLOR_PURPLE .. ":1," .. COLOR_PURPLE
end

-- current CPU clock from cpufreq, for the CPU info line
local function read_cpu_freq()
    local khz = read_num("/sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq")
    return khz and khz / 1e6  -- GHz
end

local function sample()
    local cpu = read_cpu()
    local ram, used, total, sused, stotal = read_ram()
    local gpu = read_gpu()
    local fan, fan_mode = read_fan()
    local cpu_t = cpu_temp_path and read_num(cpu_temp_path)
    local gpu_t = gpu_temp_path and read_num(gpu_temp_path)
    -- hottest of the nvme temp inputs; bogus readings (some drives report 0
    -- or saturated values on sensors that are not really present) are dropped
    local nvme_t
    for _, p in ipairs(nvme_temp_paths) do
        local v = read_num(p)
        if v and v > 0 and v < 115000 and (not nvme_t or v > nvme_t) then
            nvme_t = v
        end
    end
    if not views then return end

    if cpu then views.cpu.graph:add_value(cpu) end
    -- one strip per core in the tapestry; buffers cap like the wibox graphs
    for i = 1, core_count do
        local h = cores_hist[i]
        if not h then h = {} cores_hist[i] = h end
        h[#h + 1] = core_usage[i] or 0
        if #h > CFG.graph_cap then table.remove(h, 1) end
    end
    for i = core_count + 1, #cores_hist do cores_hist[i] = nil end
    if cores_graph then cores_graph:emit_signal("widget::redraw_needed") end
    if gpu then views.gpu.graph:add_value(gpu) end
    -- per-engine strips: busy-ns deltas from fdinfo over wall time
    read_gpu_engines()
    for _, name in ipairs(eng_names) do
        local h = eng_hist[name]
        if not h then h = {} eng_hist[name] = h end
        h[#h + 1] = eng_usage[name] or 0
        if #h > CFG.graph_cap then table.remove(h, 1) end
    end
    if eng_graph then eng_graph:emit_signal("widget::redraw_needed") end
    if ram then views.ram.graph:add_value(ram) end
    -- second graphs: CPU package temp under CPU busy, GPU edge temp under
    -- GPU busy; the NVMe section's own graph is the drive's hottest sensor
    if cpu_t and views.cpu.graph2 then
        views.cpu.graph2:add_value(cpu_t / 1000)
        views.cpu.graph2.color = temp_gradient(cpu_t / 1000)
    end
    if gpu_t and views.gpu.graph2 then
        views.gpu.graph2:add_value(gpu_t / 1000)
        views.gpu.graph2.color = temp_gradient(gpu_t / 1000)
    end
    if nvme_t and views.temp.graph then
        views.temp.graph:add_value(nvme_t / 1000)
        views.temp.graph.color = temp_gradient(nvme_t / 1000)
    end
    if fan and views.fan and views.fan.graph then views.fan.graph:add_value(fan) end

    views.cpu.value.markup = cpu
        and string.format("%d%%%s", math.floor(cpu + 0.5),
            cpu_t and string.format('  ·  <span foreground="%s">%.0f°C</span>',
                temp_colour(cpu_t / 1000), cpu_t / 1000) or "")
        or "--"
    local ghz = read_cpu_freq()
    views.cpu.info.text = string.format("%s%s · %d cores",
        ghz and string.format("%.2f GHz · ", ghz) or "",
        read_loadavg(), core_count)

    views.gpu.value.markup = gpu
        and string.format("%d%%%s", math.floor(gpu + 0.5),
            gpu_t and string.format('  ·  <span foreground="%s">%.0f°C</span>',
                temp_colour(gpu_t / 1000), gpu_t / 1000) or "")
        or "--"
    local gpu_bits = {}
    if gpu_freq_path then
        -- amdgpu freq*_input reports Hz
        local hz = read_num(gpu_freq_path)
        if hz then gpu_bits[#gpu_bits + 1] = string.format("sclk %.0f MHz", hz / 1e6) end
    end
    if gpu_power_path then
        local uw = read_num(gpu_power_path)
        if uw then gpu_bits[#gpu_bits + 1] = string.format("%.1f W", uw / 1e6) end
    end
    views.gpu.info.text = #gpu_bits > 0 and table.concat(gpu_bits, "  ·  ") or " "

    views.ram.value.text = ram and string.format("%d%%", math.floor(ram + 0.5)) or "--"
    views.ram.info.text = (used and total)
        and string.format("%.1f/%.1f GiB  ·  swap %.1f/%.1f GiB",
            used, total, sused or 0, stotal or 0)
        or " "

    views.temp.value.markup = nvme_t and string.format(
        '<span foreground="%s">%.0f°C</span>', temp_colour(nvme_t / 1000), nvme_t / 1000)
        or "--"
    -- sensor count lives in the list heading built in build_content;
    -- views.temp.info is not part of this section's layout
    -- each sensor's figure textbox was built in build_content (views.temp.cells);
    -- updating text keeps the right-aligned column layout intact
    for i, s in ipairs(temp_sensors) do
        local v = read_num(s.path)
        views.temp.cells[i].markup = v and string.format(
            '<span foreground="%s">%.0f°C</span>', temp_colour(v / 1000), v / 1000)
            or "n/a"
    end

    if views.fan then
        if fan_mode == "rpm" then
            views.fan.value.text = string.format("%d RPM", fan)
            views.fan.info.text = #fan_paths .. " tach input" .. (#fan_paths > 1 and "s" or "")
        elseif fan_mode == "duty" then
            views.fan.value.text = string.format("%d%% duty", math.floor(fan + 0.5))
            views.fan.info.text = "pwm duty (no tach exposed)"
        else
            views.fan.value.text = "n/a"
            views.fan.info.text = "no fan sensor exposed"
        end
    end
end


-- MARK: WIDGETS

local make_text = popup_common.make_text

local function separator()
    return popup_common.separator(CFG.content_w)
end

-- transparent overlay stacked over a graph: a faint grey hairline per minute
-- of history (30 samples at the 2 s interval), counted back from the right
-- edge where the newest sample sits after the mirror
local MINUTE_PX = (dpi(2) + dpi(1)) * 30  -- step_width + step_spacing, per min
local function minute_markers()
    local w = base.make_widget()
    wclay.describe_widget(w, function(_, _, _, _, offer)
        local width = offer.w or (CFG.content_w - 2 * style.popup.margin_x)
        local specs = {}
        for i = 1, math.ceil(width / MINUTE_PX) - 1 do
            specs[i] = { float = true, parent = 6, own = 6,
                x = 1 - i * MINUTE_PX, w = 1, h = { percent = 1 },
                bg = { 0.75, 0.75, 0.75, 0.22 } }
        end
        return { w = { percent = 1 }, h = { percent = 1 }, specs = specs }
    end, "resource_popup.minute_markers")
    return w
end

-- a mirrored history graph with the minute-marker overlay.
-- wibox.widget.graph draws the newest sample at the left edge; the mirror
-- flips it so history scrolls right-to-left, and the markers overlay sits
-- outside the mirror so it measures from the right edge directly
local function make_graph()
    local graph = wibox.widget {
        min_value = 0,
        max_value = 100,
        capacity = CFG.graph_cap,
        step_width = dpi(2),
        step_spacing = style.spacing.hair,
        forced_width = CFG.content_w - 2 * style.popup.margin_x,
        color = "linear:0,0:0," .. CFG.graph_h .. ":0," .. COLOR_GOLD
            .. ":0.5," .. COLOR_PURPLE .. ":1," .. COLOR_PURPLE,
        background_color = "#00000000",
        widget = wibox.widget.graph,
    }
    -- min-height constraint so the graph is at least CFG.graph_h but can grow to
    -- fill extra space when the popup's min-height floor leaves room. the
    -- flex's max_widget_size caps that growth — wibox.widget.graph:fit is
    -- greedy (returns the full offered height), so without a cap each graph
    -- claims the whole fit allowance and the popup balloons to fit height
    local graph_flex = wibox.widget {
        graph,
        max_widget_size = CFG.graph_h * 1.5,
        layout = wibox.layout.flex.vertical,
    }
    local constrained = wibox.widget {
        graph_flex,
        strategy = "min",
        height = CFG.graph_h,
        widget = wibox.container.constraint,
    }
    return wibox.widget {
        {
            constrained,
            reflection = { horizontal = true },
            layout = wibox.container.mirror,
        },
        minute_markers(),
        layout = wibox.layout.stack,
    }, graph
end

-- continuous ramp for the tapestry cells: idle cores sit near-black against
-- the popup bg, and load raises brightness along the hue path dim green →
-- lime → gold → orange → red at full tilt
local LOAD_STOPS = {
    {   0, "#242424" },      -- idle: near-black, just off the popup bg
    {  30, "#4E7A2E" },      -- dim green
    {  55, CFG.temp_ok_c },  -- lime
    {  75, COLOR_GOLD },
    {  90, CFG.temp_warm_c },
    { 100, CFG.temp_hot_c },
}

local function lerp_hex(a, b, t)
    local ar, ag, ab = a:match("#(..)(..)(..)")
    local br, bg, bb = b:match("#(..)(..)(..)")
    ar, ag, ab = tonumber(ar, 16), tonumber(ag, 16), tonumber(ab, 16)
    br, bg, bb = tonumber(br, 16), tonumber(bg, 16), tonumber(bb, 16)
    return string.format("#%02X%02X%02X",
        math.floor(ar + (br - ar) * t + 0.5),
        math.floor(ag + (bg - ag) * t + 0.5),
        math.floor(ab + (bb - ab) * t + 0.5))
end

-- piecewise lerp across the stops; v is clamped to 0-100
local function load_colour(v)
    v = math.max(0, math.min(v, 100))
    for i = 2, #LOAD_STOPS do
        if v <= LOAD_STOPS[i][1] then
            local lo, hi = LOAD_STOPS[i - 1], LOAD_STOPS[i]
            return lerp_hex(lo[2], hi[2], (v - lo[1]) / (hi[1] - lo[1]))
        end
    end
    return LOAD_STOPS[#LOAD_STOPS][2]
end

-- tapestry history graph: one horizontal strip per row, each 2px column in
-- it a cell tinted by that row's load at that sample. drawn directly
-- (wibox.widget.graph has no multi-series mode) with the same step pitch and
-- newest-at-the-right-edge direction as the mirrored graphs, so the minute
-- markers still line up. rows_fn() returns { {hist=…, label=name|nil}, … }
-- per draw so the strip set can change without a rebuild; labeled rows get
-- a name column carved out of the left edge
local CORE_STEP = dpi(2) + style.spacing.hair  -- step_width + step_spacing
local CORE_CELL = dpi(2)                       -- matches wibox graph step_width
local core_patterns = {}

-- old: overlaid polylines, one per core — unreadable at 32 cores
local function cell_pattern(v)
    -- quantized to whole percents so the pattern cache stays small
    local q = math.floor(math.max(0, math.min(v, 100)) + 0.5)
    local p = core_patterns[q]
    if not p then
        p = gears.color(load_colour(q))
        core_patterns[q] = p
    end
    return p
end

local function make_tapestry(rows_fn, n_hint)
    -- dpi(2) a row, floored at graph_h, capped so the section can't swallow
    -- the whole popup height; n_hint is the expected row count at build
    local rows_h = math.min(math.max((n_hint or 0) * dpi(2), CFG.graph_h),
        CFG.graph_h * 2)
    local w = base.make_widget()
    -- the cell grid is pixel art, not a widget tree: the describer rasterises
    -- it into one image surface per compile. a fresh surface each time, since
    -- the renderer only re-rasters when the pointer changes
    wclay.describe_widget(w, function(w, _, _, _, offer)
        local width = math.floor(math.min(offer.w or 1e9,
            CFG.content_w - 2 * style.popup.margin_x))
        local height = math.floor(math.min(offer.h or 1e9, rows_h))
        if width < 1 or height < 1 then return nil end
        local surf = cairo.ImageSurface(cairo.Format.ARGB32, width, height)
        local cr = cairo.Context(surf)
        local rows = rows_fn()
        local n_rows = #rows
        if n_rows == 0 then
            return { image = surf._native, w = width, h = height,
                image_width = width, image_height = height }
        end
        local label_w = 0
        if rows[1].label then
            cr:set_font_size(dpi(9))
            for _, row in ipairs(rows) do
                label_w = math.max(label_w, cr:text_extents(row.label).width)
            end
            label_w = math.ceil(label_w) + dpi(5)
        end
        local row_h = height / n_rows
        for i, row in ipairs(rows) do
            local h = row.hist
            local n = #h
            local y = (i - 1) * row_h
            for j = 1, n do
                local xr = width - (n - j) * CORE_STEP
                if xr - CORE_CELL >= label_w then
                    cr:set_source(cell_pattern(h[j]))
                    cr:rectangle(xr - CORE_CELL, y, CORE_CELL, row_h)
                    cr:fill()
                end
            end
            -- name tinted by the row's latest load, centred in its strip
            if row.label then
                local fs = math.min(dpi(9), row_h - dpi(2))
                if fs >= 4 then
                    cr:set_font_size(fs)
                    cr:set_source(cell_pattern(h[n] or 0))
                    cr:move_to(dpi(2), y + (row_h + fs * 0.7) / 2)
                    cr:show_text(row.label)
                end
            end
        end
        surf:flush()
        return { image = surf._native, w = width, h = height,
            image_width = width, image_height = height }
    end, "resource_popup.tapestry")
    -- same flex+constraint stack as make_graph, sized for the strip count
    local graph_flex = wibox.widget {
        w,
        max_widget_size = rows_h * 1.5,
        layout = wibox.layout.flex.vertical,
    }
    local constrained = wibox.widget {
        graph_flex,
        strategy = "min",
        height = rows_h,
        widget = wibox.container.constraint,
    }
    return wibox.widget {
        constrained,
        minute_markers(),
        layout = wibox.layout.stack,
    }, w
end

local function cpu_rows()
    local rows = {}
    for i = 1, math.min(#cores_hist, core_count) do
        rows[i] = { hist = cores_hist[i] }
    end
    return rows
end

local function eng_rows()
    local rows = {}
    for i, name in ipairs(eng_names) do
        rows[i] = { hist = eng_hist[name] or {}, label = name }
    end
    return rows
end

-- one metric section: "Title .... value" header, history graph(s), info line.
-- n_graphs=0 leaves graphs out entirely (used for fan when the hardware
-- exposes neither a tach input nor a pwm duty); n_graphs=2 stacks a captioned
-- second graph (GPU busy + temp, NVMe + CPU temp — all read as 0-100).
-- graph2_first places the captioned graph above the primary one; label gives
-- the primary graph a caption of its own (used when both are temperatures)
local function make_section(title, n_graphs, graph2_label, graph2_first, label)
    local value_text = make_text("--", COLOR_GOLD, FONT_VALUE)
    value_text.align = "right"
    local info_text = make_text(" ", COLOR_GREY, FONT_INFO)

    local rows = wibox.widget {
        {
            make_text(title, COLOR_WHITE, FONT_HEAD),
            nil,
            value_text,
            layout = wibox.layout.align.horizontal,
        },
        layout = wibox.layout.fixed.vertical,
        spacing = style.spacing.s,
    }

    local graph, graph2
    local function add_graph2()
        local w
        if graph2_label then rows:add(make_text(graph2_label, COLOR_GREY, FONT_INFO)) end
        w, graph2 = make_graph()
        rows:add(w)
    end
    if n_graphs >= 2 and graph2_first then add_graph2() end
    if n_graphs >= 1 then
        local w
        if label then rows:add(make_text(label, COLOR_GREY, FONT_INFO)) end
        w, graph = make_graph()
        rows:add(w)
    end
    if n_graphs >= 2 and not graph2_first then add_graph2() end
    rows:add(info_text)

    local body = wibox.widget {
        {
            rows,
            left = style.spacing.xl, right = style.spacing.xl,
            top = style.spacing.m, bottom = style.spacing.m,
            widget = wibox.container.margin,
        },
        forced_width = CFG.content_w,
        bg = COLOR_BLACK,
        widget = wibox.container.background,
    }
    return body, { value = value_text, info = info_text, graph = graph, graph2 = graph2, rows = rows }
end

local function build_content()
    local cpu_body, cpu_v = make_section("CPU", cpu_temp_path and 2 or 1, "cpu temp")
    local gpu_body, gpu_v = make_section("GPU", gpu_temp_path and 2 or 1, "edge temp")
    local ram_body, ram_v = make_section("RAM", 1)
    local temp_body, temp_v = make_section("NVMe", #nvme_temp_paths > 0 and 1 or 0,
        nil, false, "nvme (hottest)")
    -- every hwmon temp input as a "name .... figure" row; two columns of
    -- align.horizontal rows so each column's figures share its right edge.
    -- FONT_INFO is the proportional Hack Nerd Font, so space-padding alone
    -- cannot keep figures on one character column — real rows can
    temp_v.cells = {}
    local col_w = math.floor((CFG.content_w - 2 * style.popup.margin_x - dpi(14)) / 2)
    local col_left  = wibox.widget { layout = wibox.layout.fixed.vertical }
    local col_right = wibox.widget { layout = wibox.layout.fixed.vertical }
    local half = math.ceil(#temp_sensors / 2)
    for i, s in ipairs(temp_sensors) do
        local name_w = make_text(s.name, COLOR_GREY, FONT_INFO)
        local temp_w = make_text("--", COLOR_GREY, FONT_INFO)
        temp_w.align = "right"
        local row = wibox.widget {
            name_w, nil, temp_w,
            forced_width = col_w,
            layout = wibox.layout.align.horizontal,
        }
        -- (luajit 5.1 rejects statements that start with a paren)
        local col = i <= half and col_left or col_right
        col:add(row)
        temp_v.cells[i] = temp_w
    end
    -- the list heading carries the sensor count, so the generic info row is
    -- dropped for this section; centred to sit over the two columns
    local list_at = #temp_v.rows:get_children()
    temp_v.rows:remove(list_at)
    local list_title = make_text(
        string.format("%d hwmon sensor temps", #temp_sensors), COLOR_GREY, FONT_INFO)
    list_title.align = "center"
    temp_v.rows:insert(list_at, list_title)
    temp_v.rows:insert(list_at + 1, wibox.widget {
        col_left,
        col_right,
        spacing = dpi(14),
        layout = wibox.layout.fixed.horizontal,
    })
    views = { cpu = cpu_v, gpu = gpu_v, ram = ram_v, temp = temp_v }

    -- per-core strips under the CPU graphs and per-engine strips under the
    -- GPU graphs; both inserted ahead of the info row (the last child of
    -- each section's rows)
    local cores_w, eng_w
    cores_w, cores_graph = make_tapestry(cpu_rows, core_count)
    eng_w, eng_graph = make_tapestry(eng_rows, #eng_names)
    local info_at = #cpu_v.rows:get_children()
    cpu_v.rows:insert(info_at, make_text("per-core busy", COLOR_GREY, FONT_INFO))
    cpu_v.rows:insert(info_at + 1, cores_w)
    local ginfo_at = #gpu_v.rows:get_children()
    gpu_v.rows:insert(ginfo_at, make_text("per-engine busy (fdinfo)", COLOR_GREY, FONT_INFO))
    gpu_v.rows:insert(ginfo_at + 1, eng_w)

    -- fan section disabled: this hardware exposes no tach input or pwm duty.
    -- uncomment (plus a `fan_body` row in the layout below) if one shows up;
    -- an rpm graph has no natural 0-100 bound, so it gets scale = true
    -- local has_fan_source = #fan_paths > 0 or pwm_path ~= nil
    -- local fan_body, fan_v = make_section("Fan", has_fan_source and 1 or 0)
    -- views.fan = fan_v
    -- if fan_v.graph and #fan_paths > 0 and not pwm_path then
    --     fan_v.graph.max_value = nil
    --     fan_v.graph.scale = true
    -- end

    -- header (title drag handle + detach + pin) and the detach/drag controller
    -- come from popup_common so this popup shares the float-and-drag behaviour
    -- of the rest of the wibar popups
    local header
    header, ctrl = popup_common.draggable_header {
        holder = popup_holder,
        name  = "resource_popup",
        title = "System",
        width = CFG.content_w,
        hide  = function() hide() end,
    }

    return wibox.widget {
        header,
        {
            cpu_body,
            separator(),
            gpu_body,
            separator(),
            ram_body,
            separator(),
            temp_body,
            layout = wibox.layout.fixed.vertical,
        },
        -- separator(),
        -- fan_body,
        -- very small bottom Spacer
        wibox.widget {
            forced_height = dpi(4),
            widget = wibox.container.background,
        },
        layout = wibox.layout.fixed.vertical,
    }
end


-- MARK: POPUP

local function ensure_popup()
    if popup then return end
    probe_hwmon()
    -- seeds core_count (needed to size the per-core tapestry at build) and
    -- the cpuN/engine deltas, so the first real sample shows figures, not nils
    read_cpu()
    read_gpu_engines()
    local pstyle = popup_common.popup_style()
    -- build content first so the awful.popup constructor gets its required
    -- widget arg; draggable_header reads popup via popup_holder, which is
    -- assigned right after construction
    local content = wibox.widget {
        {
            build_content(),
            strategy = "max",
            width    = CFG.content_w,
            widget   = wibox.container.constraint,
        },
        strategy = "min",
        height   = CFG.content_h,
        widget   = wibox.container.constraint,
    }
    popup = awful.popup {
        widget   = content,
        visible  = false,
        ontop    = true,
        bg       = COLOR_BLACK,
        border_width = pstyle.border_width,
        border_color = COLOR_GOLD,
        shape = pstyle.shape,
    }
    popup_holder.popup = popup
end

-- outside-click detection is installed only when the pin is off
-- (auto-close); see plugins/popup_common.lua
hide = function()
    if not popup or not popup.visible then return end
    -- stop sampling while closed: the graphs are invisible, and every tick
    -- reads ~15 sysfs files and writes widgets nothing can see
    if sample_timer then sample_timer:stop() end
    popup_common.hide(popup)
end

local function show(anchor)
    ensure_popup()
    ctrl.set_anchor(anchor)
    awesome.emit_signal("popup::opening")
    sample()
    if sample_timer and not sample_timer.started then sample_timer:start() end
    popup_common.show_placement(popup, anchor, ctrl.show_opts())
end

local function toggle(anchor)
    ensure_popup()
    ctrl.toggle(anchor, show)
end


-- MARK: ATTACH

-- Wire left-click toggle (and right-click dismiss) on a resource widget. Uses
-- connect_signal so nothing else bound to the widget is clobbered. Safe to
-- call once per widget per screen; all of them share the single popup.
function M.attach(widget, highlight)
    ensure_popup()
    if not sample_timer then
        -- created stopped: show() samples once and starts the timer, so no
        -- work happens while the popup has never been opened
        sample_timer = gears.timer {
            timeout = 2, autostart = false,
            callback = guarded(sample),
        }
        awesome.connect_signal("exit", guarded(function() sample_timer:stop() end))

        -- pause sampling while dragged: a graph rebuild mid-move hitches the
        -- drag (attach runs once per resource bar, so connect here once)
        popup:connect_signal("popup::drag_begin", guarded(function()
            sample_timer:stop()
        end))
        popup:connect_signal("popup::drag_end", guarded(function()
            if popup.visible and not sample_timer.started then
                sample_timer:start()
            end
        end))
    end
    popup_common.attach(popup, widget, toggle, { right_hide = hide, highlight = highlight })
end

return M
