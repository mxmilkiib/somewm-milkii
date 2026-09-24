-- plugins/resource_popup.lua
-- Clickable popup anchored to the wibar CPU/GPU/RAM widgets. Shows a short
-- scrolling history graph per metric plus current readings: CPU usage/load/
-- temp, GPU busy/temp/clock/power, RAM/swap usage, and temperatures. A fan
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
local beautiful = require("beautiful")
local guarded = require("error_guard")
local popup_common = require("plugins.popup_common")

local dpi = beautiful.xresources.apply_dpi

local COLOR_PURPLE = popup_common.theme.PURPLE
local COLOR_BLACK  = popup_common.theme.BLACK
local COLOR_WHITE  = popup_common.theme.WHITE
local COLOR_GOLD   = popup_common.theme.GOLD
local COLOR_GREY   = popup_common.theme.GREY
local FONT       = popup_common.fonts.FONT
local FONT_INFO  = popup_common.fonts.FONT_INFO
local FONT_VALUE = popup_common.fonts.FONT_VALUE
local FONT_HEAD  = popup_common.fonts.FONT_HEAD
-- local CONTENT_W  = dpi(260)
local CONTENT_W  = dpi(300)
local CONTENT_H  = dpi(700)  -- min-height floor; taller graphs fill most of it
local GRAPH_H    = dpi(44)
local GRAPH_CAP  = 120   -- samples kept per graph (4 min at the 2s interval)

local M = {}

local popup
-- holder table: draggable_header reads popup from here so build_content can
-- run before the awful.popup is constructed (awful.popup requires a widget arg)
local popup_holder = {}
local sample_timer
local views          -- { cpu = {value,info,graph}, gpu = ..., ram = ..., temp = ... }
local core_count = 0
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
local function read_cpu()
    local f = io.open("/proc/stat", "r")
    if not f then return nil end
    local total, idle, n = 0, 0, 0
    for line in f:lines() do
        if line:match("^cpu%d") then
            n = n + 1
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
    if celsius >= 90 then return "#FF6B6B" end
    if celsius >= 75 then return "#E8934A" end
    if celsius >= 55 then return COLOR_GOLD end
    return "#9FD64A"
end

-- the same ramp as a graph gradient: the fill's top edge takes the heat
-- colour, cooling to purple towards the baseline
local function temp_gradient(celsius)
    return "linear:0,0:0," .. GRAPH_H .. ":0," .. temp_colour(celsius)
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
    if gpu then views.gpu.graph:add_value(gpu) end
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
    -- local lines = {}
    -- for _, s in ipairs(temp_sensors) do
    --     local v = read_num(s.path)
    --     local cell = v and string.format("%.0f°C", v / 1000) or "n/a"
    --     -- centre the stat in its column so it has equal space either side.
    --     -- somewm runs LuaJIT 5.1 (no utf8 lib): count chars by subtracting
    --     -- UTF-8 continuation bytes (0x80-0xBF) from the byte length
    --     local pad = 6 - (#cell - select(2, cell:gsub("[\128-\191]", "")))
    --     local lpad = math.floor(pad / 2)
    --     lines[#lines + 1] = string.format("%-15s%s%s%s", s.name,
    --         (" "):rep(lpad), cell, (" "):rep(pad - lpad))
    -- end
    -- views.temp.list.text = table.concat(lines, "\n")

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
    return popup_common.separator(CONTENT_W)
end

-- transparent overlay stacked over a graph: a faint grey hairline per minute
-- of history (30 samples at the 2 s interval), counted back from the right
-- edge where the newest sample sits after the mirror
local MINUTE_PX = (dpi(2) + dpi(1)) * 30  -- step_width + step_spacing, per min
local function minute_markers()
    local w = base.make_widget()
    function w:draw(_, cr, width, height)
        cr:set_source_rgba(0.75, 0.75, 0.75, 0.22)
        cr:set_line_width(1)
        local x = width - MINUTE_PX
        while x > 0 do
            cr:move_to(x + 0.5, 0)   -- half-pixel for a crisp 1px line
            cr:line_to(x + 0.5, height)
            x = x - MINUTE_PX
        end
        cr:stroke()
    end
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
        capacity = GRAPH_CAP,
        step_width = dpi(2),
        step_spacing = dpi(1),
        forced_width = CONTENT_W - dpi(20),
        color = "linear:0,0:0," .. GRAPH_H .. ":0," .. COLOR_GOLD
            .. ":0.5," .. COLOR_PURPLE .. ":1," .. COLOR_PURPLE,
        background_color = "#00000000",
        widget = wibox.widget.graph,
    }
    -- min-height constraint so the graph is at least GRAPH_H but can grow to
    -- fill extra space when the popup's min-height floor leaves room. the
    -- flex's max_widget_size caps that growth — wibox.widget.graph:fit is
    -- greedy (returns the full offered height), so without a cap each graph
    -- claims the whole fit allowance and the popup balloons to fit height
    local graph_flex = wibox.widget {
        graph,
        max_widget_size = GRAPH_H * 1.5,
        layout = wibox.layout.flex.vertical,
    }
    local constrained = wibox.widget {
        graph_flex,
        strategy = "min",
        height = GRAPH_H,
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
        spacing = dpi(4),
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
            left = dpi(10), right = dpi(10),
            top = dpi(6), bottom = dpi(6),
            widget = wibox.container.margin,
        },
        forced_width = CONTENT_W,
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
    local col_w = math.floor((CONTENT_W - dpi(20) - dpi(14)) / 2)
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
        width = CONTENT_W,
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
    local style = popup_common.popup_style()
    -- build content first so the awful.popup constructor gets its required
    -- widget arg; draggable_header reads popup via popup_holder, which is
    -- assigned right after construction
    local content = wibox.widget {
        {
            build_content(),
            strategy = "max",
            width    = CONTENT_W,
            widget   = wibox.container.constraint,
        },
        strategy = "min",
        height   = CONTENT_H,
        widget   = wibox.container.constraint,
    }
    popup = awful.popup {
        widget   = content,
        visible  = false,
        ontop    = true,
        bg       = COLOR_BLACK,
        border_width = style.border_width,
        border_color = COLOR_GOLD,
        shape = style.shape,
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
