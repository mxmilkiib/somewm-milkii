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
local ai_popup = require("plugins.ai_popup")
local dpi = beautiful.xresources.apply_dpi
local icon_dir = "/usr/share/icons/Adwaita/symbolic/"
local WIDGET_FONT = font_utils.FONT_MONO
local M = {}
local volume_views = {}
local volume_timer
local last_volume_icon, last_volume_color, last_volume_muted, last_volume_pct
local resource_views = {}
local resource_timer
local ai_views = {}
local ai_timer
local previous_cpu_total, previous_cpu_idle
local stat_glyphs = { cpu = "󰍛", gpu = "󰢮", ram = "󰘚", temp = "󰔏" }
local STAT_GAP = dpi(2)  -- px between stat glyph and value
-- guard against duplicate signal connections on hot-reload (P11)
local signals_connected = false

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
    -- skip the SVG reload+retint and the text write when nothing changed;
    -- the poll ticks far more often than the volume actually moves
    if icon == last_volume_icon and color == last_volume_color
        and muted == last_volume_muted and pct == last_volume_pct then
        return
    end
    last_volume_icon, last_volume_color = icon, color
    last_volume_muted, last_volume_pct = muted, pct
    local painted = gears.color.recolor_image(icon_dir .. "status/" .. icon, color)
    for _, view in ipairs(volume_views) do
        view.icon.image = painted
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

if not signals_connected then
    awesome.connect_signal("volume::updated", guarded(apply_volume))
    signals_connected = true
end

-- debounce: one sink change emits a burst of pactl events; collapse them into
-- a single wpctl query
local volume_debounce = gears.timer {
    timeout = 0.15, single_shot = true, autostart = false,
    callback = guarded(update_volume),
}

-- event-driven volume tracking: one persistent pactl subscriber prints a line
-- per server event. replaces the 10s poll, which also lagged external changes
-- (pavucontrol, other apps) by up to its interval
local volume_sub_dead = true
local volume_sub_pid
local function start_volume_sub()
    if not volume_sub_dead then return end
    volume_sub_pid = awful.spawn.with_line_callback({ "pactl", "subscribe" }, {
        stdout = guarded(function(line)
            if line:find("on sink") or line:find("on source") or line:find("on server") then
                volume_debounce:again()
            end
        end),
        exit = guarded(function() volume_sub_dead = true; volume_sub_pid = nil end),
    })
    volume_sub_dead = type(volume_sub_pid) ~= "number"
end

local function ensure_volume_timer()
    if volume_timer then return end
    -- keybind changes arrive instantly via volume::updated; external changes
    -- via the pactl subscriber. the slow poll is only a safety net that also
    -- restarts the subscriber if its process dies
    volume_timer = gears.timer { timeout = 60, autostart = true, call_now = true, callback = guarded(function()
        if volume_sub_dead then start_volume_sub() end
        update_volume()
        return true
    end) }
    awesome.connect_signal("exit", guarded(function()
        volume_timer:stop()
        if volume_sub_pid then
            awful.spawn.with_shell("kill " .. volume_sub_pid .. " 2>/dev/null")
            volume_sub_pid = nil
        end
    end))
    start_volume_sub()
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

M.read_cpu_temp = read_cpu_temp

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
    -- the display only ever shows whole units; skip the markup+text write
    -- (and the redraw it triggers) when the rounded value didn't move
    local shown = math.floor(v + 0.5)
    if view.last_shown == shown then return end
    view.last_shown = shown
    view.glyph.markup = string.format('<span foreground="%s">%s</span>',
        stat_glyph_colour(v), glyph)
    view.value.text = string.format(fmt, shown)
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
        if used and total then
            local tip = string.format("Memory: %.1f / %.1f GiB", used, total)
            if tip ~= view.last_tip then
                view.last_tip = tip
                view.ram_tip:set_text(tip)
            end
        end
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


-- // MARK -- ai status

