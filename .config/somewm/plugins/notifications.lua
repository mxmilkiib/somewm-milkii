-- Modern notification display with shared-timer slide animation
-- Uses awful.popup for full placement control + naughty.widget.* for content
-- Slide-in animation uses a single shared gears.timer for all active animations
-- Close fades the popup's opacity out over CFG.fade_duration before removal
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
local style   = require("plugins.style")
local dpi = style.dpi
local COLOR_GOLD   = style.color.accent
local COLOR_PURPLE = style.color.accent2
local COLOR_BLACK  = style.color.bg
local COLOR_WHITE  = style.color.fg

local M = {}

-- Configuration
-- module configuration; override via M.configure{...} before first use
local CFG = {
    slide_duration = 0.3,
    fade_duration = 0.12,
    gap = dpi(4),
    top_margin = dpi(4),
    right_gap = dpi(6),
    max_width = dpi(1400),
    -- fraction of screen width; high enough that typical notifications all hit
    -- the floor and render at the same width
    min_width_frac = 0.45,
    timeout = 3.125,
}

function M.configure(opts) style.merge(CFG, opts) end

-- The title is differentiated by bold markup + gold background, not font size.
-- Use the theme font directly; the theme already handles DPI + ui_scale scaling.
-- local NOTIF_FONT = beautiful.notification_font or beautiful.font or "Sans 10"
-- Widget-Popup Fonts (same as the resource/battery/volume/displays popups)
local FONT           = style.font.normal
local FONT_HEAD      = style.font.head
-- local FONT_VALUE  = style.font.bold  -- too large for the header sender
-- local FONT_COUNTDOWN = style.font.normal
-- local FONT_COUNTDOWN = style.font.info
local FONT_COUNTDOWN = style.font.small

