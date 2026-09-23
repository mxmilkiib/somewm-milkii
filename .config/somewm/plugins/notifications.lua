-- Modern notification display with shared-timer slide animation
-- Uses awful.popup for full placement control + naughty.widget.* for content
-- Slide-in animation uses a single shared gears.timer for all active animations
-- Stacking is manual (per-screen list) to anchor at the systray's left edge

local awful = require("awful")
local naughty = require("naughty")
local wibox = require("wibox")
local beautiful = require("beautiful")
local gears = require("gears")
local gtable = require("gears.table")
local gtimer = require("gears.timer")
local gdebug = require("gears.debug")
local gstring = require("gears.string")
local guarded = require("error_guard")
local font_utils = require("rc.font_utils")
local dpi = beautiful.xresources.apply_dpi
local COLOR_GOLD = (beautiful.main_gold and beautiful.main_gold.base) or "#FFD700"
local COLOR_PURPLE = (beautiful.main_purple and beautiful.main_purple.base) or "#623997"
local COLOR_BLACK  = "#000000"
local COLOR_WHITE  = "#FFFFFF"

local M = {}

-- Configuration
local SLIDE_DURATION = 0.3
local NOTIF_GAP = dpi(4)
local NOTIF_TOP_MARGIN = dpi(4)
local NOTIF_RIGHT_GAP = dpi(6)
local MAX_NOTIF_WIDTH = dpi(800)
local DEFAULT_TIMEOUT = 50

-- The title is differentiated by bold markup + gold background, not font size.
-- Use the theme font directly; the theme already handles DPI + ui_scale scaling.
-- local NOTIF_FONT = beautiful.notification_font or beautiful.font or "Sans 10"
-- Widget-Popup Fonts (same as the resource/battery/volume/displays popups)
local FONT           = font_utils.FONT
local FONT_HEAD      = font_utils.FONT_HEAD
-- local FONT_VALUE  = font_utils.FONT_BOLD  -- too large for the header sender
-- local FONT_COUNTDOWN = font_utils.FONT
-- local FONT_COUNTDOWN = font_utils.FONT_INFO
local FONT_COUNTDOWN = font_utils.FONT_SMALL

-- circle-phase glyphs for the header countdown (quarter steps, empty→full)
local TIMER_GLYPHS = { "○", "◔", "◑", "◕", "●" }


-- Per-screen active notification boxes (for manual stacking)
local screen_boxes = {}

-- Per-screen systray anchor cache
local systray_anchors = {}
local systray_anchor_stale = true


local wbase = require("wibox.widget.base")

-- // MARK --systray-anchor

-- Compute the left-edge x of the systray on a given screen by traversing
-- the wibar's widget tree and fitting each widget in the right section.
local function compute_systray_anchor(s)
    local wibar = s.mywibox
    if not wibar or not wibar.valid then return nil end
    local wg = wibar:geometry()
    local root = wibar.widget
    if not root then return nil end

    local children = root:get_children()
    if #children < 3 then return nil end

    local right_section = children[3]
    local right_children = right_section:get_children()

    local context = { dpi = beautiful.xresources.get_dpi() or 96 }
    local max_w, max_h = wg.width, wg.height

    local systray_found = false
    local width_after = 0
    local systray_w = 0

    for _, child in ipairs(right_children) do
        -- check if this widget contains the systray
        if not systray_found and s.mysystray then
            local function contains_systray(w)
                if w == s.mysystray then return true end
                local kids = w.get_children and w:get_children() or nil
                if kids then
                    for _, k in ipairs(kids) do
                        if contains_systray(k) then return true end
                    end
                end
                return false
            end
            if contains_systray(child) then
                local fw = wbase.fit_widget(right_section, context, child, max_w, max_h)
                systray_w = fw or 0
                systray_found = true
            end
        else
            local fw = wbase.fit_widget(right_section, context, child, max_w, max_h)
            width_after = width_after + (fw or 0)
        end
    end

    if not systray_found then return nil end

    -- systray left edge = wibar right edge - widgets after systray - systray width
    return wg.x + wg.width - width_after - systray_w
