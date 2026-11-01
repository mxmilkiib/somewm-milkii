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
local guarded = require("error_guard")
local style   = require("plugins.style")
local popup_common = require("plugins.popup_common")

local dpi = style.dpi

local COLOR_BLACK  = popup_common.theme.BLACK
local COLOR_WHITE  = popup_common.theme.WHITE
local COLOR_GOLD   = popup_common.theme.GOLD
local COLOR_GREY   = popup_common.theme.GREY
local COLOR_GREEN  = popup_common.theme.GREEN
local COLOR_RED    = popup_common.theme.RED
local FONT       = popup_common.fonts.FONT
local FONT_INFO  = popup_common.fonts.FONT_INFO
local FONT_MONO  = popup_common.fonts.FONT_MONO

local M = {}

-- module configuration; override via M.configure{...} before first use
-- (the popup builds lazily on the first attach/click)
local CFG = {
    content_w   = dpi(320),  -- popup content width
    desc_w      = dpi(112),  -- fixed description column width
    toggle_w    = dpi(64),   -- fixed Start/Stop button width
    name_indent = dpi(14),   -- gap between the status dot and its name
}

function M.configure(opts) style.merge(CFG, opts) end

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
        section = "Inference",
        key = "llama",
        name = "llama-server",
        desc = "LLM inference",
        port = ":8081",
        start_cmd = { "systemctl", "--user", "start", "llama-server.service" },
        stop_cmd  = { "systemctl", "--user", "stop",  "llama-server.service" },
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
        section = "Speech to text",
        key = "whisper",
        name = "whisper-server",
        desc = "STT API",
        port = ":8082",
        start_cmd = { "systemctl", "--user", "start", "whisper-server.service" },
        stop_cmd  = { "systemctl", "--user", "stop",  "whisper-server.service" },
    },
    {
        -- live dictation client (whisper-stream + wtype via pidfile);
        -- sits beside whisper-server, the batch STT HTTP API it does not use
        key = "dictate",
        name = "whisper-dictate",
        desc = "Live dictation",
        start_cmd = { "whisper-dictate" },
        stop_cmd  = { "whisper-dictate" },
        is_toggle = true,
    },
    {
        section = "Text to speech",
        -- sherpa-onnx TTS (Alba Scots voice) behind an OpenAI-compatible
        -- /v1/audio/speech endpoint; `say` talks to it
        key = "tts",
        name = "sherpa-tts",
        desc = "TTS (Alba)",
        port = ":8882",
        start_cmd = { "systemctl", "--user", "start", "sherpa-tts.service" },
        stop_cmd  = { "systemctl", "--user", "stop",  "sherpa-tts.service" },
    },
    {
        -- kokoro TTS behind the same OpenAI-compatible endpoint shape;
        -- tts-reader can select any of its voices
        key = "kokoro",
        name = "kokoro-server",
        desc = "TTS (Kokoro)",
        port = ":8880",
        start_cmd = { "systemctl", "--user", "start", "kokoro-server.service" },
        stop_cmd  = { "systemctl", "--user", "stop",  "kokoro-server.service" },
    },
    {
        -- launcher, not a service: opens the reader UI on the current
        -- primary selection (no status query, button always says Speak)
        key = "reader",
        name = "tts-reader",
        desc = "Speak selection",
        is_launcher = true,
        launch_label = "Speak",
        start_cmd = { "tts-reader", "--sel" },
    },
}


-- // MARK -- status query

