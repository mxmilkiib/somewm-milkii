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

-- capi globals captured once: mousegrabber drives the header drag
local capi = { mousegrabber = mousegrabber }

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
local anchor_widget
local sample_timer
local views          -- { cpu = {value,info,graph}, gpu = ..., ram = ..., temp = ... }
local core_count = 0
-- forward declarations: the pin/detach callbacks (built inside build_content)
-- need these bound as upvalues before the POPUP section assigns them
local hide
local is_pinned  -- getter set in build_content (see popup_common.pin)
local paint_detach
local set_detached
local start_drag
local set_sticky  -- drives the pin icon from set_detached (set in build_content)
-- detach state: while true the popup floats at its current spot instead of
-- re-anchoring to the clicked widget, and the header is draggable
local detached
local detach_glyph  -- header textbox whose colour tracks `detached`


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
local nvme_temp_path, nvme_temp_caption
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
            -- every temp input, for the Temp section's sensor list
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
            if name == "nvme" and not nvme_temp_path then
                -- Sensor 2 responds visibly to drive activity while Composite
                -- sits flat; a graph wants the livelier input. it is the sole
                -- preferred label: the scan hits Composite first otherwise
                local label
                nvme_temp_path, label = pick_temp(dir, { ["Sensor 2"] = true })
                nvme_temp_caption = label and (name .. " (" .. label:lower() .. ")")
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
    local nvme_t = nvme_temp_path and read_num(nvme_temp_path)
    if not views then return end

    if cpu then views.cpu.graph:add_value(cpu) end
    if gpu then views.gpu.graph:add_value(gpu) end
    if ram then views.ram.graph:add_value(ram) end
    -- second graphs: CPU package temp under CPU busy, GPU edge temp under
    -- GPU busy; the Temp section's own graph is the NVMe sensor
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
        local mhz = read_num(gpu_freq_path)
        if mhz then gpu_bits[#gpu_bits + 1] = string.format("sclk %d MHz", mhz) end
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
    views.temp.info.text = string.format("%d hwmon sensors", #temp_sensors)
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
    -- min-height constraint so the graph is at least GRAPH_H but can grow
    -- to fill extra space when the popup's min-height floor leaves room
    local constrained = wibox.widget {
        {
            graph,
            widget = wibox.layout.flex.vertical,
        },
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
    local temp_body, temp_v = make_section("Temp", nvme_temp_path and 1 or 0,
        nil, false, nvme_temp_caption)
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
    temp_v.rows:add(wibox.widget {
        col_left,
        col_right,
        spacing = dpi(14),
        layout = wibox.layout.fixed.horizontal,
    })
    -- centre the "N hwmon sensors" Count Line
    temp_v.info.align = "center"
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

    -- pin toggle at the right of the header: gold = stays open on outside
    -- clicks, grey = any outside click closes it
    local pin_btn, pinned, set_pin = popup_common.pin("resource_popup", function(on)
        if popup and popup.visible then
            if on then popup_common.outside_click_teardown(popup)
            else popup_common.outside_click_setup(popup, hide) end
        end
    end)
    is_pinned = pinned
    -- set_pin drives the pin icon from set_detached: a detached popup is
    -- sticky, so the pin shows gold. transient (not persisted) so re-anchoring
    -- restores the user's actual stay-open preference from disk
    set_sticky = function(on)
        set_pin(on, false, false)
    end

    -- detach button: gold while the popup floats free, grey while anchored.
    -- built here so its textbox is wired into the module-level paint_detach
    detach_glyph = wibox.widget {
        align = "center", valign = "center",
        font = FONT_HEAD, widget = wibox.widget.textbox,
    }
    local detach_btn = wibox.widget { detach_glyph, widget = wibox.container.background }
    awful.tooltip { objects = { detach_btn },
        text = "Detach: click or drag the title to float the popup" }
    detach_btn:buttons(gears.table.join(awful.button({}, 1, guarded(function()
        set_detached(not detached)
    end))))
    paint_detach()

    -- the title and the stretch beside it are the drag handle; the buttons
    -- on the right sit outside the handle so they keep their own clicks.
    -- a space textbox gives the stretchy middle real geometry to receive
    -- button::press, else an empty container can miss the press on somewm
    local title_w = make_text("System", COLOR_WHITE, FONT_HEAD)
    local drag_area = wibox.widget {
        { text = " ", widget = wibox.widget.textbox },
        bg = "#00000000",
        widget = wibox.container.background,
    }
    local function on_drag_press(_, _, _, button)
        if button == 1 then start_drag() end
    end
    title_w:connect_signal("button::press", on_drag_press)
    drag_area:connect_signal("button::press", on_drag_press)

    local header = wibox.widget {
        {
            {
                title_w,
                drag_area,
                {
                    detach_btn,
                    pin_btn,
                    spacing = dpi(6),
                    layout = wibox.layout.fixed.horizontal,
                },
                layout = wibox.layout.align.horizontal,
            },
            left = dpi(10), right = dpi(10),
            top = dpi(6), bottom = dpi(6),
            widget = wibox.container.margin,
        },
        forced_width = CONTENT_W,
        bg = COLOR_PURPLE,
        widget = wibox.container.background,
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
            layout = wibox.layout.flex.vertical,
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
    popup = awful.popup {
        -- the inner constraint forces the fit to measure children at the real
        -- content width; unbounded, info lines fit on one line and the
        -- reported height comes up short once they wrap at draw time. the
        -- outer constraint sets a min-height floor so the popup keeps a set
        -- tall size even when fewer sensors leave content short of it
        widget   = wibox.widget {
            {
                build_content(),
                strategy = "max",
                width    = CONTENT_W,
                widget   = wibox.container.constraint,
            },
            strategy = "min",
            height   = CONTENT_H,
            widget   = wibox.container.constraint,
        },
        visible  = false,
        ontop    = true,
        bg       = COLOR_BLACK,
        border_width = style.border_width,
        border_color = COLOR_GOLD,
        shape = style.shape,
    }
end

-- outside-click detection is installed only when the pin is off
-- (auto-close); see plugins/popup_common.lua
hide = function()
    if not popup or not popup.visible then return end
    popup_common.hide(popup)
    anchor_widget = nil
end

-- detach/sticky: while on, the popup floats at its current spot instead of
-- re-anchoring to the clicked widget, and the header can be dragged. turning
-- it off closes the popup so the next open returns to the anchored position
paint_detach = function()
    if detach_glyph then
        detach_glyph.markup = string.format('<span foreground="%s">󰆼</span>',
            detached and COLOR_GOLD or COLOR_GREY)
    end
end
set_detached = function(on)
    if detached == on then return end
    detached = on
    paint_detach()
    -- detached implies sticky: while floating free the popup also ignores
    -- outside clicks so it stays open until explicitly re-anchored. the pin
    -- icon is driven to gold to reflect this; the pin's persisted state is
    -- left untouched (set_sticky passes persist=false) so re-anchoring
    -- restores the user's actual stay-open preference from disk
    if set_sticky then set_sticky(on) end
    if popup and popup.visible then
        if on then popup_common.outside_click_teardown(popup)
        elseif not is_pinned() then popup_common.outside_click_setup(popup, hide) end
    end
    if not on and popup and popup.visible then hide() end
end

local function place(anchor)
    awful.placement.next_to(popup, {
        widget = anchor,
        preferred_positions = "top",
        preferred_anchors = "back",
        honor_workarea = true,
    })
end

-- drag the popup by its header: a mousegrabber tracks the pointer until the
-- left button releases. entering the grabber also engages detach so the
-- popup stays where it is dropped. the 10 s safety timer mirrors tag_pager's:
-- a missed release can never leave the grabber swallowing all pointer input.
-- the mouse-to-popup offset is captured on the first motion event and every
-- later position is derived from the grabber's own coords, so the popup
-- tracks the cursor exactly rather than accumulating drift from a start
-- snapshot taken in a different coordinate origin
local drag_gen = 0
start_drag = function()
    if not popup or not popup.visible then return end
    if not detached then set_detached(true) end
    drag_gen = drag_gen + 1
    local gen = drag_gen
    local g = popup:geometry()
    local pw, ph = g.width, g.height
    local off_x, off_y
    local safety = gears.timer {
        timeout = 10, single_shot = true,
        callback = guarded(function()
            if capi.mousegrabber.isrunning and capi.mousegrabber.isrunning() then
                capi.mousegrabber.stop()
            end
        end),
    }
    capi.mousegrabber.run(function(m)
        if gen ~= drag_gen then safety:stop() return false end
        if not (m.buttons and m.buttons[1]) then safety:stop() return false end
        if not popup or not popup.visible then safety:stop() return false end
        if not off_x then
            off_x = m.x - g.x
            off_y = m.y - g.y
        end
        -- width/height pinned to the snapshot so the wibox never re-fits
        -- its widget tree during the drag (that re-fit is the judder)
        popup:geometry {
            x = m.x - off_x,
            y = m.y - off_y,
            width = pw, height = ph,
        }
        return true
    end, "fleur")
end

local function show(anchor)
    ensure_popup()
    anchor_widget = anchor
    awesome.emit_signal("popup::opening")
    sample()
    popup_common.show_placement(popup, anchor, {
        is_pinned = is_pinned,
        detached = function() return detached end,
        hide = hide,
    })
end

local function toggle(anchor)
    ensure_popup()
    if popup.visible then
        if anchor == anchor_widget then
            hide()
        elseif not detached then
            anchor_widget = anchor
            place(anchor)
        end
    else
        show(anchor)
    end
end


-- MARK: ATTACH

-- Wire left-click toggle (and right-click dismiss) on a resource widget. Uses
-- connect_signal so nothing else bound to the widget is clobbered. Safe to
-- call once per widget per screen; all of them share the single popup.
function M.attach(widget)
    ensure_popup()
    if not sample_timer then
        sample_timer = gears.timer {
            timeout = 2, autostart = true, call_now = true,
            callback = guarded(sample),
        }
        awesome.connect_signal("exit", guarded(function() sample_timer:stop() end))
    end
    popup_common.attach(popup, widget, toggle, { right_hide = hide })
end

return M
