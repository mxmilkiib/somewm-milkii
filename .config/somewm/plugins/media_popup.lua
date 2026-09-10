-- plugins/media_popup.lua
-- KDE-style MPRIS media popup: one independently controllable row for every
-- Playerctl instance, including KDE Connect players exported by phones.
-- Player instances are refreshed together so PC and phone playback remain
-- visible at the same time instead of only showing the most recently active
-- player.

local awful = require("awful")
local wibox = require("wibox")
local beautiful = require("beautiful")
local gears = require("gears")
local guarded = require("error_guard")

local dpi = beautiful.xresources.apply_dpi
local gold = (beautiful.main_gold and beautiful.main_gold.base) or "#FFD700"
local purple = (beautiful.main_purple and beautiful.main_purple.base) or "#623997"
local art_cache = (os.getenv("XDG_CACHE_HOME") or (os.getenv("HOME") .. "/.cache")) .. "/somewm-media-art"
local metadata_format = "{{status}}\t{{playerName}}\t{{title}}\t{{artist}}\t{{mpris:artUrl}}"

local M = {}
local players = {}
local rows = wibox.layout.fixed.vertical()
rows.spacing = dpi(6)

local empty = wibox.widget {
    text = "No media players",
    align = "center",
    valign = "center",
    forced_height = dpi(48),
    widget = wibox.widget.textbox,
}

local popup = awful.popup {
    widget = {
        {
            empty,
            rows,
            spacing = dpi(6),
            layout = wibox.layout.fixed.vertical,
        },
        margins = dpi(10),
        widget = wibox.container.margin,
    },
    minimum_width = dpi(470),
    maximum_width = dpi(620),
    border_color = gold,
    border_width = beautiful.bar_edge_width or dpi(3),
    ontop = true,
    visible = false,
    shape = function(cr, w, h) gears.shape.rounded_rect(cr, w, h, beautiful.border_radius or dpi(3)) end,
}

local function player_label(instance, name)
    local suffix = instance:match("kdeconnect%.mpris_(.+)")
    if suffix then return "Phone · " .. suffix:sub(1, 8) end
    return (name and name ~= "" and name or instance):gsub("%.instance%d+$", "")
end

local function control_button(glyph, instance, command)
    local button = wibox.widget {
        {
            {
                markup = "<span size='large'>" .. glyph .. "</span>",
                valign = "center",
                widget = wibox.widget.textbox,
            },
            halign = "center",
            valign = "center",
            widget = wibox.container.place,
        },
        forced_width = dpi(28),
        forced_height = dpi(26),
        bg = beautiful.bg_normal,
        border_width = dpi(1),
        border_color = purple,
        shape = function(cr, w, h) gears.shape.rounded_rect(cr, w, h, beautiful.border_radius or dpi(3)) end,
        widget = wibox.container.background,
    }
    button:connect_signal("button::press", guarded(function(_, _, _, pressed)
        if pressed == 1 then awful.spawn({ "playerctl", "-p", instance, command }, false) end
    end))
    button:connect_signal("mouse::enter", guarded(function() button.bg = beautiful.bg_focus end))
    button:connect_signal("mouse::leave", guarded(function() button.bg = beautiful.bg_normal end))
    return button
end