-- Query all service statuses in a single shell call to keep the
-- async overhead to one fork per poll. Returns a table keyed by the
-- service's `key` field with value "active" or "inactive".
local function query_status(callback)
    local cmd = [[printf 'llama:%s\nwhisper:%s\nopenwebui:%s\ndictate:%s\ntts:%s\nkokoro:%s\n' \
      "$(systemctl --user is-active llama-server.service 2>/dev/null || true)" \
      "$(systemctl --user is-active whisper-server.service 2>/dev/null || true)" \
      "$(systemctl is-active open-webui.service 2>/dev/null || true)" \
      "$(if [ -f /tmp/whisper-dictate.pid ]; then pid=$(cat /tmp/whisper-dictate.pid 2>/dev/null); if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then echo active; else echo inactive; fi; else echo inactive; fi)" \
      "$(systemctl --user is-active sherpa-tts.service 2>/dev/null || true)" \
      "$(systemctl --user is-active kokoro-server.service 2>/dev/null || true)"]]
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
        forced_width = CFG.desc_w,
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

    -- launchers aren't services: fixed label, no Start/Stop state
    local toggle_label, toggle_color
    if svc.is_launcher then
        toggle_label = svc.launch_label or "Open"
        toggle_color = COLOR_GOLD
    else
        toggle_label = is_active and "Stop" or "Start"
        toggle_color = is_active and COLOR_RED or COLOR_GREEN
    end
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
        forced_width = CFG.toggle_w,
        top = style.spacing.xs, bottom = style.spacing.xs,
        bg = popup_common.theme.HOVER,
        shape = function(cr, w, h)
            require("gears.shape").rounded_rect(cr, w, h, style.popup.radius)
        end,
        widget = wibox.container.background,
    }

    local function refresh_soon()
        -- whisper-dictate debounces 400ms; systemd needs a moment to
        -- transition states. 1s covers both before re-querying.
        gears.timer.start_new(1, guarded(function()
            refresh_popup()
            awesome.emit_signal("ai::status_changed")
            return false
        end))
    end

    toggle_bg:buttons(gears.table.join(awful.button({}, 1, guarded(function()
        if svc.is_launcher then
            -- fire-and-forget app launch, then close the popup
            awful.spawn(svc.start_cmd)
            hide()
            return
        end
        local cmd = is_active and svc.stop_cmd or svc.start_cmd
        if svc.is_toggle then
            -- a toggle's start invocation stays alive for the session, so
            -- easy_async's on-exit callback would defer the row refresh
            -- until dictation ended; fire-and-forget + fixed delay instead
            awful.spawn(cmd)
            refresh_soon()
        else
            awful.spawn.easy_async(cmd, guarded(function()
                refresh_soon()
            end))
        end
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
                left = CFG.name_indent,
                widget = wibox.container.margin,
            },
            toggle_bg,
            expand = "inside",
            layout = wibox.layout.align.horizontal,
        },
        top = style.spacing.s, bottom = style.spacing.s,
        left = style.spacing.m, right = style.spacing.xl,
        widget = wibox.container.margin,
    }
end


-- group heading above each service section (Inference/STT/TTS)
local function make_section_header(title)
    return wibox.widget {
        make_text(title:upper(), COLOR_GREY, FONT_INFO),
        top = style.spacing.m, bottom = style.spacing.xxs,
        left = style.spacing.m,
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
        width = CFG.content_w,
        hide  = function() hide() end,
        also_release = true,
    }

    rows_container = wibox.widget {
        layout = wibox.layout.fixed.vertical,
        spacing = style.spacing.xxs,
    }

    -- whisper dictation + TTS reader hotkey notes at the bottom
    hotkey_row = wibox.widget {
        {
            {
                make_text("Dictation hotkey: ", COLOR_GREY, FONT_INFO),
                make_text("Ctrl+Shift+Space", COLOR_GOLD, FONT_MONO),
                spacing = style.spacing.xxs,
                layout = wibox.layout.fixed.horizontal,
            },
            {
                make_text("TTS hotkey: ", COLOR_GREY, FONT_INFO),
                make_text("Mod4+Shift+T", COLOR_GOLD, FONT_MONO),
                spacing = style.spacing.xxs,
                layout = wibox.layout.fixed.horizontal,
            },
            spacing = style.spacing.xxs,
            layout = wibox.layout.fixed.vertical,
        },
        top = style.spacing.m, bottom = style.spacing.s,
        left = style.spacing.xxs, right = style.spacing.xxs,
        widget = wibox.container.margin,
    }

    return wibox.widget {
        header,
        {
            rows_container,
            top = style.spacing.m, bottom = style.spacing.s,
            left = style.popup.margin_x, right = style.popup.margin_x,
            widget = wibox.container.margin,
        },
        popup_common.separator(CFG.content_w),
        {
            hotkey_row,
            left = style.popup.margin_x, right = style.popup.margin_x,
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
        for i, svc in ipairs(services) do
            if svc.section then
                -- purple rule between sections, matching the separators the
                -- volume/brightness popups draw between their device groups
                if i > 1 then
                    rows_container:add(popup_common.separator(CFG.content_w))
                end
                rows_container:add(make_section_header(svc.section))
            end
            rows_container:add(make_service_row(svc, status))
        end
        if cb then cb() end
    end))
end


-- // MARK -- popup lifecycle

local function ensure_popup()
    if popup then return end
    local pstyle = popup_common.popup_style()
    -- build content first so the awful.popup constructor gets its required
    -- widget arg; draggable_header reads popup via popup_holder, assigned
    -- right after construction
    local content = build_content()
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
    -- whisper-dictate pings this signal right after its pidfile appears or
    -- disappears, so a visible popup can re-query immediately instead of
    -- waiting on the post-click timer or the 15s poll
    awesome.connect_signal("ai::status_changed", guarded(function()
        if popup.visible then refresh_popup() end
    end))
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
