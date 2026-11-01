-- plugins/brightness_popup.lua
-- Clickable popup anchored to the wibar brightness widget. Lists all active
-- displays with their brightness levels and a refresh button that tells
-- wlr-brightnessd to retry failed gamma controls and re-apply gamma.
--
-- One shared popup is created lazily and re-anchored to whichever brightness
-- widget is clicked (the wibar is built per-screen).

local awful   = require("awful")
local gears   = require("gears")
local wibox   = require("wibox")
local beautiful = require("beautiful")
local gshape  = require("gears.shape")
local guarded = require("error_guard")
local popup_common = require("plugins.popup_common")
local style   = require("plugins.style")

local dpi = style.dpi

local capi_output = output

local COLOR_PURPLE = popup_common.theme.PURPLE
local COLOR_BLACK  = popup_common.theme.BLACK
local COLOR_WHITE  = popup_common.theme.WHITE
local COLOR_GOLD   = popup_common.theme.GOLD
local COLOR_GREY   = popup_common.theme.GREY
local COLOR_HOVER  = popup_common.theme.HOVER
local COLOR_RED    = popup_common.theme.RED
local COLOR_GREEN   = popup_common.theme.GREEN
local FONT       = popup_common.fonts.FONT
local FONT_HEAD  = popup_common.fonts.FONT_HEAD
-- module configuration; override via M.configure{...} before first use
local CFG = {
    content_w = dpi(240),
}
-- sdr-white slider bounds for HDR outputs, in nits (PQ reference is 203)
local NITS_MIN, NITS_MAX = 80, 600



local M = {}

function M.configure(opts) style.merge(CFG, opts) end

local popup
-- holder table: draggable_header reads popup from here so build_content can
-- run before the awful.popup is constructed (awful.popup requires a widget arg)
local popup_holder = {}
local display_rows = {}
local refresh_popup  -- forward declaration (used by make_refresh_button before definition)
-- forward declarations: `hide` is referenced by the draggable_header
-- controller before assignment; `ctrl` is built in build_content once the
-- popup exists
local hide
local ctrl
-- active debounce timers from slider rows; stopped on hide/rebuild (B27)
local active_send_timers = {}


-- MARK: DAEMON COMMUNICATION

local function get_sock_path()
    local f = io.popen("id -u 2>/dev/null")
    local uid = f and f:read("*l") or "1000"
    if f then f:close() end
    return "/tmp/wlr-brightnessd-" .. uid .. ".sock"
end

local BRIGHTNESSD_SOCK = get_sock_path()


-- MARK: WIDGETS

local make_text = popup_common.make_text

local function separator()
    return popup_common.separator(CFG.content_w)
end

local function make_refresh_button()
    local txt = wibox.widget {
        text  = "Reapply Gamma",
        fg    = COLOR_WHITE,
        font  = FONT,
        widget = wibox.widget.textbox,
    }
    local bg = wibox.widget {
        {
            txt,
            halign = "center",
            valign = "center",
            fill_horizontal = true,
            widget = wibox.container.place,
        },
        forced_width = CFG.content_w,
        bg = COLOR_BLACK,
        fg = COLOR_WHITE,
        widget = wibox.container.background,
    }
    bg:connect_signal("mouse::enter", function() bg.bg = COLOR_HOVER end)
    bg:connect_signal("mouse::leave", function() bg.bg = COLOR_BLACK end)
    bg:buttons(gears.table.join(awful.button({}, 1, function()
        awful.spawn.easy_async(
            string.format("echo reapply | socat - UNIX-CONNECT:%s 2>/dev/null", BRIGHTNESSD_SOCK),
            guarded(function()
                refresh_popup()
            end)
        )
    end)))
    return bg
end