-- Two bar icons on a purple badge: a robot for the main LLM server
-- (llama-server) and a microphone for dictation (whisper-dictate). The
-- robot is green while llama-server runs, the mic green only while
-- dictation is actually recording — an idle whisper-server shows grey.
-- Both glyphs brighten to gold on hover. Left-click opens the AI popup
-- (attached in rc.lua). Polls every 15s and also refreshes on the
-- "ai::status_changed" signal emitted by the popup after a toggle.
local AI_BG = (beautiful.main_purple and beautiful.main_purple.base) or "#623997"
local AI_GLYPH_SERVER = "\u{F06A9}"  -- nf-md-robot
local AI_GLYPH_VOICE  = "\u{F036C}"  -- nf-md-microphone
local AI_COLOR_ACTIVE = "#69D665"
local AI_COLOR_IDLE   = "#CCCCCC"
local AI_COLOR_HOVER  = "#FFD700"

local function set_ai_glyph(w, glyph, color)
    w.markup = string.format('<span foreground="%s">%s</span>', color, glyph)
end

-- old: single glyph coloured by overall status (green for llama, gold for
--      any other service, grey when all idle)
-- local function update_ai_status()
--     ai_popup.query_status(guarded(function(status)
--         local llama = status.llama == "active"
--         local whisper = status.whisper == "active"
--         local openwebui = status.openwebui == "active"
--         local any = llama or whisper or openwebui
--         local color = llama and "#69D665" or any and "#FFD700" or "#CCCCCC"
--         for _, view in ipairs(ai_views) do
--             view.glyph.markup = string.format('<span foreground="%s">\u{F06A9}</span>', color)
--         end
--     end))
-- end

local function update_ai_status()
    ai_popup.query_status(guarded(function(status)
        local llama = status.llama == "active"
        -- the mic is a recording indicator, not a service indicator: green
        -- only while whisper-dictate is capturing, not for an idle
        -- whisper-server
        local voice = status.dictate == "active"
        local server_color = llama and AI_COLOR_ACTIVE or AI_COLOR_IDLE
        local voice_color  = voice  and AI_COLOR_ACTIVE or AI_COLOR_IDLE
        for _, view in ipairs(ai_views) do
            view.server_color = server_color
            view.voice_color  = voice_color
            if not view.hovering then
                set_ai_glyph(view.glyph_server, AI_GLYPH_SERVER, server_color)
                set_ai_glyph(view.glyph_voice,  AI_GLYPH_VOICE,  voice_color)
            end
            if view.tooltip then
                view.tooltip.text = string.format("Local AI: %s | %s",
                    llama and "server running" or "server idle",
                    voice and "recording" or "not recording")
            end
        end
    end))
end

