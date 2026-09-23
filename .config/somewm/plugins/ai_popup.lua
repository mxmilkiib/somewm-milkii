-- plugins/ai_popup.lua
-- Clickable popup anchored to the wibar AI status widget. Shows the status
-- of local AI services (llama-server, whisper-server, open-webui,
-- whisper-dictate) with start/stop toggles, and notes the dictation hotkey.
--
-- One shared popup is created lazily and re-anchored to whichever AI
-- widget is clicked (the wibar is built per-screen).

local awful   = require("awful")
local gears   = require("gears")
local wibox   = require("wibox")
local beautiful = require("beautiful")
local guarded = require("error_guard")
local popup_common = require("plugins.popup_common")

local dpi = beautiful.xresources.apply_dpi

local COLOR_BLACK  = popup_common.theme.BLACK
local COLOR_WHITE  = popup_common.theme.WHITE
local COLOR_GOLD   = popup_common.theme.GOLD
local COLOR_GREY   = popup_common.theme.GREY
local COLOR_GREEN  = popup_common.theme.GREEN
local COLOR_RED    = popup_common.theme.RED
local FONT       = popup_common.fonts.FONT
local FONT_INFO  = popup_common.fonts.FONT_INFO
local FONT_MONO  = popup_common.fonts.FONT_MONO
local CONTENT_W  = dpi(320)

local M = {}

local popup
-- holder table: draggable_header reads popup from here so build_content can
-- run before the awful.popup is constructed (awful.popup requires a widget arg)
local popup_holder = {}
local hide
local ctrl
local rows_container
local hotkey_row
local refresh_popup  -- forward declaration (used by make_service_row before definition)


-- // MARK -- service definitions

local services = {
    {
        key = "llama",
        name = "llama-server",
        desc = "LLM inference",
        port = ":8081",
        start_cmd = { "systemctl", "--user", "start", "llama-server.service" },
        stop_cmd  = { "systemctl", "--user", "stop",  "llama-server.service" },
    },
    {
        key = "whisper",
        name = "whisper-server",
        desc = "STT API",
        port = ":8082",
        start_cmd = { "systemctl", "--user", "start", "whisper-server.service" },
        stop_cmd  = { "systemctl", "--user", "stop",  "whisper-server.service" },
    },
    {
        key = "openwebui",
        name = "open-webui",
        desc = "Web UI",
        port = ":8080",
        start_cmd = { "sh", "-c", "SUDO_ASKPASS=/usr/bin/ksshaskpass sudo -A systemctl start open-webui.service" },
        stop_cmd  = { "sh", "-c", "SUDO_ASKPASS=/usr/bin/ksshaskpass sudo -A systemctl stop open-webui.service" },
    },
    {
        key = "dictate",
        name = "whisper-dictate",
        desc = "Live dictation",
        start_cmd = { "whisper-dictate" },
        stop_cmd  = { "whisper-dictate" },
        is_toggle = true,
    },
}


-- // MARK -- status query

-- Query all four service statuses in a single shell call to keep the
-- async overhead to one fork per poll. Returns a table keyed by the
-- service's `key` field with value "active" or "inactive".
local function query_status(callback)
    local cmd = [[printf 'llama:%s\nwhisper:%s\nopenwebui:%s\ndictate:%s\n' \
      "$(systemctl --user is-active llama-server.service 2>/dev/null || true)" \
      "$(systemctl --user is-active whisper-server.service 2>/dev/null || true)" \
      "$(systemctl is-active open-webui.service 2>/dev/null || true)" \
      "$(if [ -f /tmp/whisper-dictate.pid ]; then pid=$(cat /tmp/whisper-dictate.pid 2>/dev/null); if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then echo active; else echo inactive; fi; else echo inactive; fi)"]]
    awful.spawn.easy_async({ "sh", "-c", cmd }, guarded(function(out)
        local status = {}
        for line in out:gmatch("[^\r\n]+") do
            local key, val = line:match("^(%w+):(%w+)")
            if key then status[key] = val end
        end
        callback(status)
    end))
end


-- // MARK -- row builder

local make_text = popup_common.make_text