-- caffeine-style manual idle inhibit: awesome.idle_inhibit suppresses all
-- idle timeouts (screensaver + DPMS) while set. The label tracks the toggle;
-- protocol inhibitors (e.g. video players) are reported by the daemon's own
-- mechanism and don't affect this button's state.
local function make_inhibit_button()
    local txt = wibox.widget {
        text  = "Stay Awake: off",
        fg    = COLOR_GREY,
        font  = FONT,
        widget = wibox.widget.textbox,
    }
    local function refresh_label()
        local on = awesome.idle_inhibit
        txt.text = "Stay Awake: " .. (on and "on" or "off")
        txt.fg = on and COLOR_GREEN or COLOR_GREY
    end
    local bg = wibox.widget {
        {
            txt,
            halign = "center",
            valign = "center",
            fill_horizontal = true,
            widget = wibox.container.place,
        },
        forced_width = CFG.content_w,
        bg = COLOR_BLACK,
        fg = COLOR_WHITE,
        widget = wibox.container.background,
    }
    bg:connect_signal("mouse::enter", function() bg.bg = COLOR_HOVER end)
    bg:connect_signal("mouse::leave", function() bg.bg = COLOR_BLACK end)
    bg:buttons(gears.table.join(awful.button({}, 1, function()
        awesome.idle_inhibit = not awesome.idle_inhibit
        refresh_label()
    end)))
    awesome.connect_signal("property::idle_inhibited", refresh_label)
    refresh_label()
    return bg
end

-- trigger the screensaver immediately; the module is already loaded by
-- rc.lua so this is the same code path as the idle timeout firing
local function make_saver_button()
    local txt = wibox.widget {
        text  = "Screensaver Now",
        fg    = COLOR_WHITE,
        font  = FONT,
        widget = wibox.widget.textbox,
    }
    local bg = wibox.widget {
        {
            txt,
            halign = "center",
            valign = "center",
            fill_horizontal = true,
            widget = wibox.container.place,
        },
        forced_width = CFG.content_w,
        bg = COLOR_BLACK,
        fg = COLOR_WHITE,
        widget = wibox.container.background,
    }
    bg:connect_signal("mouse::enter", function() bg.bg = COLOR_HOVER end)
    bg:connect_signal("mouse::leave", function() bg.bg = COLOR_BLACK end)
    bg:buttons(gears.table.join(awful.button({}, 1, function()
        hide()
        require("plugins.screensaver").preview()
    end)))
    return bg
end

-- saver delay presets: runtime re-registration of the "screensaver" idle
-- timeout (nil disables the saver stage; DPMS is unaffected)
local SAVER_PRESETS = {
    { label = "5m",  secs = 300 },
    { label = "15m", secs = 900 },
    { label = "30m", secs = 1800 },
    { label = "1h",  secs = 3600 },
    { label = "off", secs = nil },
}