end

local function get_systray_anchor(s)
    if systray_anchor_stale or not systray_anchors[s] then
        systray_anchors[s] = compute_systray_anchor(s)
        systray_anchor_stale = false
    end
    return systray_anchors[s]
end

-- recompute anchors on screen geometry changes
screen.connect_signal("property::geometry", guarded(function()
    systray_anchor_stale = true
    systray_anchors = {}
end))

-- cleanup on screen removal
screen.connect_signal("removed", guarded(function(s)
    systray_anchors[s] = nil
    screen_boxes[s] = nil
end))


-- // MARK --stacking

-- Reposition all active notification popups on a screen (top-down from wibar).
-- Skips entries currently animating so the slide-in doesn't fight with reflow.
local function reflow(s)
    local boxes = screen_boxes[s]
    if not boxes then return end
    local wibar = s.mywibox
    local wibar_h = (wibar and wibar.valid and wibar:geometry().height) or 0
    -- include screen y offset for correct multi-screen stacking
    local y = s.geometry.y + wibar_h + NOTIF_TOP_MARGIN
    for i = #boxes, 1, -1 do
        local entry = boxes[i]
        if entry.popup and entry.popup.valid then
            if not entry.animating then
                local geo = entry.popup:geometry()
                entry.popup:geometry({ y = math.floor(y) })
            end
            local geo = entry.popup:geometry()
            y = y + geo.height + NOTIF_GAP
        end
    end
end

local function add_box(s, entry)
    if not screen_boxes[s] then screen_boxes[s] = {} end
    table.insert(screen_boxes[s], 1, entry)
    reflow(s)
end

local function remove_box(s, entry)
    local boxes = screen_boxes[s]
    if not boxes then return end
    for i, e in ipairs(boxes) do
        if e == entry then
            table.remove(boxes, i)
            break
        end
    end
    reflow(s)
end


-- // MARK --animation
-- old: a shared 60fps gears.timer stepped every active slide (see
--      ensure_anim_timer in git history).
-- new: somewm's native C frame clock via awesome.start_animation —
--      vsync-paced ticks, easing in C, and a :cancel() handle.

local anim_count = 0

local function slide_to(entry, popup, start_y, target_y)
    anim_count = anim_count + 1
    awesome.start_animation(SLIDE_DURATION, "ease-out-cubic",
        function(progress)
            if popup.valid then
                popup:geometry({ y = math.floor(start_y + (target_y - start_y) * progress) })
            end
        end,
        function()
            anim_count = anim_count - 1
            if entry and entry.popup and entry.popup.valid then
                entry.animating = false
                reflow(entry.screen)
            end
        end)
end


-- // MARK --widget-template