-- countdown indicator: remaining seconds as braille cells, one dot per
-- second packed eight to a cell. the leftmost cell erodes first — each
-- tick picks a dot off it; once empty it drops off and the cell to its
-- right starts draining. DRAIN is indexed by dot count (0-8), ordered to
-- empty a cell's left column (dots 1,2,3,7) before the right (4,5,6,8)
-- bottom to top within each column.
-- (earlier styles: one "⡀" per second grouped in tens; a single "⣿…⠀"
-- cell as a fraction gauge; "○◔◑◕●" quarter-phase circle)
local DRAIN = { "⠀", "⢀", "⢠", "⢰", "⢸", "⣸", "⣼", "⣾", "⣿" }
local function seconds_dots(secs)
    secs = math.floor(secs)
    if secs <= 0 then return "" end
    local cells = {}
    local partial = secs % 8
    if partial > 0 then cells[#cells + 1] = DRAIN[partial + 1] end
    for _ = 1, math.floor(secs / 8) do cells[#cells + 1] = DRAIN[9] end
    return table.concat(cells)
end


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
                -- fit_widget is gone with Clay; without a measure the anchor
                -- slides right of the true systray edge but stays on the bar
                local fw = wbase.fit_widget
                    and wbase.fit_widget(right_section, context, child, max_w, max_h) or 0
                systray_w = fw
                systray_found = true
            end
        else
            local fw = wbase.fit_widget
                and wbase.fit_widget(right_section, context, child, max_w, max_h) or 0
            width_after = width_after + fw
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
    local y = s.geometry.y + wibar_h + CFG.top_margin
    -- lower popups overlap the one above by the border width minus 1px so
    -- stacked borders nearly share a single line (matches popup creation)
    local bw = style.popup.border_width
    for i = #boxes, 1, -1 do
        local entry = boxes[i]
        if entry.popup and entry.popup.valid then
            if not entry.animating then
                local geo = entry.popup:geometry()
                entry.popup:geometry({ y = math.floor(y) })
            end
            local geo = entry.popup:geometry()
            y = y + geo.height + CFG.gap - bw
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
-- awesome.start_animation is gone with the declarative animation rework;
-- a shared 60fps gears.timer steps every active animation instead (the
-- pre-native approach). step(progress 0..1), done() once at the end.

local anim_count = 0

local active_anims = setmetatable({}, { __mode = "k" })
local anim_timer

local function animate(duration, easing, step, done)
    local eased = easing == "ease-out-cubic"
        and function(p) return 1 - (1 - p) ^ 3 end
        or function(p) return p end
    local t0 = os.clock()
    local t = gtimer {
        timeout = 1 / 60,
        autostart = true,
        call_now = false,
        callback = function(self)
            local p = math.min((os.clock() - t0) / duration, 1)
            step(eased(p))
            if p >= 1 then
                self:stop()
                active_anims[self] = nil
                if not next(active_anims) and anim_timer then
                    anim_timer:stop()
                    anim_timer = nil
                end
                if done then done() end
            end
        end,
    }
    active_anims[t] = true
    return t
end

local function slide_to(entry, popup, start_y, target_y)
    anim_count = anim_count + 1
    animate(CFG.slide_duration, "ease-out-cubic",
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


-- Quick fade-out on close: marks the entry animating so reflow leaves its
-- Stack Slot alone (lower Notifications reflow once the space frees, not
-- mid-fade), then hides and removes it
local function fade_out(entry, popup, s)
    anim_count = anim_count + 1
    entry.animating = true
    animate(CFG.fade_duration, "linear",
        function(progress)
            if popup.valid then
                popup.opacity = 1 - progress
            end
        end,
        function()
            anim_count = anim_count - 1
            if popup.valid then
                popup.visible = false
            end
            remove_box(s, entry)
        end)
end


-- // MARK --widget-template

-- Widget-Popup Form (same as resource/battery/volume/displays popups):
-- Purple Header Bar (Title left, Sender + Countdown Glyph right in Gold),
-- Black Body (Icon left, Message filling the rest), Actions Section below.
local function build_widget(n, s)
    -- naughty's fallback icon (/usr/share/awesome/icons/awesomeNN.png) is a
    -- 1-bit image that renders as a grey blob at this size; treat it as
    -- "no icon" so sender-less notifications don't get the placeholder
    local icon = n.icon
    if type(icon) == "string" and icon:match("/icons/awesome%d+%.png$") then
        icon = nil
    end

    -- compact icon inline in the header, kept under text line height so it
    -- doesn't stretch the row and leave the meta text floating off-centre
    local icon_widget = wibox.widget {
        image = icon,
        resize = true,
        halign = "center",
        valign = "center",
        forced_width = dpi(15),
        forced_height = dpi(15),
        widget = wibox.widget.imagebox,
    }

    -- countdown indicator: a braille dot per remaining second, rendered at
    -- the right edge of the black body band (the old 28px arcchart forced
    -- the header to ~40px; braille stays one line tall)
    local countdown_text = wibox.widget {
        markup = string.format("<span foreground='%s'>%s</span>",
            COLOR_GOLD, seconds_dots(n.timeout or CFG.timeout)),
        font = FONT_COUNTDOWN,
        align = "center",
        valign = "center",
        widget = wibox.widget.textbox,
    }

    -- title: white bold text on the purple header bar; top-aligned so a
    -- wrapping message doesn't drift it off the first line
    local title_widget = wibox.widget {
        markup = "<b>" .. (n.title or "") .. "</b>",
        font = FONT_HEAD,
        align = "left",
        valign = "top",
        widget = wibox.widget.textbox,
    }

    -- sender: bold gold in the header's right slot; timestamp sits at the
    -- very right in regular weight — same "app  ·  YYYY-MM-DD HH:MM"
    -- value format as the notification centre
    local app_name_widget = wibox.widget {
        markup = "<b><span foreground='" .. COLOR_GOLD .. "'>"
            .. gstring.xml_escape(n.app_name or "") .. " ·"
            .. "</span></b>",
        font = style.font.info,
        align = "right",
        valign = "center",
        widget = wibox.widget.textbox,
    }

    local time_widget = wibox.widget {
        markup = "<span foreground='" .. COLOR_GOLD .. "'>"
            .. os.date("%Y-%m-%d %H:%M") .. "</span>",
        font = style.font.info,
        align = "right",
        valign = "center",
        widget = wibox.widget.textbox,
    }

    -- message takes the header's expanding middle slot (align's "inside"
    -- default), so it wraps instead of overlapping the right-side meta.
    -- top-aligned: extra lines grow downward, keeping the first line level
    -- with the title and meta
    local message_widget = wibox.widget {
        markup = n.message or n.text or "",
        font = FONT,
        align = "left",
        valign = "top",
        wrap = "word_char",
        widget = wibox.widget.textbox,
    }

    -- centre a one-line message in the band, and start a multiline body's
    -- first line at that same offset. the pad is symmetric so a body taller
    -- than its siblings stays centred; the floor keeps a few px of black
    -- breathing room around short bodies
    local probe = wibox.widget { text = "Ag", font = FONT,
        widget = wibox.widget.textbox }
    -- somewm textboxes measure via get_preferred_size; fall back to fit on
    -- builds that still carry the classic widget API
    local function measure(w)
        if w.get_preferred_size then return w:get_preferred_size(s) end
        return w:fit(s, 9999, 9999)
    end
    local _, line_h = measure(probe)
    local title_w, title_h = measure(title_widget)
    local app_w, meta_h = measure(app_name_widget)
    local time_w = select(1, measure(time_widget))
    local has_app = n.app_name and n.app_name ~= ""
    if not has_app then app_w = 0 end
    local sib_h = math.max(icon and dpi(15) or 0, title_h, meta_h)
    local msg_pad = math.max(dpi(4), math.floor((sib_h - line_h) / 2))

    -- countdown lives inside the black band now; the right meta section is
    -- sender + timestamp only (frozen exact so the purple box never shrinks)
    local show_cd = (n.timeout or CFG.timeout) > 5
    local right_w = app_w + (has_app and dpi(6) or 0) + time_w

    -- the title column keeps its dpi(180) floor so the black band stays
    -- aligned across typical notifications, but grows to the title's natural
    -- width so longer titles render on a single line
    local title_col_w = math.max(dpi(180),
        title_w + (icon and (dpi(15) + style.spacing.l) or 0))

    local title_bar = wibox.widget {
        {
            {
                {
                    -- title column: dpi(180) minimum so the black body band
                    -- starts at the same offset for the majority of
                    -- notifications, expanding to fit the title on one line
                    {
                        {
                            icon and wibox.widget {
                                icon_widget,
                                right = style.spacing.l,
                                widget = wibox.container.margin,
                            } or nil,
                            title_widget,
                            layout = wibox.layout.fixed.horizontal,
                        },
                        -- same top inset as the message's first line, so the
                        -- band's vertical padding splits evenly instead of
                        -- pooling below the text in one-line toasts
                        top = msg_pad + dpi(1),
                        widget = wibox.container.margin,
                    },
                    strategy = "exact",
                    width = title_col_w,
                    widget = wibox.container.constraint,
                },
                {
                    {
                        {
                            -- message expands; countdown hugs the band's
                            -- right edge, vertically centred
                            nil,
                            {
                                message_widget,
                                left = style.spacing.xl, right = style.spacing.xl,
                                -- the band starts spacing.m above the inner row
                                -- (its negative margin cancels the purple pad), so
                                -- the first line needs that back on top to sit level
                                -- with the title/meta and centre a single-line body;
                                -- extra lines grow downward from that same offset.
                                -- +1/-1 biases the text down inside its band: glyph
                                -- ink sits high in the line box, so a geometrically
                                -- centred line still reads high
                                top = style.spacing.m + msg_pad + dpi(1),
                                bottom = msg_pad - dpi(1),
                                widget = wibox.container.margin,
                            },
                            show_cd and {
                                countdown_text,
                                right = style.spacing.s,
                                widget = wibox.container.margin,
                            } or nil,
                            layout = wibox.layout.align.horizontal,
                        },
                        bg = COLOR_BLACK,
                        widget = wibox.container.background,
                    },
                    -- negative vertical margins cancel the purple bar's
                    -- padding so the black reaches the popup's top and
                    -- bottom edges; horizontal margins leave purple
                    -- strips beside the block
                    left = style.spacing.l, right = style.spacing.l,
                    top = -dpi(6), bottom = -dpi(6),
                    widget = wibox.container.margin,
                },
                {
                    -- fixed-width right section: measured once while the
                    -- countdown is full so the purple box keeps its size as
                    -- braille cells drain; the inner place keeps content
                    -- right-aligned so the gap grows on its left
                    {
                        {
                            {
                                has_app and app_name_widget or nil,
                                time_widget,
                                spacing = style.spacing.m,
                                layout = wibox.layout.fixed.horizontal,
                            },
                            halign = "right",
                            valign = "top",
                            widget = wibox.container.place,
                        },
                        -- same top inset as the message's first line (and the
                        -- title column), so multiline bodies don't shift it
                        top = msg_pad + dpi(1),
                        widget = wibox.container.margin,
                    },
                    strategy = "exact",
                    width = right_w,
                    widget = wibox.container.constraint,
                },
                layout = wibox.layout.align.horizontal,
            },
            left = style.spacing.xl, right = style.spacing.xl,
            top = style.spacing.m, bottom = style.spacing.m,
            widget = wibox.container.margin,
        },
        bg = COLOR_PURPLE,
        fg = COLOR_WHITE,
        widget = wibox.container.background,
    }

    local actions_widget
    if n.actions and #n.actions > 0 then
        local action_buttons = {}
        for _, action in ipairs(n.actions) do
            table.insert(action_buttons, wibox.widget {
                {
                    {
                        text = action.name,
                        font = style.font.bold,
                        widget = wibox.widget.textbox,
                    },
                    halign = "center",
                    fill_horizontal = true,
                    widget = wibox.container.place,
                },
                forced_height = dpi(20),
                widget = wibox.container.background,
                bg = "#ffffff3d",
                shape = function(cr, w, h)
                    gears.shape.rounded_rect(cr, w, h, style.popup.radius)
                end,
                buttons = {
                    awful.button({}, 1, function()
                        action:invoke()
                    end),
                },
            })
        end
        local actions_row = wibox.layout.flex.horizontal()
        actions_row.spacing = style.spacing.xs
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
                    left = style.spacing.xs, right = style.spacing.xs,
                    top = style.spacing.xs, bottom = style.spacing.xs,
                    widget = wibox.container.margin,
                },
                layout = wibox.layout.fixed.vertical,
            },
            bg = COLOR_BLACK,
            fg = COLOR_WHITE,
            widget = wibox.container.background,
        }
    end

    -- single-row layout: the header carries icon + title + message + meta;
    -- actions still get their own black section under it when present
    local inner = wibox.widget {
        {
            title_bar,
            actions_widget,
            spacing = style.spacing.none,
            layout = wibox.layout.fixed.vertical,
        },
        bg = COLOR_BLACK,
        widget = wibox.container.background,
    }

    -- enforce the minimum screen-width fraction at the widget level so the popup
    -- is actually that wide (awful.popup sizes from its widget tree)
    local min_width = dpi(0)
    if s and s.valid then
        min_width = math.floor(s.geometry.width * CFG.min_width_frac)
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

    -- border is drawn inside the widget tree, not on the drawin: somewm's
    -- border scene buffers never accept input, so clicks on a drawin-level
    -- border pass straight through. as a widget container the border pixels
    -- are content, and the popup's button list dismisses on them
    local bw = style.popup.border_width
    local popup = awful.popup {
        widget = wibox.widget {
            widget,
            border_width = bw,
            border_color = COLOR_GOLD,
            widget = wibox.container.background,
        },
        screen = s,
        visible = false,
        ontop = true,
        type = "notification",
        bg = style.color.bg,
        fg = style.color.fg,
        border_width = 0,
        border_color = COLOR_GOLD,
        shape = function(cr, w, h)
            gears.shape.rounded_rect(cr, w, h, style.popup.radius)
        end,
        maximum_width = CFG.max_width,
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
    local timeout = n.timeout or CFG.timeout
    local timeout_timer
    local countdown_timer
    if timeout > 0 then
        -- countdown timer: one tick per second, each tick drops one dot.
        -- a counter is used instead of os.clock() (which measures CPU time
        -- not wall time, and barely advances while awesome is idle)
        local secs_left = math.ceil(timeout)
        local function paint_countdown()
            countdown_text:set_markup(string.format(
                "<span foreground='%s'>%s</span>", COLOR_GOLD,
                seconds_dots(secs_left)))
        end
        countdown_timer = gtimer {
            timeout = 1,
            autostart = false,
            callback = guarded(function()
                secs_left = math.max(0, secs_left - 1)
                paint_countdown()
                if secs_left <= 0 then countdown_timer:stop() end
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
        -- and refill the dots to the new remaining count
        n:connect_signal("property::timeout", guarded(function(_, new_t)
            if timeout_timer and timeout_timer.started then
                timeout_timer:stop()
            end
            if new_t and new_t > 0 then
                timeout_timer.timeout = new_t
                timeout_timer:start()
                secs_left = math.ceil(new_t)
                paint_countdown()
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

    -- cleanup on destroy: fade out instead of vanishing. an unshown Popup
    -- (destroyed during deferred setup) has nothing to fade — remove directly
    n:connect_signal("destroyed", guarded(function()
        entry.destroyed = true
        if timeout_timer then timeout_timer:stop() end
        if countdown_timer then countdown_timer:stop() end
        if popup and popup.valid and popup.visible then
            fade_out(entry, popup, s)
        else
            if popup and popup.valid then
                popup.visible = false
            end
            remove_box(s, entry)
        end
    end))

    -- defer geometry-dependent setup to next event loop (popup needs layout)
    gtimer.delayed_call(guarded(function()
        if not popup.valid or not s.valid or entry.destroyed then return end

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
            local target_y = screen_geo.y + wibar_h + CFG.top_margin
            -- newest entry sits at index 1 = bottom of the stack; land
            -- below the existing popups with the same border overlap
            -- reflow uses
            local bw = style.popup.border_width
            local boxes = screen_boxes[s]
            for i = #boxes, 2, -1 do
                local e = boxes[i]
                if e.popup and e.popup.valid then
                    target_y = target_y + e.popup:geometry().height + CFG.gap - bw
                end
            end

            -- start position: above the target screen so the popup slides
            -- down from the top edge of that specific screen
            -- set width explicitly so we can center perfectly before showing
            -- (somewm may not reposition an already-visible popup)
            local min_w = math.floor(screen_geo.width * CFG.min_width_frac)
            local popup_x = screen_geo.x + math.floor((screen_geo.width - min_w) / 2)
            popup:geometry({ width = min_w, x = popup_x, y = screen_geo.y - dpi(400) })
            popup.visible = true

            -- defer to the next frame so the compositor has drawn the popup
            -- and geometry().height reflects the real height
            gtimer.delayed_call(guarded(function()
                if not popup.valid or not s.valid or entry.destroyed then return end

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