local function make_saver_timeout_row()
    local saver = require("plugins.screensaver")
    local entries = {}
    local function refresh_labels()
        for _, e in ipairs(entries) do
            e.txt.fg = (e.secs == saver.saver_timeout) and COLOR_GREEN or COLOR_GREY
        end
    end
    local row = wibox.widget {
        layout  = wibox.layout.flex.horizontal,
        spacing = style.spacing.xxs,
    }
    for _, p in ipairs(SAVER_PRESETS) do
        local txt = wibox.widget {
            text   = p.label,
            fg     = COLOR_GREY,
            font   = FONT,
            widget = wibox.widget.textbox,
        }
        local bg = wibox.widget {
            {
                txt,
                halign = "center",
                valign = "center",
                fill_horizontal = true,
                widget = wibox.container.place,
            },
            bg = COLOR_BLACK,
            fg = COLOR_WHITE,
            widget = wibox.container.background,
        }
        bg:connect_signal("mouse::enter", function() bg.bg = COLOR_HOVER end)
        bg:connect_signal("mouse::leave", function() bg.bg = COLOR_BLACK end)
        bg:buttons(gears.table.join(awful.button({}, 1, function()
            saver.set_saver_timeout(p.secs)
            refresh_labels()
        end)))
        entries[#entries + 1] = { secs = p.secs, txt = txt }
        row:add(bg)
    end
    refresh_labels()
    return wibox.widget {
        {
            {
                make_text("Screensaver Delay", COLOR_WHITE, FONT_HEAD),
                row,
                layout = wibox.layout.fixed.vertical,
                spacing = style.spacing.xs,
            },
            left = style.spacing.m, right = style.spacing.m,
            top = style.spacing.s, bottom = style.spacing.s,
            widget = wibox.container.margin,
        },
        forced_width = CFG.content_w,
        bg = COLOR_BLACK,
        widget = wibox.container.background,
    }
end


-- MARK: DISPLAY ROWS

local function build_content()
    -- header (title drag handle + detach + pin) and the detach/drag controller
    -- come from popup_common so this popup can float and be dragged like the
    -- rest of the wibar popups
    local header
    header, ctrl = popup_common.draggable_header {
        holder = popup_holder,
        name  = "brightness_popup",
        title = "Displays",
        width = CFG.content_w,
        hide  = function() hide() end,
    }

    local rows_container = wibox.widget {
        layout = wibox.layout.fixed.vertical,
        spacing = style.spacing.xxs,
    }

    local refresh_btn = make_refresh_button()
    local inhibit_btn = make_inhibit_button()
    local saver_btn   = make_saver_button()
    local saver_row   = make_saver_timeout_row()

    return wibox.widget {
        header,
        {
            rows_container,
            top = style.spacing.l, bottom = style.spacing.l,
            left = style.spacing.xl, right = style.spacing.xl,
            widget = wibox.container.margin,
        },
        separator(),
        refresh_btn,
        separator(),
        inhibit_btn,
        separator(),
        saver_btn,
        separator(),
        saver_row,
        layout = wibox.layout.fixed.vertical,
    }, rows_container, refresh_btn
end


-- MARK: REFRESH

local function get_display_info(callback)
    -- gather: output list from somewm, per-device backlight pct from
    -- brightnessctl -l -m, and daemon per-output status (gamma_size, failed,
    -- ready, no_brightness, brightness) from the socket
    local info = {}

    awful.spawn.easy_async("somewm-client output list", guarded(function(out)
        local seen = {}
        for line in (out or ""):gmatch("[^\r\n]+") do
            local name = line:match('name="([^"]+)"')
            if name and not seen[name] then
                seen[name] = true
                info[#info + 1] = { name = name }
            end
        end

        -- backlight devices (class "backlight" only) with their percentages
        awful.spawn.easy_async("brightnessctl -l -m 2>/dev/null", guarded(function(bout)
            local bl_devices = {}
            for line in (bout or ""):gmatch("[^\r\n]+") do
                local device, class, pct = line:match("^([^,]+),([^,]+),[^,]+,(%d+)%%")
                if device and class == "backlight" then
                    bl_devices[#bl_devices + 1] = { name = device, pct = tonumber(pct) }
                end
            end

            -- get daemon brightness (global default) and per-output status
            awful.spawn.easy_async_with_shell(
                string.format(
                    "echo 'get_brightness' | socat - UNIX-CONNECT:%s 2>/dev/null; echo '---'; echo 'status' | socat - UNIX-CONNECT:%s 2>/dev/null",
                    BRIGHTNESSD_SOCK, BRIGHTNESSD_SOCK),
                guarded(function(dout)
                    local daemon_brightness = 100
                    local status_map = {}

                    if dout then
                        local parts = {}
                        for p in dout:gmatch("[^\r\n]+") do
                            parts[#parts + 1] = p
                        end
                        -- first line is the global brightness value
                        if parts[1] and parts[1]:match("^%d+$") then
                            daemon_brightness = tonumber(parts[1])
                        end
                        -- after "---" are per-output status lines
                        for i = 3, #parts do
                            local name, gs, failed, ready, nobr, br = parts[i]:match(
                                "^(%S+): gamma_size=(%d+) failed=(%d+) ready=(%d+) no_brightness=(%d+) brightness=(%d+)")
                            if name then
                                status_map[name] = {
                                    gamma_size = tonumber(gs),
                                    failed = tonumber(failed),
                                    ready = tonumber(ready),
                                    no_brightness = tonumber(nobr),
                                    brightness = tonumber(br),
                                }
                            end
                        end
                    end

                    -- output objects keyed by name: an HDR output's slider
                    -- drives its SDR white level in nits (output.sdr_white)
                    -- instead of a gamma ramp, which is meaningless in PQ
                    local out_by_name = {}
                    for i = 1, capi_output.count() do
                        local o = capi_output[i]
                        if o and o.valid and o.name then out_by_name[o.name] = o end
                    end

                    -- assemble per-display info
                    local bl_idx = 1
                    for _, d in ipairs(info) do
                        local st = status_map[d.name] or {}
                        d.gamma_failed = st.failed == 1
                        d.gamma_ready = st.ready == 1
                        d.no_brightness = st.no_brightness == 1
                        if d.no_brightness then
                            -- hardware backlight: map to a backlight device by
                            -- index (laptops typically have a single one) and
                            -- read its percentage from brightnessctl
                            local dev = bl_devices[bl_idx]
                            bl_idx = bl_idx + 1
                            d.bl_device = dev and dev.name
                            d.brightness = (dev and dev.pct) or 100
                            d.source = "backlight"
                        else
                            -- software dimming: per-output brightness from the
                            -- daemon status, falling back to the global value
                            d.brightness = st.brightness or daemon_brightness
                            d.source = "gamma"
                        end
                        local o = out_by_name[d.name]
                        if o and o.hdr and type(o.sdr_white) == "number" then
                            d.output = o
                            d.hdr = true
                            d.source = "sdr-white"
                            d.brightness = math.floor(o.sdr_white + 0.5)
                        end
                    end

                    callback(info)
                end)
            )
        end))
    end))
end


local rows_container_ref
local refresh_btn_ref

-- apply a brightness percentage to a single display.
-- gamma outputs go through wlr-brightnessd's per-output command; backlight
-- outputs are set directly via brightnessctl on their mapped device.
local function set_display_brightness(d, pct)
    if d.hdr and d.output then
        pcall(function()
            d.output.sdr_white = math.max(NITS_MIN, math.min(NITS_MAX, pct))
        end)
        return
    end
    pct = math.max(1, math.min(100, pct))
    if d.source == "gamma" then
        awful.spawn.with_shell(string.format(
            "echo 'set_brightness %s %d' | socat - UNIX-CONNECT:%s 2>/dev/null",
            d.name, pct, BRIGHTNESSD_SOCK))
    elseif d.bl_device then
        awful.spawn.easy_async({ "brightnessctl", "-d", d.bl_device, "set", pct .. "%" })
    end
end

function refresh_popup(on_done)
    if not rows_container_ref then return end
    for _, t in ipairs(active_send_timers) do t:stop() end
    active_send_timers = {}
    rows_container_ref:reset()

    get_display_info(guarded(function(info)
        if #info == 0 then
            rows_container_ref:add(make_text("No displays found", COLOR_GREY))
            if on_done then on_done() end
            return
        end

        local sliders = {}
        local individual_rows = {}

        for _, d in ipairs(info) do
            local name_text = wibox.widget {
                text  = d.name,
                fg    = COLOR_WHITE,
                font  = FONT_HEAD,
                widget = wibox.widget.textbox,
            }

            local pct_color = d.gamma_failed and COLOR_RED or COLOR_GOLD
            local pct_text = wibox.widget {
                text  = d.brightness .. (d.hdr and " nits" or "%"),
                fg    = pct_color,
                font  = popup_common.fonts.FONT_VALUE,
                widget = wibox.widget.textbox,
            }

            local source_text = wibox.widget {
                text  = d.source,
                fg    = COLOR_GREY,
                font  = popup_common.fonts.FONT_SMALL,
                widget = wibox.widget.textbox,
            }

            local status_text = wibox.widget {
                text  = d.gamma_failed and " (gamma failed)" or "",
                fg    = COLOR_RED,
                font  = popup_common.fonts.FONT_SMALL,
                widget = wibox.widget.textbox,
            }

            local header = wibox.widget {
                {
                    {
                        name_text,
                        source_text,
                        status_text,
                        layout = wibox.layout.fixed.horizontal,
                        spacing = style.spacing.s,
                    },
                    forced_width = dpi(120),
                    widget = wibox.container.background,
                },
                pct_text,
                layout = wibox.layout.fixed.horizontal,
            }

            local slider = wibox.widget {
                bar_shape           = gshape.rounded_rect,
                bar_height          = dpi(3),
                bar_color           = COLOR_PURPLE,
                handle_shape        = gshape.circle,
                handle_width        = dpi(12),
                handle_height       = dpi(12),
                handle_color        = COLOR_WHITE,
                handle_border_width = style.popup.border_width,
                handle_border_color = COLOR_PURPLE,
                min   = d.hdr and NITS_MIN or 1,
                max   = d.hdr and NITS_MAX or 100,
                value = d.brightness,
                -- slider:fit() returns the full available height, so without a
                -- forced height the popup would grow to the whole workarea
                forced_width  = CFG.content_w - 2 * style.popup.margin_x,
                forced_height = dpi(14),
                widget = wibox.widget.slider,
            }
            slider._d = d

            -- debounce the actual hardware/daemon write so dragging the handle
            -- only fires one command after the user pauses
            local pending_val
            local send_timer = gears.timer {
                timeout     = 0.15,
                single_shot = true,
                autostart   = false,
                callback    = function()
                    if pending_val then set_display_brightness(d, pending_val) end
                end,
            }
            active_send_timers[#active_send_timers + 1] = send_timer
            local function row_clamp(v)
                v = math.floor(v + 0.5)
                return d.hdr and math.max(NITS_MIN, math.min(NITS_MAX, v))
                    or math.max(1, math.min(100, v))
            end
            slider:connect_signal("property::value", function(_, val)
                val = row_clamp(val)
                pending_val = val
                pct_text.text = val .. (d.hdr and " nits" or "%")
                send_timer:stop()
                send_timer:start()
            end)

            -- mouse wheel over the slider nudges the value by STEP; setting
            -- .value reuses the property::value handler above so the write is
            -- debounced just like dragging the handle
            local STEP = d.hdr and 10 or 5
            slider:buttons(gears.table.join(
                awful.button({}, 4, function()
                    slider.value = row_clamp(slider.value) + STEP
                end),
                awful.button({}, 5, function()
                    slider.value = row_clamp(slider.value) - STEP
                end)
            ))

            local row = wibox.widget {
                header,
                slider,
                layout = wibox.layout.fixed.vertical,
                spacing = style.spacing.s,
            }

            local row_bg = wibox.widget {
                {
                    row,
                    left = style.spacing.m, right = style.spacing.m,
                    top = style.spacing.s, bottom = style.spacing.s,
                    widget = wibox.container.margin,
                },
                forced_width = CFG.content_w,
                bg = COLOR_BLACK,
                widget = wibox.container.background,
            }

            -- hdr rows stay out of the combined slider: a percent value is
            -- meaningless as a nits level
            if not d.hdr then sliders[#sliders + 1] = slider end
            individual_rows[#individual_rows + 1] = row_bg
        end

        -- combined "All Displays" slider: moving it sets every individual
        -- slider at once; each individual slider's property::value handler
        -- then debounces its own hardware/daemon write, so no separate
        -- command is needed here. only percent rows take part — hdr rows
        -- carry nits
        if #sliders == 0 then
            for _, r in ipairs(individual_rows) do
                rows_container_ref:add(r)
            end
            if on_done then on_done() end
            return
        end
        local function clamp_round(v)
            return math.max(1, math.min(100, math.floor(v + 0.5)))
        end

        local all_pct = wibox.widget {
            text  = "",
            fg    = COLOR_GOLD,
            font  = popup_common.fonts.FONT_VALUE,
            widget = wibox.widget.textbox,
        }
        local all_header = wibox.widget {
            {
                make_text("All Displays", COLOR_WHITE, FONT_HEAD),
                forced_width = dpi(120),
                widget = wibox.container.background,
            },
            all_pct,
            layout = wibox.layout.fixed.horizontal,
        }
        local all_slider = wibox.widget {
            bar_shape           = gshape.rounded_rect,
            bar_height          = dpi(3),
            bar_color           = COLOR_PURPLE,
            handle_shape        = gshape.circle,
            handle_width        = dpi(12),
            handle_height       = dpi(12),
            handle_color        = COLOR_WHITE,
            handle_border_width = style.popup.border_width,
            handle_border_color = COLOR_PURPLE,
            min   = 1,
            max   = 100,
            forced_width  = CFG.content_w - 2 * style.popup.margin_x,
            forced_height = dpi(14),
            widget = wibox.widget.slider,
        }
        -- initial value = rounded average of the individual displays
        local sum = 0
        for _, s in ipairs(sliders) do sum = sum + s.value end
        all_slider.value = clamp_round(sum / #sliders)
        all_pct.text = all_slider.value .. "%"

        all_slider:connect_signal("property::value", function(_, val)
            val = clamp_round(val)
            all_pct.text = val .. "%"
            for _, s in ipairs(sliders) do
                s.value = val
            end
        end)
        local ALL_STEP = 5
        all_slider:buttons(gears.table.join(
            awful.button({}, 4, function()
                all_slider.value = clamp_round(all_slider.value) + ALL_STEP
            end),
            awful.button({}, 5, function()
                all_slider.value = clamp_round(all_slider.value) - ALL_STEP
            end)
        ))

        local all_row = wibox.widget {
            all_header,
            all_slider,
            layout = wibox.layout.fixed.vertical,
            spacing = style.spacing.s,
        }
        local all_row_bg = wibox.widget {
            {
                all_row,
                left = style.spacing.m, right = style.spacing.m,
                top = style.spacing.s, bottom = style.spacing.s,
                widget = wibox.container.margin,
            },
            forced_width = CFG.content_w,
            bg = COLOR_BLACK,
            widget = wibox.container.background,
        }

        rows_container_ref:add(all_row_bg)
        rows_container_ref:add(separator())
        for _, r in ipairs(individual_rows) do
            rows_container_ref:add(r)
        end

        if on_done then on_done() end
    end))
end


-- MARK: POPUP

local function ensure_popup()
    if popup then return end
    local pstyle = popup_common.popup_style()
    -- build content first so the awful.popup constructor gets its required
    -- widget arg; draggable_header reads popup via popup_holder, assigned
    -- right after construction
    local content, rc, rb = build_content()
    rows_container_ref = rc
    refresh_btn_ref = rb
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

hide = function()
    if not popup then return end
    for _, t in ipairs(active_send_timers) do t:stop() end
    popup_common.hide(popup)
end

local function show(anchor)
    ensure_popup()
    if popup.visible or popup._showing then return end
    ctrl.set_anchor(anchor)
    -- emit before setting _showing: the signal fires every registered closer
    -- synchronously, including this popup's own hide — popup_common.hide
    -- clears _showing unconditionally, so emitting after the set would make
    -- the async refresh callback bail before show_placement ever runs
    awesome.emit_signal("popup::opening")
    popup._showing = true
    -- build rows first, then size + place + reveal. placing before the async
    -- rows arrive would anchor an empty popup that then grows downward off
    -- the bottom of the screen once the (now taller) rows are added
    refresh_popup(function()
        if not popup._showing then return end
        popup_common.show_placement(popup, anchor, ctrl.show_opts())
        popup._showing = false
    end)
end

local function toggle(anchor)
    ensure_popup()
    ctrl.toggle(anchor, show)
end


-- MARK: ATTACH

-- Wire left-click toggle (and right-click dismiss) on a brightness widget.
-- Uses connect_signal so existing scroll buttons (4/5) are preserved.
-- Safe to call once per screen; all widgets share the single popup.
function M.attach(widget)
    ensure_popup()
    popup_common.attach(popup, widget, toggle, { right_hide = hide })
end

-- whether the popup is currently on screen (used by plugins.brightness to
-- suppress the OSD notification while the popup is showing live values)
function M.is_visible()
    return popup and popup.visible or false
end

-- re-read display info and rebuild the popup rows
M.refresh = refresh_popup

-- close this popup when any other popup opens
popup_common.register_closer(hide)


return M
