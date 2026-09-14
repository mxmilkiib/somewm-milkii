-- plugins/system_widgets.lua
-- Compact DE-style bar widgets not supplied by SNI: cpu/gpu/ram/temp stats,
-- volume, keyboard layout, and show desktop. Polling is shared by every screen.

local awful = require("awful")
local wibox = require("wibox")
local gears = require("gears")
local beautiful = require("beautiful")
local keyboardlayout = require("awful.widget.keyboardlayout")
local guarded = require("error_guard")

local font_utils = require("rc.font_utils")
local dpi = beautiful.xresources.apply_dpi
local icon_dir = "/usr/share/icons/Adwaita/symbolic/"
local WIDGET_FONT = font_utils.FONT_MONO
local M = {}
local volume_views = {}
local volume_timer
local resource_views = {}
local resource_timer
local previous_cpu_total, previous_cpu_idle
local stat_glyphs = { cpu = "󰍛", gpu = "󰢮", ram = "󰘚", temp = "󰔏" }
local STAT_GAP = dpi(2)  -- px between stat glyph and value

local function centered(widget)
    return wibox.widget { widget, halign = "center", valign = "center", widget = wibox.container.place }
end

local function apply_volume(pct, muted)
    local icon = muted and "audio-volume-muted-symbolic.svg"
        or pct < 34 and "audio-volume-low-symbolic.svg"
        or pct < 67 and "audio-volume-medium-symbolic.svg"
        or "audio-volume-high-symbolic.svg"
    local color = muted and "#777777"
        or pct < 34 and "#C5E89A"  -- pale lime green
        or pct < 67 and "#9FD64A"  -- medium lime green
        or "#6FA820"               -- strong lime green
    for _, view in ipairs(volume_views) do
        view.icon.image = gears.color.recolor_image(icon_dir .. "status/" .. icon, color)
        view.text.text = muted and "--%" or (pct .. "%")
    end
end

local function update_volume()
    awful.spawn.easy_async({ "wpctl", "get-volume", "@DEFAULT_AUDIO_SINK@" }, guarded(function(out)
        local value = tonumber(out:match("Volume:%s*([%d%.]+)"))
        if not value then return end
        apply_volume(math.floor(value * 100 + 0.5), out:find("MUTED") ~= nil)
    end))
end

awesome.connect_signal("volume::updated", guarded(apply_volume))

local function ensure_volume_timer()
    if volume_timer then return end
    volume_timer = gears.timer { timeout = 2, autostart = true, call_now = true, callback = guarded(update_volume) }
    awesome.connect_signal("exit", guarded(function() volume_timer:stop() end))
end