function M.ai_status(args)
    args = args or {}
    local glyph_server = wibox.widget {
        markup = string.format('<span foreground="%s">%s</span>', AI_COLOR_IDLE, AI_GLYPH_SERVER),
        font = font_utils.mono_size(13),
        valign = "center",
        widget = wibox.widget.textbox,
    }
    local glyph_voice = wibox.widget {
        markup = string.format('<span foreground="%s">%s</span>', AI_COLOR_IDLE, AI_GLYPH_VOICE),
        font = font_utils.mono_size(13),
        valign = "center",
        widget = wibox.widget.textbox,
    }
    -- distinctive purple badge: the AI widget is the only bar icon with a
    -- permanent coloured background, set flush so the purple band spans the
    -- full height of the bar, setting it apart from the outline-only hover
    -- borders on the other info widgets. No place wrapper and no rounded
    -- shape: anything that shrink-wraps the badge vertically turns the
    -- purple back into a floating pill.
    -- old: rounded pill — top/bottom = dpi(1) margins + rounded_rect shape,
    --      returned via centered(badge)
    local badge = wibox.widget {
        {
            {
                glyph_server,
                glyph_voice,
                spacing = dpi(4),
                layout = wibox.layout.fixed.horizontal,
            },
            left = dpi(5), right = dpi(5),
            widget = wibox.container.margin,
        },
        bg = AI_BG,
        widget = wibox.container.background,
    }
    local widget = badge
    local view = {
        glyph_server = glyph_server,
        glyph_voice  = glyph_voice,
        server_color = AI_COLOR_IDLE,
        voice_color  = AI_COLOR_IDLE,
        hovering     = false,
    }
    -- hover: brighten both glyphs to gold; restore status colours on leave
    widget:connect_signal("mouse::enter", function()
        view.hovering = true
        set_ai_glyph(glyph_server, AI_GLYPH_SERVER, AI_COLOR_HOVER)
        set_ai_glyph(glyph_voice,  AI_GLYPH_VOICE,  AI_COLOR_HOVER)
    end)
    widget:connect_signal("mouse::leave", function()
        view.hovering = false
        set_ai_glyph(glyph_server, AI_GLYPH_SERVER, view.server_color)
        set_ai_glyph(glyph_voice,  AI_GLYPH_VOICE,  view.voice_color)
    end)
    ai_views[#ai_views + 1] = view
    widget:buttons(gears.table.join(
        awful.button({}, 1, args.open or function() end)
    ))
    if not ai_timer then
        -- toggles inside the popup emit ai::status_changed for an instant
        -- refresh; the poll only needs to catch services changed elsewhere
        ai_timer = gears.timer { timeout = 15, autostart = true, call_now = true,
            callback = guarded(update_ai_status) }
        awesome.connect_signal("exit", guarded(function() ai_timer:stop() end))
        awesome.connect_signal("ai::status_changed", guarded(update_ai_status))
    end
    local tip = awful.tooltip { objects = { widget }, text = "Local AI services" }
    view.tooltip = tip
    return widget
end


-- shimmer status widget: a single glyph whose colour tracks the animation
-- run state (gold while running, grey while stopped). left-click opens the
-- shimmer popup (interactive controls); the popup is attached in rc.lua via
-- shimmer_popup.attach so this constructor stays popup-agnostic, mirroring
-- how the other widgets here delegate their click target through `args.open`
local shimmer_views = {}
local shimmer_timer
local shimmer_mod  -- cached on first use so the 2s poll doesn't re-require
local SHIMMER_GLYPH = "\u{F0E02}"  -- Nerd Font "format-color" / palette swatch

local function update_shimmer_status()
    if not shimmer_mod then shimmer_mod = require("plugins.shimmer") end
    local running = shimmer_mod.is_running and shimmer_mod.is_running()
    local preset  = shimmer_mod.get_current_preset and shimmer_mod.get_current_preset() or ""
    for _, view in ipairs(shimmer_views) do
        view.glyph.markup = string.format('<span foreground="%s">%s</span>',
            running and "#E6B84D" or "#777777", SHIMMER_GLYPH)
    end
    -- tooltip carries the live preset so the bar hints at the active effect
    -- without opening the popup
    for _, view in ipairs(shimmer_views) do
        if view.tooltip then
            view.tooltip.text = string.format("Shimmer: %s%s",
                running and "running " or "stopped ", preset)
        end
    end
end

function M.shimmer(args)
    args = args or {}
    local glyph = wibox.widget {
        markup = string.format('<span foreground="#777777">%s</span>', SHIMMER_GLYPH),
        font = font_utils.mono_size(13),
        valign = "center",
        widget = wibox.widget.textbox,
    }
    local widget = centered(glyph)
    local tip = awful.tooltip { objects = { widget }, text = "Shimmer" }
    shimmer_views[#shimmer_views + 1] = { glyph = glyph, tooltip = tip }
    widget:buttons(gears.table.join(
        awful.button({}, 1, args.open or function() end)
    ))
    if not shimmer_timer then
        update_shimmer_status()
        -- start/stop/mode changes arrive via the facade's state_changed
        -- signal; the 30 s tick is a fallback for anything that bypasses it
        awesome.connect_signal("shimmer::state_changed", guarded(update_shimmer_status))
        shimmer_timer = gears.timer { timeout = 30, autostart = true,
            callback = guarded(update_shimmer_status) }
        awesome.connect_signal("exit", guarded(function() shimmer_timer:stop() end))
    end
    return widget
end

return M
