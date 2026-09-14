-- plugins/media_popup.lua
-- KDE-style media popup: album art, title/artist, prev/play-pause/next.
-- Driven by a single long-running `playerctl --follow` stream, so the
-- popup and any attached tray button update instantly with zero polling.
--
-- Usage in rc.lua (once, after the wibar exists):
--   local media_popup = require("plugins.media_popup")
--   media_popup.attach(media_btn)   -- left-click toggles the popup

local awful = require("awful")
local wibox = require("wibox")
local beautiful = require("beautiful")
local gears = require("gears")
local guarded = require("error_guard")

local dpi = beautiful.xresources.apply_dpi

local M = {}

local FIELD_SEP = "\t"
local ART_CACHE = (os.getenv("XDG_CACHE_HOME") or (os.getenv("HOME") .. "/.cache")) .. "/somewm-media-art"

local state = { status = nil, title = "", artist = "", art = nil }

-- // MARK -- widgets

local art_widget = wibox.widget {
    resize = true,
    forced_width = dpi(96),
    forced_height = dpi(96),
    halign = "center",
    valign = "center",
    widget = wibox.widget.imagebox,
}

local title_widget = wibox.widget {
    markup = "<b>Nothing playing</b>",
    ellipsize = "end",
    widget = wibox.widget.textbox,
}

local artist_widget = wibox.widget {
    text = "",
    ellipsize = "end",
    widget = wibox.widget.textbox,
}

local function control_button(glyph, cmd)
    local w = wibox.widget {
        {
            {
                markup = "<span size='x-large'>" .. glyph .. "</span>",
                align = "center",
                widget = wibox.widget.textbox,
            },
            margins = dpi(6),
            widget = wibox.container.margin,
        },
        bg = beautiful.bg_normal,
        shape = gears.shape.rounded_rect,
        widget = wibox.container.background,
    }
    w:connect_signal("button::press", guarded(function(_, _, _, b)
        if b == 1 then awful.spawn.with_shell("playerctl " .. cmd .. " 2>/dev/null") end
    end))
    w:connect_signal("mouse::enter", guarded(function() w.bg = beautiful.bg_focus end))
    w:connect_signal("mouse::leave", guarded(function() w.bg = beautiful.bg_normal end))
    return w
end

local play_btn = control_button("⏯", "play-pause")

local popup = awful.popup {
    widget = {
        {
            art_widget,
            {
                title_widget,
                artist_widget,
                {
                    control_button("⏮", "previous"),
                    play_btn,
                    control_button("⏭", "next"),
                    spacing = dpi(8),
                    layout = wibox.layout.fixed.horizontal,
                },
                spacing = dpi(4),
                layout = wibox.layout.fixed.vertical,
            },
            spacing = dpi(12),
            layout = wibox.layout.fixed.horizontal,
        },
        margins = dpi(12),
        widget = wibox.container.margin,
    },
    border_color = beautiful.border_focus or "#623997",
    border_width = 1,
    ontop = true,
    visible = false,
    shape = gears.shape.rounded_rect,
}

-- // MARK -- state updates

local function set_art(url)
    if not url or url == "" then
        art_widget.image = nil
        return
    end
    local path = url:match("^file://(.+)")
    if path then
        art_widget.image = path
        return
    end
    if url:match("^https?://") then
        -- cache by a filesystem-safe name; only fetch when missing
        local fname = ART_CACHE .. "/" .. url:gsub("%W", "_")
        awful.spawn.easy_async_with_shell(
            string.format("mkdir -p %s; [ -s %q ] || curl -sfm 5 -o %q %q; echo done",
                ART_CACHE, fname, fname, url),
            guarded(function()
                if state.art == url and gears.filesystem.file_readable(fname) then
                    art_widget.image = fname
                end
            end))
    end
end

local function render()
    if state.status then
        title_widget.markup = "<b>" .. gears.string.xml_escape(state.title ~= "" and state.title or "Unknown") .. "</b>"
        artist_widget.text = state.artist
    else
        title_widget.markup = "<b>Nothing playing</b>"
        artist_widget.text = ""
    end
end

local function start_stream()
    awful.spawn.with_line_callback(
        "playerctl --follow metadata --format '{{status}}" .. FIELD_SEP .. "{{title}}"
            .. FIELD_SEP .. "{{artist}}" .. FIELD_SEP .. "{{mpris:artUrl}}'",
        {
            stdout = guarded(function(line)
                local status, title, artist, art = line:match("^([^\t]*)\t([^\t]*)\t([^\t]*)\t?(.*)$")
                if not status or status == "" then
                    state.status = nil
                else
                    state.status, state.title, state.artist = status, title, artist
                    if art ~= state.art then
                        state.art = art
                        set_art(art)
                    end
                end
                render()
                if M.on_update then M.on_update(state) end
            end),
        })
end

-- // MARK -- attach

--- Toggle the popup anchored under a wibar widget on left click.
function M.attach(button_widget)
    button_widget:connect_signal("button::press", guarded(function(_, _, _, b)
        if b ~= 1 then return end
        if popup.visible then
            popup.visible = false
        else
            awful.placement.next_to(popup, {
                preferred_positions = "bottom",
                preferred_anchors = "middle",
                geometry = mouse.current_widget_geometry,
            })
            popup.visible = true
        end
    end))
    -- close when the pointer leaves the popup
    popup:connect_signal("mouse::leave", guarded(function() popup.visible = false end))
end

start_stream()
render()

return M