local function create_row(instance)
    local art = wibox.widget {
        resize = true,
        forced_width = dpi(64),
        forced_height = dpi(64),
        halign = "center",
        valign = "center",
        widget = wibox.widget.imagebox,
    }
    local source = wibox.widget { markup = "<b>" .. gears.string.xml_escape(instance) .. "</b>", widget = wibox.widget.textbox }
    local title = wibox.widget { text = "Nothing playing", ellipsize = "end", forced_width = dpi(250), widget = wibox.widget.textbox }
    local artist = wibox.widget { text = "", ellipsize = "end", widget = wibox.widget.textbox }
    local status = wibox.widget { text = "", align = "right", widget = wibox.widget.textbox }
    local row = wibox.widget {
        {
            art,
            {
                {
                    source,
                    nil,
                    status,
                    layout = wibox.layout.align.horizontal,
                },
                title,
                artist,
                {
                    control_button("⏮", instance, "previous"),
                    control_button("⏯", instance, "play-pause"),
                    control_button("⏭", instance, "next"),
                    spacing = dpi(6),
                    layout = wibox.layout.fixed.horizontal,
                },
                spacing = dpi(2),
                layout = wibox.layout.fixed.vertical,
            },
            spacing = dpi(10),
            layout = wibox.layout.fixed.horizontal,
        },
        margins = dpi(8),
        widget = wibox.container.margin,
    }
    local bg = wibox.widget {
        row,
        bg = beautiful.bg_normal,
        border_color = purple,
        border_width = dpi(1),
        shape = function(cr, w, h) gears.shape.rounded_rect(cr, w, h, beautiful.border_radius or dpi(3)) end,
        widget = wibox.container.background,
    }
    return { instance = instance, widget = bg, art = art, source = source, title = title, artist = artist, status = status, art_url = nil }
end

local function update_art(player, url)
    if player.art_url == url then return end
    player.art_url = url
    if not url or url == "" then player.art.image = nil; return end
    local path = url:match("^file://(.+)")
    if path then player.art.image = path; return end
    if not url:match("^https?://") then return end
    gears.filesystem.make_directories(art_cache)
    local filename = art_cache .. "/" .. url:gsub("%W", "_")
    if gears.filesystem.file_readable(filename) then player.art.image = filename; return end
    awful.spawn.easy_async({ "curl", "-sfm", "5", "-o", filename, url }, guarded(function(_, _, _, code)
        if code == 0 and player.art_url == url and gears.filesystem.file_readable(filename) then
            player.art.image = filename
        end
    end))
end

local function update_player(player)
    awful.spawn.easy_async({ "playerctl", "-p", player.instance, "metadata", "--format", metadata_format }, guarded(function(out)
        local status, name, title, artist, art = out:match("^([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t?(.-)%s*$")
        if not status then return end
        player.source.markup = "<b>" .. gears.string.xml_escape(player_label(player.instance, name)) .. "</b>"
        player.title.text = title ~= "" and title or "Nothing playing"
        player.artist.text = artist
        player.status.markup = status == "Playing"
            and ("<span foreground='" .. gold .. "'>Playing</span>") or status
        update_art(player, art)
    end))
end

local function rebuild(player_names)
    local wanted = {}
    for _, instance in ipairs(player_names) do
        wanted[instance] = true
        if not players[instance] then players[instance] = create_row(instance) end
    end
    for instance in pairs(players) do
        if not wanted[instance] then players[instance] = nil end
    end
    rows:reset()
    table.sort(player_names)
    for _, instance in ipairs(player_names) do
        rows:add(players[instance].widget)
        update_player(players[instance])
    end
    empty.visible = #player_names == 0
    if M.on_update then M.on_update(players) end
end

local function refresh()
    awful.spawn.easy_async({ "playerctl", "-l" }, guarded(function(out)
        local names, seen = {}, {}
        for instance in out:gmatch("[^\r\n]+") do
            if instance ~= "" and not seen[instance] then
                seen[instance] = true
                names[#names + 1] = instance
            end
        end
        rebuild(names)
    end))
end

function M.attach(button_widget)
    button_widget:connect_signal("button::press", guarded(function(_, _, _, pressed)
        if pressed ~= 1 then return end
        if popup.visible then
            popup.visible = false
            return
        end
        refresh()
        popup.visible = true
        -- position: top edge at bar bottom (workarea top), right-aligned to
        -- screen with 4px margin so the popup never gets cut off by the right
        -- edge
        local s = mouse.screen or awful.screen.focused()
        local wa = s.workarea
        local bw = popup.border_width or 0
        local pw = popup:geometry().width
        popup.x = math.max(wa.x + bw, wa.x + wa.width - pw - bw - dpi(4))
        popup.y = wa.y + bw
    end))
end

local refresh_timer = gears.timer { timeout = 2, autostart = true, call_now = true, callback = guarded(refresh) }
awesome.connect_signal("exit", guarded(function() refresh_timer:stop() end))

M.popup = popup
M.players = players

return M