function M.volume(args)
    args = args or {}
    local icon = wibox.widget { forced_width = dpi(14), forced_height = dpi(14), resize = true, widget = wibox.widget.imagebox }
    local text = wibox.widget { text = "--%", font = WIDGET_FONT, valign = "center", widget = wibox.widget.textbox }
    local content = wibox.widget {
        icon,
        { text, left = dpi(2), widget = wibox.container.margin },
        spacing = dpi(2),
        layout = wibox.layout.fixed.horizontal,
    }
    local widget = centered(content)
    volume_views[#volume_views + 1] = { icon = icon, text = text }
    widget:buttons(gears.table.join(
        awful.button({}, 1, args.open or function() awful.spawn("pavucontrol") end),
        awful.button({}, 2, args.mute or function() awful.spawn({ "wpctl", "set-mute", "@DEFAULT_AUDIO_SINK@", "toggle" }) end),
        awful.button({}, 4, args.up),
        awful.button({}, 5, args.down)
    ))
    ensure_volume_timer()
    return widget
end

local function read_cpu()
    local file = io.open("/proc/stat", "r")
    if not file then return nil end
    local line = file:read("*l")
    file:close()
    local values = {}
    for value in line:gmatch("%d+") do values[#values + 1] = tonumber(value) end
    local total = 0
    for _, value in ipairs(values) do total = total + value end
    local idle = (values[4] or 0) + (values[5] or 0)
    local usage
    if previous_cpu_total and total > previous_cpu_total then
        usage = 100 * (1 - (idle - previous_cpu_idle) / (total - previous_cpu_total))
    end
    previous_cpu_total, previous_cpu_idle = total, idle
    return usage
end

local function read_ram()
    local file = io.open("/proc/meminfo", "r")
    if not file then return nil end
    local total, available
    for line in file:lines() do
        total = total or tonumber(line:match("^MemTotal:%s+(%d+)"))
        available = available or tonumber(line:match("^MemAvailable:%s+(%d+)"))
        if total and available then break end
    end
    file:close()
    if not total or not available then return nil end
    return 100 * (total - available) / total, (total - available) / 1048576, total / 1048576
end

local function read_gpu()
    for card = 0, 7 do
        local file = io.open("/sys/class/drm/card" .. card .. "/device/gpu_busy_percent", "r")
        if file then
            local usage = tonumber(file:read("*l"))
            file:close()
            if usage then return usage end
        end
    end
end

-- CPU temp source found once (k10temp/coretemp/zenpower temp1_input), then
-- read directly; false marks "no sensor" so probing stops after the first pass
local cpu_temp_path
local function read_cpu_temp()
    if cpu_temp_path == nil then
        cpu_temp_path = false
        for i = 0, 15 do
            local name_file = io.open("/sys/class/hwmon/hwmon" .. i .. "/name", "r")
            if name_file then
                local name = name_file:read("*l")
                name_file:close()
                if name == "k10temp" or name == "coretemp" or name == "zenpower" then
                    local path = "/sys/class/hwmon/hwmon" .. i .. "/temp1_input"
                    local probe = io.open(path, "r")
                    if probe then probe:close() cpu_temp_path = path end
                    break
                end
            end
        end
    end
    if not cpu_temp_path then return nil end
    local file = io.open(cpu_temp_path, "r")
    if not file then return nil end
    local temp = tonumber(file:read("*l"))
    file:close()
    return temp and temp / 1000
end

-- stepped colour ramp for the stat glyphs (same bands as the popup's sensor
-- figures): low = lime, mid = gold, high = orange, very high = red
local function stat_glyph_colour(v)
    if v < 55 then return "#9FD64A"
    elseif v < 75 then return "#FFD700"
    elseif v < 90 then return "#E8934A"
    else return "#FF6B6B" end
end

-- glyph tinted by value via pango markup (textbox fg is a no-op in somewm);
-- the value sits in its own textbox so the glyph–value gap is a real pixel
-- spacing, not a space glyph of whatever width the font gives it
local function set_stat(view, glyph, fmt, v)
    view.glyph.markup = string.format('<span foreground="%s">%s</span>',
        stat_glyph_colour(v), glyph)
    view.value.text = string.format(fmt, math.floor(v + 0.5))
end

local function update_resources()
    local cpu = read_cpu()
    local ram, used, total = read_ram()
    local gpu = read_gpu()
    local ctemp = read_cpu_temp()
    for _, view in ipairs(resource_views) do
        if cpu then set_stat(view.cpu, stat_glyphs.cpu, "%d%%", cpu) end
        if gpu then set_stat(view.gpu, stat_glyphs.gpu, "%d%%", gpu) end
        if ram then set_stat(view.ram, stat_glyphs.ram, "%d%%", ram) end
        if ctemp and view.temp then set_stat(view.temp, stat_glyphs.temp, "%d°C", ctemp) end
        if used and total then view.ram_tip:set_text(string.format("Memory: %.1f / %.1f GiB", used, total)) end
    end
end

local function stat_label(glyph, init, glyph_size)
    local glyph_w = wibox.widget {
        markup = glyph,
        font = font_utils.mono_size(glyph_size or 12),
        valign = "center",
        widget = wibox.widget.textbox,
    }
    local value_w = wibox.widget {
        text = init,
        font = WIDGET_FONT,
        valign = "center",
        widget = wibox.widget.textbox,
    }
    local widget = centered(wibox.widget {
        glyph_w,
        value_w,
        spacing = STAT_GAP,
        layout = wibox.layout.fixed.horizontal,
    })
    return widget, glyph_w, value_w
end

function M.resources()
    local cpu, cpu_g, cpu_v = stat_label(stat_glyphs.cpu, "--%")
    local gpu, gpu_g, gpu_v = stat_label(stat_glyphs.gpu, "--%", 13)
    local ram, ram_g, ram_v = stat_label(stat_glyphs.ram, "--%")
    local temp, temp_g, temp_v = stat_label(stat_glyphs.temp, "--°")
    local view = {
        cpu = { glyph = cpu_g, value = cpu_v },
        gpu = { glyph = gpu_g, value = gpu_v },
        ram = { glyph = ram_g, value = ram_v },
        temp = { glyph = temp_g, value = temp_v },
        ram_tip = awful.tooltip { objects = { ram }, text = "Memory" },
    }
    awful.tooltip { objects = { cpu }, text = "Total CPU usage" }
    awful.tooltip { objects = { gpu }, text = "GPU busy" }
    awful.tooltip { objects = { temp }, text = "CPU temperature (Tctl)" }
    resource_views[#resource_views + 1] = view
    if not resource_timer then
        resource_timer = gears.timer { timeout = 2, autostart = true, call_now = true, callback = guarded(update_resources) }
        awesome.connect_signal("exit", guarded(function() resource_timer:stop() end))
    end
    return { cpu = cpu, gpu = gpu, ram = ram, temp = temp }
end

function M.keyboard()
    local label = keyboardlayout.new()
    local widget = centered(wibox.widget {
        label,
        left = dpi(4), right = dpi(4),
        widget = wibox.container.margin,
    })
    awful.tooltip { objects = { widget }, text = "Keyboard layout" }
    return widget
end

function M.show_desktop(s)
    local icon = wibox.widget {
        image = gears.color.recolor_image(icon_dir .. "devices/video-display-symbolic.svg", "#777777"),
        forced_width = dpi(14), forced_height = dpi(14), resize = true,
        widget = wibox.widget.imagebox,
    }
    local widget = wibox.widget {
        { icon, halign = "center", valign = "center", widget = wibox.container.place },
        forced_width = dpi(32),
        forced_height = dpi(32),
        bg = "#000000",
        widget = wibox.container.background,
    }
    widget:connect_signal("mouse::enter", function()
        icon.image = gears.color.recolor_image(icon_dir .. "devices/video-display-symbolic.svg", "#CCCCCC")
    end)
    widget:connect_signal("mouse::leave", function()
        icon.image = gears.color.recolor_image(icon_dir .. "devices/video-display-symbolic.svg", "#777777")
    end)
    local hidden = setmetatable({}, { __mode = "k" })
    local showing = false
    widget:buttons(gears.table.join(awful.button({}, 1, function()
        if showing then
            for c in pairs(hidden) do if c.valid then c.minimized = false end end
            hidden = setmetatable({}, { __mode = "k" })
            showing = false
            return
        end
        for _, c in ipairs(client.get(s)) do
            if c.valid and not c.minimized and c:isvisible() then
                hidden[c] = true
                c.minimized = true
            end
        end
        showing = true
    end)))
    awful.tooltip { objects = { widget }, text = "Show desktop" }
    return widget
end

return M