local function make_service_row(svc, status)
    local is_active = status[svc.key] == "active"
    local dot_color = is_active and COLOR_GREEN or COLOR_GREY

    local dot = wibox.widget {
        markup = string.format('<span foreground="%s">\u{25CF}</span>', dot_color),
        font = FONT,
        valign = "center",
        widget = wibox.widget.textbox,
    }

    local name = wibox.widget {
        text = svc.name,
        fg = COLOR_WHITE,
        font = FONT,
        align = "left",
        valign = "center",
        widget = wibox.widget.textbox,
    }

    -- desc sits in a fixed-width column so each row's port starts at the
    -- same x (the middle cell's left edge is uniform: every row leads with
    -- an identical dot glyph)
    local desc = wibox.widget {
        text = svc.desc,
        fg = COLOR_GREY,
        font = FONT_INFO,
        align = "left",
        valign = "center",
        forced_width = dpi(96),
        widget = wibox.widget.textbox,
    }

    local port = wibox.widget {
        text = svc.port or "",
        fg = COLOR_GREY,
        font = FONT_INFO,
        align = "left",
        valign = "center",
        widget = wibox.widget.textbox,
    }

    local toggle_label = is_active and "Stop" or "Start"
    local toggle_color = is_active and COLOR_RED or COLOR_GREEN
    local toggle = wibox.widget {
        markup = string.format('<span foreground="%s">%s</span>', toggle_color, toggle_label),
        font = FONT,
        valign = "center",
        widget = wibox.widget.textbox,
    }
    -- wibox.container.place centres the text so left/right padding is even;
    -- forced_width on the background keeps Start and Stop the same width
    local toggle_bg = wibox.widget {
        {
            toggle,
            halign = "center",
            widget = wibox.container.place,
        },
        forced_width = dpi(64),
        top = dpi(3), bottom = dpi(3),
        bg = popup_common.theme.HOVER,
        shape = function(cr, w, h)
            require("gears.shape").rounded_rect(cr, w, h, dpi(3))
        end,
        widget = wibox.container.background,
    }

    toggle_bg:buttons(gears.table.join(awful.button({}, 1, guarded(function()
        local cmd = is_active and svc.stop_cmd or svc.start_cmd
        awful.spawn.easy_async(cmd, guarded(function()
            -- whisper-dictate debounces 400ms; systemd needs a moment to
            -- transition states. 1s covers both before re-querying.
            gears.timer.start_new(1, guarded(function()
                refresh_popup()
                awesome.emit_signal("ai::status_changed")
                return false
            end))
        end))
    end))))

    return wibox.widget {
        {
            dot,
            {
                {
                    name,
                    { desc, port, layout = wibox.layout.fixed.horizontal },
                    layout = wibox.layout.flex.vertical,
                },
                left = dpi(14),
                widget = wibox.container.margin,
            },
            toggle_bg,
            expand = "inside",
            layout = wibox.layout.align.horizontal,
        },
        top = dpi(4), bottom = dpi(4),
        left = dpi(6), right = dpi(10),
        widget = wibox.container.margin,
    }
end


-- // MARK -- content

local function build_content()
    -- header (title drag handle + detach + pin) and the detach/drag controller
    -- come from popup_common so this popup can float and be dragged like the
    -- rest of the wibar popups. also_release: the ontop popup can swallow the
    -- first button::press on focus transfer, so listen for release too
    local header
    header, ctrl = popup_common.draggable_header {
        holder = popup_holder,
        name  = "ai_popup",
        title = "Local AI",
        width = CONTENT_W,
        hide  = function() hide() end,
        also_release = true,
    }

    rows_container = wibox.widget {
        layout = wibox.layout.fixed.vertical,
        spacing = dpi(2),
    }

    -- whisper dictation hotkey note at the bottom
    hotkey_row = wibox.widget {
        {
            make_text("Dictation hotkey: ", COLOR_GREY, FONT_INFO),
            make_text("Ctrl+Shift+Space", COLOR_GOLD, FONT_MONO),
            spacing = dpi(2),
            layout = wibox.layout.fixed.horizontal,
        },
        top = dpi(6), bottom = dpi(4),
        left = dpi(2), right = dpi(2),
        widget = wibox.container.margin,
    }

    return wibox.widget {
        header,
        {
            rows_container,
            top = dpi(6), bottom = dpi(4),
            left = dpi(10), right = dpi(10),
            widget = wibox.container.margin,
        },
        popup_common.separator(CONTENT_W),
        {
            hotkey_row,
            left = dpi(10), right = dpi(10),
            widget = wibox.container.margin,
        },
        layout = wibox.layout.fixed.vertical,
    }
end


-- // MARK -- refresh

refresh_popup = function(cb)
    if not popup or not rows_container then if cb then cb() end return end
    query_status(guarded(function(status)
        rows_container:reset()
        for _, svc in ipairs(services) do
            rows_container:add(make_service_row(svc, status))
        end
        if cb then cb() end
    end))
end


-- // MARK -- popup lifecycle

local function ensure_popup()
    if popup then return end
    local style = popup_common.popup_style()
    -- build content first so the awful.popup constructor gets its required
    -- widget arg; draggable_header reads popup via popup_holder, assigned
    -- right after construction
    local content = build_content()
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

hide = function()
    if not popup then return end
    -- skip if not visible: the register_closer fires synchronously during
    -- emit_signal("popup::opening") in show(), before the popup is
    -- revealed. calling popup_common.hide here would reset _showing
    -- and the async refresh callback would bail without showing
    if not popup.visible then return end
    popup_common.hide(popup)
end

popup_common.register_closer(hide)

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
    -- rows arrive would anchor an empty popup that then grows downward
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


-- // MARK -- attach

-- Wire left-click toggle on an AI status widget. Safe to call once per
-- screen; all widgets share the single popup.
function M.attach(widget)
    ensure_popup()
    popup_common.attach(popup, widget, toggle, {
        right_hide = hide,
    })
end

function M.is_visible()
    return popup and popup.visible or false
end

-- Expose query_status so the bar widget can share the same status check
M.query_status = query_status

return M
