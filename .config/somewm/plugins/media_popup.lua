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
local popup_common = require("plugins.popup_common")

local dpi = beautiful.xresources.apply_dpi
local gold = popup_common.theme.GOLD
local purple = popup_common.theme.PURPLE
local FONT_HEAD = popup_common.fonts.FONT_HEAD
local FONT = popup_common.fonts.FONT_CLEAR
local art_cache = (os.getenv("XDG_CACHE_HOME") or (os.getenv("HOME") .. "/.cache")) .. "/somewm-media-art"
local metadata_format = "{{status}}\t{{playerName}}\t{{title}}\t{{artist}}\t{{mpris:artUrl}}"

-- when a preferred player is present, hide these duplicates
local player_dedup = {
    ["plasma-browser-integration"] = { "firefox" },
}

local M = {}
local popup
-- forward declaration: the pin toggle's click callback needs this bound as
-- an upvalue (assigned near the bottom of this file)
local hide
local is_pinned  -- getter set by popup_common.pin in the header below
local players = {}
local rows = wibox.layout.fixed.vertical()
rows.spacing = dpi(6)

local empty = wibox.widget {
    text = "No media players",
    font = FONT,
    align = "center",
    valign = "center",
    forced_height = dpi(22),
    widget = wibox.widget.textbox,
}

-- pin toggle at the right of the header: gold = stays open on outside
-- clicks, grey = any outside click closes it
local pin_btn
pin_btn, is_pinned = popup_common.pin("media_popup", function(on)
    if popup and popup.visible then
        if on then popup_common.outside_click_teardown(popup)
        else popup_common.outside_click_setup(popup, hide) end
    end
end)

local header = wibox.widget {
    {
        {
            {
                text  = "Media",
                fg    = "#FFFFFF",
                font  = FONT_HEAD,
                align = "left",
                valign = "center",
                widget = wibox.widget.textbox,
            },
            nil,
            pin_btn,
            layout = wibox.layout.align.horizontal,
        },
        left = dpi(10), right = dpi(10),
        top = dpi(6), bottom = dpi(6),
        widget = wibox.container.margin,
    },
    bg = purple,
    widget = wibox.container.background,
}

popup = awful.popup {
    widget = {
        header,
        {
            {
                empty,
                rows,
                spacing = dpi(6),
                layout = wibox.layout.fixed.vertical,
            },
            top = dpi(8), bottom = dpi(2),
            left = dpi(10), right = dpi(10),
            widget = wibox.container.margin,
        },
        layout = wibox.layout.fixed.vertical,
    },
    minimum_width = dpi(470),
    maximum_width = dpi(620),
    border_color = gold,
    border_width = popup_common.popup_style().border_width,
    ontop = true,
    visible = false,
    shape = popup_common.popup_style().shape,
}

local function player_label(instance, name)
    local suffix = instance:match("kdeconnect%.mpris_(.+)")
    if suffix then return "Phone · " .. suffix:sub(1, 8) end
    return (name and name ~= "" and name or instance):gsub("%.instance.+$", "")
end

local function control_button(glyph, instance, command)
    local button = wibox.widget {
        {
            {
                markup = glyph,
                font = "Noto Sans Symbols 14",
                valign = "center",
                widget = wibox.widget.textbox,
            },
            halign = "center",
            valign = "center",
            widget = wibox.container.place,
        },
        forced_width = dpi(34),
        forced_height = dpi(34),
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
        forced_width = dpi(72),
        forced_height = dpi(72),
        halign = "center",
        valign = "center",
        widget = wibox.widget.imagebox,
    }
    -- constrain art to exactly 72px so a non-square image doesn't inflate
    -- the row height (which would create a gap between text and buttons).
    -- the row can still grow taller when the text column needs more space.
    -- forced_width on the container keeps the column stable when no art is
    -- loaded, so the text column never shifts position between players.
    local art_container = wibox.widget {
        {
            art,
            strategy = "exact",
            height = dpi(72),
            width = dpi(72),
            widget = wibox.container.constraint,
        },
        forced_width = dpi(82),
        right = dpi(10),
        widget = wibox.container.margin,
    }
    local source = wibox.widget { markup = "<b>" .. gears.string.xml_escape(instance) .. "</b>", font = FONT, widget = wibox.widget.textbox }
    local title = wibox.widget { text = "Nothing playing", font = FONT, ellipsize = "end", wrap = "none", widget = wibox.widget.textbox }
    local artist = wibox.widget { text = "", font = FONT, ellipsize = "end", wrap = "none", widget = wibox.widget.textbox }
    local status = wibox.widget { text = "", font = FONT, align = "right", widget = wibox.widget.textbox }
    local text_col = wibox.widget {
        nil,
        {
            {
                {
                    source,
                    nil,
                    status,
                    layout = wibox.layout.align.horizontal,
                },
                {
                    title,
                    artist,
                    top = dpi(4),
                    bottom = dpi(4),
                    widget = wibox.container.margin,
                },
                {
                    {
                        control_button("⏮", instance, "previous"),
                        control_button("⏯", instance, "play-pause"),
                        control_button("⏭", instance, "next"),
                        spacing = dpi(6),
                        forced_height = dpi(34),
                        layout = wibox.layout.fixed.horizontal,
                    },
                    halign = "right",
                    widget = wibox.container.place,
                },
                spacing = dpi(4),
                layout = wibox.layout.fixed.vertical,
            },
            expand = "inside",
            layout = wibox.layout.align.vertical,
        },
        nil,
        expand = "inside",
        layout = wibox.layout.align.vertical,
    }
    local row = wibox.widget {
        art_container,
        text_col,
        nil,
        layout = wibox.layout.align.horizontal,
    }
    local bg = wibox.widget {
        {
            row,
            top = dpi(10),
            left = dpi(10),
            right = dpi(10),
            bottom = dpi(4),
            widget = wibox.container.margin,
        },
        bg = beautiful.bg_normal,
        border_color = purple,
        border_width = dpi(1),
        shape = function(cr, w, h) gears.shape.rounded_rect(cr, w, h, beautiful.border_radius or dpi(3)) end,
        widget = wibox.container.background,
    }
    -- scroll wheel adjusts this player's volume only (5% per notch)
    bg:connect_signal("button::press", guarded(function(_, _, _, button)
        if button == 4 then
            awful.spawn({ "playerctl", "-p", instance, "volume", "0.05+" }, false)
        elseif button == 5 then
            awful.spawn({ "playerctl", "-p", instance, "volume", "0.05-" }, false)
        end
    end))
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