-- Widget-Popup Form (same as resource/battery/volume/displays popups):
-- Purple Header Bar (Title left, Sender + Countdown Glyph right in Gold),
-- Black Body (Icon left, Message filling the rest), Actions Section below.
local function build_widget(n, s)
    local icon_widget = wibox.widget {
        image = n.icon,
        resize = true,
        halign = "center",
        valign = "center",
        forced_width = dpi(36),
        forced_height = dpi(36),
        widget = wibox.widget.imagebox,
    }

    -- countdown indicator: unicode circle-phase glyph + seconds at text
    -- height, so the header stays one line tall like the widget popups
    -- (the old 28px arcchart forced the header to ~40px)
    local countdown_text = wibox.widget {
        markup = string.format("<span foreground='%s'>● %ds</span>",
            COLOR_GOLD, n.timeout or DEFAULT_TIMEOUT),
        font = FONT_COUNTDOWN,
        align = "center",
        valign = "center",
        widget = wibox.widget.textbox,
    }

    -- title: white bold text on the purple header bar
    local title_widget = wibox.widget {
        markup = "<b>" .. (n.title or "") .. "</b>",
        font = FONT_HEAD,
        align = "left",
        valign = "center",
        widget = wibox.widget.textbox,
    }

    -- sender: gold text in the header's right slot (widget-popup form),
    -- at info size so it doesn't outgrow the title like FONT_VALUE did
    local app_name_widget = wibox.widget {
        markup = "<span foreground='" .. COLOR_GOLD .. "'>"
            .. gstring.xml_escape(n.app_name or "") .. "</span>",
        font = font_utils.FONT_INFO,
        align = "right",
        valign = "center",
        widget = wibox.widget.textbox,
    }

    local title_bar = wibox.widget {
        {
            {
                title_widget,
                nil,
                {
                    app_name_widget,
                    (n.timeout or DEFAULT_TIMEOUT) > 5 and countdown_text or nil,
                    spacing = dpi(6),
                    layout = wibox.layout.fixed.horizontal,
                },
                layout = wibox.layout.align.horizontal,
            },
            left = dpi(10), right = dpi(10),
            top = dpi(6), bottom = dpi(6),
            widget = wibox.container.margin,
        },
        bg = COLOR_PURPLE,
        fg = COLOR_WHITE,
        widget = wibox.container.background,
    }

    local message_widget = wibox.widget {
        markup = n.message or n.text or "",
        font = FONT,
        align = "left",
        valign = "center",
        wrap = "word_char",
        widget = wibox.widget.textbox,
    }

    local actions_widget
    if n.actions and #n.actions > 0 then
        local action_buttons = {}
        for _, action in ipairs(n.actions) do
            table.insert(action_buttons, wibox.widget {
                {
                    {
                        text = action.name,
                        widget = wibox.widget.textbox,
                    },
                    halign = "center",
                    fill_horizontal = true,
                    widget = wibox.container.place,
                },
                forced_height = dpi(24),
                widget = wibox.container.background,
                bg = "#ffffff22",
                shape = function(cr, w, h)
                    gears.shape.rounded_rect(cr, w, h, beautiful.border_radius or dpi(3))
                end,
                buttons = {
                    awful.button({}, 1, function()
                        action:invoke()
                    end),
                },
            })
        end
        local actions_row = wibox.layout.flex.horizontal()
        actions_row.spacing = dpi(4)
        for _, btn in ipairs(action_buttons) do
            actions_row:add(btn)
        end
        -- actions get their own black Section under a Purple Separator
        actions_widget = wibox.widget {
            {
                {
                    forced_height = dpi(1),
                    bg = COLOR_PURPLE,
                    widget = wibox.container.background,
                },
                {
                    actions_row,
                    left = dpi(10), right = dpi(10),
                    top = dpi(4), bottom = dpi(6),
                    widget = wibox.container.margin,
                },
                layout = wibox.layout.fixed.vertical,
            },
            bg = COLOR_BLACK,
            fg = COLOR_WHITE,
            widget = wibox.container.background,
        }
    end

    -- body: icon left, message filling the remaining width
    local body = wibox.widget {
        {
            {
                {
                    icon_widget,
                    right = dpi(8),
                    widget = wibox.container.margin,
                },
                message_widget,
                nil,
                layout = wibox.layout.align.horizontal,
            },
            left = dpi(10), right = dpi(10),
            top = dpi(6), bottom = dpi(6),
            widget = wibox.container.margin,
        },
        bg = COLOR_BLACK,
        fg = COLOR_WHITE,
        widget = wibox.container.background,
    }

    local inner = wibox.widget {
        {
            title_bar,
            body,
            actions_widget,
            spacing = dpi(0),
            layout = wibox.layout.fixed.vertical,
        },
        bg = COLOR_BLACK,
        widget = wibox.container.background,
    }

    -- enforce 15% minimum screen width at the widget level so the popup
    -- is actually that wide (awful.popup sizes from its widget tree)
    local min_width = dpi(0)
    if s and s.valid then
        min_width = math.floor(s.geometry.width * 0.15)
    end
    local widget = wibox.widget {
        inner,
        strategy = "min",
        width = min_width,
        widget = wibox.container.constraint,
    }

    -- live-update title/message so in-flight OSD notifications (volume,
    -- brightness) that mutate n.message and emit property::message actually
    -- refresh the displayed bar instead of freezing on the first value
    n:connect_signal("property::message", guarded(function()
        message_widget:set_markup(n.message or n.text or "")
    end))
    n:connect_signal("property::text", guarded(function()
        message_widget:set_markup(n.message or n.text or "")
    end))
    n:connect_signal("property::title", guarded(function()
        title_widget:set_markup("<b>" .. (n.title or "") .. "</b>")
    end))

    return widget, countdown_text
