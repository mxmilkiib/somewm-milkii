-- plugins/volume_popup.lua
-- Clickable popup anchored to the wibar volume widget. Lists all PipeWire
-- sinks (outputs) and sources (inputs) with individual volume sliders and
-- mute toggles. Uses wpctl for all volume operations.
--
-- One shared popup is created lazily and re-anchored to whichever volume
-- widget is clicked (the wibar is built per-screen).

local awful   = require("awful")
local gears   = require("gears")
local wibox   = require("wibox")
local beautiful = require("beautiful")
local gshape  = require("gears.shape")
local gtable  = require("gears.table")
local guarded = require("error_guard")
local popup_common = require("plugins.popup_common")

local dpi = beautiful.xresources.apply_dpi

local COLOR_PURPLE = popup_common.theme.PURPLE
local COLOR_BLACK  = popup_common.theme.BLACK
local COLOR_WHITE  = popup_common.theme.WHITE
local COLOR_GOLD   = popup_common.theme.GOLD
local COLOR_GREY   = popup_common.theme.GREY
local COLOR_RED    = popup_common.theme.RED
local FONT       = popup_common.fonts.FONT
local FONT_HEAD  = popup_common.fonts.FONT_HEAD
local CONTENT_W  = dpi(440)

local M = {}

local popup
local rows_container_ref
local refresh_popup  -- forward declaration (used by make_slider_row before definition)
-- forward declaration: the pin toggle's click callback (built inside
-- build_content) needs this bound as an upvalue
local hide
local is_pinned  -- getter set in build_content (see popup_common.pin)
-- active debounce timers from slider rows; stopped on hide/rebuild (B27)
local active_send_timers = {}
-- refs to the default-sink row's slider + pct, refreshed whenever the popup
-- rebuilds; used to update that row in place on volume::updated (e.g. when
-- scrolling the wibar icon) without a full popup rebuild
local default_sink_view


-- MARK: WIDGETS

local make_text = popup_common.make_text

local function separator()
    return popup_common.separator(CONTENT_W)
end

local function section_label(text)
    return wibox.widget {
        {
            make_text(text, COLOR_GREY, FONT_HEAD),
            left = dpi(6), right = dpi(6),
            top = dpi(4), bottom = dpi(2),
            widget = wibox.container.margin,
        },
        forced_width = CONTENT_W,
        widget = wibox.container.background,
    }
end


-- MARK: VOLUME PARSING

-- parse `wpctl status` output into sinks and sources tables.
-- each device: { id, name, vol (0-1+), muted, is_default }
local function parse_devices(stdout)
    local sinks, sources = {}, {}
    local current = nil
    for line in stdout:gmatch("[^\r\n]+") do
        if line:match("Sinks:") then
            current = sinks
        elseif line:match("Sources:") then
            current = sources
        elseif line:match("Filters:") or line:match("Streams:") then
            current = nil
        elseif current then
            local star, id, name, vol, rest = line:match("^%s*│%s*(%*?)%s*(%d+)%.(.-)%[vol:%s*([%d%.]+)%s*(.-)%]")
            if id then
                current[#current + 1] = {
                    id = tonumber(id),
                    name = name:gsub("^%s+", ""):gsub("%s+$", ""),
                    vol = tonumber(vol) or 0,
                    muted = rest and rest:find("MUTED") ~= nil,
                    is_default = star == "*",
                }
            end
        end
    end
    return sinks, sources
end


-- MARK: SLIDER ROW