local function update_empty_state()
    local any_visible = false
    for _, p in pairs(players) do
        if p.widget.visible then any_visible = true break end
    end
    empty.visible = not any_visible
    awesome.emit_signal("media::players_active", any_visible)
end

local function update_player(player)
    awful.spawn.easy_async({ "playerctl", "-p", player.instance, "metadata", "--format", metadata_format }, guarded(function(out)
        local status, name, title, artist, art = out:match("^([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t?(.-)%s*$")
        local is_kdeconnect = player.instance:match("kdeconnect%.mpris_") ~= nil
        if not status then
            if is_kdeconnect then player.widget.visible = false end
            update_empty_state()
            return
        end
        -- KDE Connect players exist whenever a phone is paired, even with no
        -- active media session. Hide those rows so the popup only shows phone
        -- playback when something is actually loaded.
        if is_kdeconnect and title == "" then
            player.widget.visible = false
            update_empty_state()
            return
        end
        player.widget.visible = true
        player.source.markup = "<b>" .. gears.string.xml_escape(player_label(player.instance, name)) .. "</b>"
        player.title.text = title ~= "" and title or "Nothing playing"
        player.artist.text = artist
        player.status.markup = status == "Playing"
            and ("<span foreground='" .. gold .. "'>Playing</span>") or status
        update_art(player, art)
        update_empty_state()
    end))
end

local function rebuild(player_names)
    -- hide shadowed duplicates when a preferred player is present
    local active = {}
    for _, instance in ipairs(player_names) do
        active[instance] = true
    end
    local filtered = {}
    for _, instance in ipairs(player_names) do
        local shadowed = false
        -- strip ".instance..." suffix so "firefox.instance_1_70" matches "firefox"
        local base = instance:gsub("%.instance.+$", "")
        for preferred, dups in pairs(player_dedup) do
            if active[preferred] then
                for _, dup in ipairs(dups) do
                    if dup == base or dup == instance then shadowed = true break end
                end
            end
            if shadowed then break end
        end
        if not shadowed then
            filtered[#filtered + 1] = instance
        end
    end

    local wanted = {}
    for _, instance in ipairs(filtered) do
        wanted[instance] = true
        if not players[instance] then players[instance] = create_row(instance) end
    end
    for instance in pairs(players) do
        if not wanted[instance] then players[instance] = nil end
    end
    rows:reset()
    table.sort(filtered)
    for _, instance in ipairs(filtered) do
        rows:add(players[instance].widget)
        update_player(players[instance])
    end
    update_empty_state()
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

local function show(anchor)
    if popup.visible then return end
    awesome.emit_signal("popup::opening")
    refresh()
    popup_common.show_placement(popup, anchor, { is_pinned = is_pinned, hide = hide })
end

hide = function()
    popup_common.hide(popup)
end

function M.attach(button_widget)
    popup_common.attach(popup, button_widget, function(w)
        if popup.visible then hide() else show(w) end
    end)
end

local refresh_timer = gears.timer { timeout = 2, autostart = true, call_now = true, callback = guarded(refresh) }
awesome.connect_signal("exit", guarded(function() refresh_timer:stop() end))

M.popup = popup
M.players = players

-- close this popup when any other popup opens
popup_common.register_closer(hide)

return M