end


-- // MARK --display

-- pick the screen the mouse cursor is on (falls back to focused, then primary)
local function pick_cursor_screen()
    local s = mouse.screen
    if s and s.valid then return s end
    s = awful.screen.focused()
    if s and s.valid then return s end
    return screen.primary
end

function M.display(n)
    local s = pick_cursor_screen()
    if not s or not s.valid then return end

    local widget, countdown_text = build_widget(n, s)

    local popup = awful.popup {
        widget = widget,
        screen = s,
        visible = false,
        ontop = true,
        type = "notification",
        bg = "#000000",
        fg = "#ffffff",
        -- border_width = 0,
        border_width = beautiful.bar_edge_width or beautiful.border_width or dpi(1),
        border_color = COLOR_GOLD,
        shape = function(cr, w, h)
            gears.shape.rounded_rect(cr, w, h, beautiful.border_radius or dpi(3))
        end,
        maximum_width = MAX_NOTIF_WIDTH,
    }

    -- set n.box so existing added-signal handler can access it
    n.box = popup

    -- popup-level buttons: left-click dismiss, right-click copy to clipboard
    local text_to_copy = ""
    if n.title and n.message then
        text_to_copy = n.title .. "\n" .. n.message
    elseif n.title then
        text_to_copy = n.title
    elseif n.message then
        text_to_copy = n.message
    end
    popup:buttons(gtable.join(
        awful.button({}, 1, function()
            n:destroy(naughty.notification_closed_reason.dismissed_by_user)
        end),
        awful.button({}, 3, function()
            if text_to_copy ~= "" then
                awful.spawn.with_shell("echo '" .. text_to_copy:gsub("'", "'\"'\"'") .. "' | wl-copy")
            end
            n:destroy(naughty.notification_closed_reason.silent)
        end)
    ))

    local entry = { popup = popup, notification = n }

    -- timeout handling
    local timeout = n.timeout or DEFAULT_TIMEOUT
    local timeout_timer
    local countdown_timer
    if timeout > 0 then
        -- countdown timer (updates the unicode phase glyph + seconds text)
        -- uses a tick counter instead of os.clock() (which measures CPU time,
        -- not wall time, and barely advances while awesome is idle)
        local arc_duration = timeout
        local arc_ticks = 0
        local ARC_RATE = 15
        countdown_timer = gtimer {
            timeout = 1 / ARC_RATE,
            autostart = false,
            callback = guarded(function()
                arc_ticks = arc_ticks + 1
                local elapsed = arc_ticks / ARC_RATE
                local remaining = math.max(0, 1 - elapsed / arc_duration)
                local glyph = TIMER_GLYPHS[math.floor(remaining * 4 + 0.5) + 1]
                local secs_left = math.ceil(remaining * arc_duration)
                countdown_text:set_markup(string.format(
                    "<span foreground='%s'>%s %ds</span>", COLOR_GOLD, glyph, secs_left))
                if remaining <= 0 then countdown_timer:stop() end
            end),
        }

        timeout_timer = gtimer {
            timeout = timeout,
            single_shot = true,
            autostart = false,
            callback = guarded(function()
                n:destroy(naughty.notification_closed_reason.expired)
            end),
        }

        -- OSD plugins (volume, brightness) call n:reset_timeout() to extend
        -- the popup on each scroll; restart our own timeout_timer to match so
        -- the notification doesn't close on the original timer's schedule
        n:connect_signal("property::timeout", guarded(function(_, new_t)
            if timeout_timer and timeout_timer.started then
                timeout_timer:stop()
            end
            if new_t and new_t > 0 then
                timeout_timer.timeout = new_t
                timeout_timer:start()
            end
        end))
    end

    -- hover to pause timeout
    popup:connect_signal("mouse::enter", guarded(function()
        if timeout_timer then timeout_timer:stop() end
        if countdown_timer then countdown_timer:stop() end
    end))
    popup:connect_signal("mouse::leave", guarded(function()
        if timeout_timer then timeout_timer:start() end
        if countdown_timer then countdown_timer:start() end
    end))

    -- cleanup on destroy
    n:connect_signal("destroyed", guarded(function()
        if timeout_timer then timeout_timer:stop() end
        if countdown_timer then countdown_timer:stop() end
        if popup and popup.valid then
            popup.visible = false
        end
        remove_box(s, entry)
    end))

    -- defer geometry-dependent setup to next event loop (popup needs layout)
    gtimer.delayed_call(guarded(function()
        if not popup.valid or not s.valid then return end

        local ok, err = pcall(function()
            local screen_geo = s.geometry

            -- add to stacking list; reflow computes the target y
            -- (reflow skips animating entries, so we set y ourselves)
            entry.animating = true
            entry.screen = s
            add_box(s, entry)

            -- capture target y from reflow (reflow ran in add_box but
            -- skipped this entry because animating=true; compute manually)
            -- must include the screen's y offset for multi-screen layouts
            local wibar = s.mywibox
            local wibar_h = (wibar and wibar.valid and wibar:geometry().height) or 0
            local target_y = screen_geo.y + wibar_h + NOTIF_TOP_MARGIN

            -- start position: above the target screen so the popup slides
            -- down from the top edge of that specific screen
            -- set width explicitly so we can center perfectly before showing
            -- (somewm may not reposition an already-visible popup)
            local min_w = math.floor(screen_geo.width * 0.15)
            local popup_x = screen_geo.x + math.floor((screen_geo.width - min_w) / 2)
            popup:geometry({ width = min_w, x = popup_x, y = screen_geo.y - dpi(400) })
            popup.visible = true

            -- defer to the next frame so the compositor has drawn the popup
            -- and geometry().height reflects the real height
            gtimer.delayed_call(guarded(function()
                if not popup.valid or not s.valid then return end

                local popup_w = popup:geometry().width
                local popup_h = popup:geometry().height

                -- recenter if the actual width differs from min_w
                -- (hide/reshow because somewm may not move a visible popup)
                local screen_geo = s.geometry
                local correct_x = screen_geo.x + math.floor((screen_geo.width - popup_w) / 2)
                if correct_x ~= popup:geometry().x then
                    popup.visible = false
                    popup:geometry({ x = correct_x })
                    popup.visible = true
                end

                -- set the real start y now that we know the popup height
                local start_y = screen_geo.y - popup_h - dpi(10)
                popup:geometry({ y = math.floor(start_y) })

                -- start slide-in animation (y only)
                slide_to(entry, popup, start_y, target_y)
            end))
        end)
        if not ok then
            -- fallback: show without animation
            if popup.valid then
                add_box(s, entry)
                popup.visible = true
            end
            gdebug.print_warning("notifications.display delayed_call: " .. tostring(err))
        end
    end))

    -- start timers
    if timeout_timer then timeout_timer:start() end
    if countdown_timer then countdown_timer:start() end

    return popup
end

-- debug exports (read-only via eval)
M._debug = function()
    local info = {}
    local total_boxes = 0
    for scr in screen do
        local boxes = screen_boxes[scr] or {}
        total_boxes = total_boxes + #boxes
        for i, e in ipairs(boxes) do
            local p = e.popup
            if p and p.valid then
                local g = p:geometry()
                local sg = scr.geometry
                table.insert(info, string.format("[s%d][%d] x=%d y=%d w=%d vis=%s | screen x=%d y=%d w=%d center=%d",
                    scr.index, i, g.x, g.y, g.width, tostring(p.visible),
                    sg.x, sg.y, sg.width, sg.x + math.floor(sg.width/2)))
            else
                table.insert(info, string.format("[%d] invalid", i))
            end
        end
    end
    return string.format("boxes:%d anims:%d | %s",
        total_boxes, anim_count, table.concat(info, " "))
end

return M