local function make_slider_row(device, device_type)
    -- device_type: "sink" or "source" (wpctl set-default works for both)
    local name = wibox.widget {
        text = device.name,
        fg = device.is_default and COLOR_GOLD or COLOR_WHITE,
        font = FONT,
        align = "left",
        valign = "center",
        ellipsize = "end",
        forced_width = dpi(280),
        widget = wibox.widget.textbox,
    }

    -- clicking name sets this device as the default
    name:buttons(gears.table.join(awful.button({}, 1, function()
        awful.spawn.easy_async({ "wpctl", "set-default", tostring(device.id) }, guarded(function()
            refresh_popup()
        end))
    end)))

    -- compact star toggle: gold ★ for the current default, dim ☆ for others;
    -- click to set as default
    local star = wibox.widget {
        text = device.is_default and "★" or "☆",
        fg = device.is_default and COLOR_GOLD or COLOR_GREY,
        font = popup_common.fonts.FONT_STAR,
        valign = "center",
        widget = wibox.widget.textbox,
    }
    star:buttons(gears.table.join(awful.button({}, 1, function()
        if not device.is_default then
            awful.spawn.easy_async({ "wpctl", "set-default", tostring(device.id) }, guarded(function()
                refresh_popup()
            end))
        end
    end)))
    if not device.is_default then
        star:connect_signal("mouse::enter", function() star.fg = COLOR_GOLD end)
        star:connect_signal("mouse::leave", function() star.fg = COLOR_GREY end)
    end

    local pct = wibox.widget {
        text = math.floor(device.vol * 100 + 0.5) .. "%",
        fg = device.muted and COLOR_GREY or COLOR_GOLD,
        font = popup_common.fonts.FONT_VALUE,
        align = "right",
        valign = "center",
        widget = wibox.widget.textbox,
    }

    local mute_btn = wibox.widget {
        text = device.muted and "Muted" or "Mute",
        fg = device.muted and COLOR_RED or COLOR_WHITE,
        font = FONT,
        valign = "center",
        widget = wibox.widget.textbox,
    }
    local function toggle_mute()
        awful.spawn.easy_async({ "wpctl", "set-mute", tostring(device.id), "toggle" }, guarded(function()
            if device.is_default and device_type == "sink" then
                awesome.emit_signal("volume::updated",
                    math.floor(device.vol * 100 + 0.5), not device.muted)
            end
            refresh_popup()
        end))
    end
    mute_btn:buttons(gears.table.join(awful.button({}, 1, toggle_mute)))

    local header = wibox.widget {
        name,
        nil,
        {
            mute_btn,
            pct,
            star,
            spacing = dpi(6),
            layout = wibox.layout.fixed.horizontal,
        },
        layout = wibox.layout.align.horizontal,
    }

    local slider = wibox.widget {
        bar_shape           = gshape.rounded_rect,
        bar_height          = dpi(3),
        bar_color           = device.muted and COLOR_GREY or COLOR_PURPLE,
        handle_shape        = gshape.circle,
        handle_width        = dpi(12),
        handle_height       = dpi(12),
        handle_color        = COLOR_WHITE,
        handle_border_width = dpi(1),
        handle_border_color = COLOR_PURPLE,
        min   = 0,
        max   = 150,
        value = math.min(150, math.floor(device.vol * 100 + 0.5)),
        forced_width  = CONTENT_W - dpi(20),
        forced_height = dpi(14),
        widget = wibox.widget.slider,
    }

    -- debounce volume writes so dragging the handle doesn't spawn a command
    -- per pixel; the timer fires 0.3s after the last movement
    local send_timer
    local pending_vol
    -- when true, property::value updates the display only and skips the
    -- debounced wpctl write (used for programmatic updates from volume::updated,
    -- which already reflect a volume change made elsewhere)
    local programmatic = false
    slider:connect_signal("property::value", function(_, val)
        pct.text = val .. "%"
        pct.fg = COLOR_GOLD
        if programmatic then return end
        pending_vol = val / 100
        if not send_timer then
            send_timer = gears.timer {
                timeout = 0.3, single_shot = true, autostart = false,
                callback = function()
                    if pending_vol then
                        awful.spawn.easy_async(
                            { "wpctl", "set-volume", "-l", "1.5", tostring(device.id), string.format("%.2f", pending_vol) },
                            guarded(function()
                                if device.is_default and device_type == "sink" then
                                    awesome.emit_signal("volume::updated",
                                        math.floor(pending_vol * 100 + 0.5), device.muted)
                                end
                            end)
                        )
                        pending_vol = nil
                    end
                end,
            }
            active_send_timers[#active_send_timers + 1] = send_timer
        end
        send_timer:stop()
        send_timer:start()
    end)

    -- mouse wheel nudges the value by 5%; setting .value reuses the
    -- property::value handler so the write is debounced just like dragging
    slider:buttons(gears.table.join(
        awful.button({}, 4, function()
            slider.value = math.min(150, math.floor(slider.value + 0.5) + 5)
        end),
        awful.button({}, 5, function()
            slider.value = math.max(0, math.floor(slider.value + 0.5) - 5)
        end)
    ))

    -- expose the default-sink row for in-place updates from volume::updated
    if device.is_default and device_type == "sink" then
        default_sink_view = {
            slider = slider,
            pct = pct,
            set_programmatic = function(v) programmatic = v end,
        }
    end

    local row = wibox.widget {
        header,
        slider,
        layout = wibox.layout.fixed.vertical,
        spacing = dpi(4),
    }

    local row_container = wibox.widget {
        {
            row,
            left = dpi(6), right = dpi(6),
            top = dpi(4), bottom = dpi(4),
            widget = wibox.container.margin,
        },
        forced_width = CONTENT_W,
        bg = COLOR_BLACK,
        widget = wibox.container.background,
    }
    -- middle-click anywhere on the row toggles mute for this device
    row_container:buttons(gears.table.join(awful.button({}, 2, toggle_mute)))
    return row_container
end


-- MARK: REFRESH

function refresh_popup(on_done)
    if not rows_container_ref then if on_done then on_done() end return end
    for _, t in ipairs(active_send_timers) do t:stop() end
    active_send_timers = {}
    default_sink_view = nil
    rows_container_ref:reset()

    awful.spawn.easy_async({ "wpctl", "status" }, guarded(function(out)
        local sinks, sources = parse_devices(out or "")

        if #sinks > 0 then
            rows_container_ref:add(section_label("Output"))
            for _, d in ipairs(sinks) do
                rows_container_ref:add(make_slider_row(d, "sink"))
            end
        end

        if #sinks > 0 and #sources > 0 then
            rows_container_ref:add(separator())
        end

        if #sources > 0 then
            rows_container_ref:add(section_label("Input"))
            for _, d in ipairs(sources) do
                rows_container_ref:add(make_slider_row(d, "source"))
            end
        end

        if #sinks == 0 and #sources == 0 then
            rows_container_ref:add(make_text("No audio devices", COLOR_GREY))
        end

        if on_done then on_done() end
    end))
end


-- MARK: POPUP

local function build_content()
    -- pin toggle at the right of the header: gold = stays open on outside
    -- clicks, grey = any outside click closes it
    local pin_btn, pinned = popup_common.pin("volume_popup", function(on)
        if popup and popup.visible then
            if on then popup_common.outside_click_teardown(popup)
            else popup_common.outside_click_setup(popup, hide, true) end
        end
    end)
    is_pinned = pinned

    local header = wibox.widget {
        {
            {
                make_text("Volume", COLOR_WHITE, FONT_HEAD),
                nil,
                pin_btn,
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

    local rows_container = wibox.widget {
        layout = wibox.layout.fixed.vertical,
        spacing = dpi(2),
    }

    return wibox.widget {
        header,
        {
            rows_container,
            top = dpi(8), bottom = dpi(8),
            left = dpi(10), right = dpi(10),
            widget = wibox.container.margin,
        },
        layout = wibox.layout.fixed.vertical,
    }, rows_container
end

local function ensure_popup()
    if popup then return end
    local content, rc = build_content()
    rows_container_ref = rc
    local style = popup_common.popup_style()
    popup = awful.popup {
        widget   = content,
        visible  = false,
        ontop    = true,
        bg       = COLOR_BLACK,
        border_width = style.border_width,
        border_color = COLOR_GOLD,
        shape = style.shape,
    }
end

hide = function()
    if not popup then return end
    for _, t in ipairs(active_send_timers) do t:stop() end
    popup_common.hide(popup)
end

local function show(anchor)
    ensure_popup()
    if popup.visible or popup._showing then return end
    popup._showing = true
    awesome.emit_signal("popup::opening")
    -- build rows first, then size + place + reveal. placing before the async
    -- rows arrive would anchor an empty popup that then grows downward off
    -- the bottom of the screen once the (now taller) rows are added
    refresh_popup(function()
        if not popup._showing then return end
        popup_common.show_placement(popup, anchor, {
            is_pinned = is_pinned, also_release = true, hide = hide,
        })
        popup._showing = false
    end)
end

local function toggle(anchor)
    ensure_popup()
    if popup.visible then hide() else show(anchor) end
end


-- MARK: ATTACH

-- Wire left-click toggle on a volume widget. Uses connect_signal so existing
-- scroll buttons (4/5) and middle-click mute are preserved.
-- Safe to call once per screen; all widgets share the single popup.
function M.attach(widget)
    ensure_popup()
    popup_common.attach(popup, widget, toggle, {
        right_hide = hide, swallow_scroll = true,
    })
end

function M.is_visible()
    return popup and popup.visible or false
end

-- nudge the default-sink slider directly when scrolling the wibar icon while
-- the popup is open. bypasses volume_osd's 3-async-call chain (get → set → get
-- → signal) for a synchronous update: the slider's own debounced property::value
-- handler writes to wpctl 0.3s after the last scroll, so the bar moves
-- instantly with no async jitter
function M.scroll_default(direction)
    if not popup or not popup.visible or not default_sink_view then return end
    local slider = default_sink_view.slider
    local step = 5
    if direction > 0 then
        slider.value = math.min(150, math.floor(slider.value + 0.5) + step)
    else
        slider.value = math.max(0, math.floor(slider.value + 0.5) - step)
    end
end

M.refresh = refresh_popup

-- close this popup when any other popup opens
popup_common.register_closer(hide)

-- update the default-sink slider in place when the volume changes elsewhere
-- (e.g. scrolling the wibar icon or pressing volume keys) so the open popup
-- reflects the new level without a full rebuild
awesome.connect_signal("volume::updated", guarded(function(pct, muted)
    if not popup or not popup.visible or not default_sink_view then return end
    local view = default_sink_view
    view.set_programmatic(true)
    view.slider.value = math.min(150, math.max(0, pct))
    view.set_programmatic(false)
    view.pct.text = pct .. "%"
    view.pct.fg = muted and COLOR_GREY or COLOR_GOLD
    view.slider.bar_color = muted and COLOR_GREY or COLOR_PURPLE
end))


return M
