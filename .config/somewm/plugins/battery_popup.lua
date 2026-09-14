-- plugins/battery_popup.lua
-- Clickable popup anchored to the wibar battery widget. Shows extended
-- battery/AC info read synchronously from /sys/class/power_supply and a
-- power-profile switcher driven by power-profiles-daemon.
--
-- The profile source of truth is `powerprofilesctl get`; this module does not
-- talk to plugins/power.lua. Both just use power-profiles-daemon, so a manual
-- choice here persists until the next AC/battery transition (which power.lua
-- auto-switches on) — no conflict.
--
-- One shared popup is created lazily and re-anchored to whichever battery
-- widget is clicked (the wibar is built per-screen).

local awful   = require("awful")
local gears   = require("gears")
local wibox   = require("wibox")
local beautiful = require("beautiful")
local gshape  = require("gears.shape")
local guarded = require("error_guard")
local popup_common = require("plugins.popup_common")

local dpi = beautiful.xresources.apply_dpi

local COLOR_PURPLE = popup_common.theme.PURPLE
local COLOR_BLACK  = popup_common.theme.BLACK
local COLOR_WHITE  = popup_common.theme.WHITE
local COLOR_GOLD   = popup_common.theme.GOLD
local COLOR_GREY   = popup_common.theme.GREY
local COLOR_HOVER  = popup_common.theme.HOVER
local FONT       = popup_common.fonts.FONT
local FONT_HEAD  = popup_common.fonts.FONT_HEAD
local CONTENT_W  = dpi(240)   -- fixed popup content width (full-width rows)

local M = {}

local POWER_PROFILES = {
    { key = "performance", label = "Performance" },
    { key = "balanced",    label = "Balanced" },
    { key = "power-saver", label = "Power Saver" },
}

local popup
local profile_buttons = {}
local active_profile  = nil
-- forward declaration: the pin toggle's click callback (built inside
-- build_content) needs this bound as an upvalue
local hide
local is_pinned  -- getter set in build_content (see popup_common.pin)

-- charge mode state: "maximize" (80% cap) or "auto" (HP managed / full)
local charge_mode_text, charge_mode_btn
local current_charge_mode = nil


-- MARK: SYS READERS

local function read_file(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local s = f:read("*l")
    f:close()
    return s
end

-- Discover the battery sysfs directory once. Probes BAT0, BAT1, BATT, BAT
-- in order; falls back to the first /sys/class/power_supply/BAT* entry.
-- Caches the result so repeated reads don't rescan the directory (P5).
local battery_path
local function find_battery_path()
    if battery_path then return battery_path end
    for _, name in ipairs({ "BAT0", "BAT1", "BATT", "BAT" }) do
        if gears.filesystem.file_readable("/sys/class/power_supply/" .. name .. "/capacity") then
            battery_path = "/sys/class/power_supply/" .. name
            return battery_path
        end
    end
    -- last resort: glob the directory for the first BAT*
    local f = io.popen("ls -d /sys/class/power_supply/BAT* 2>/dev/null | head -1")
    if f then
        local p = f:read("*l")
        f:close()
        if p and p ~= "" then
            battery_path = p
            return p
        end
    end
    battery_path = "/sys/class/power_supply/BAT0"  -- legacy fallback
    return battery_path
end

M.find_battery_path = find_battery_path

local function battery_info()
    local bat = find_battery_path()
    local num = function(p) return tonumber(read_file(p)) end
    return {
        pct        = num(bat .. "/capacity") or 0,
        status     = read_file(bat .. "/status") or "Unknown",
        energy_now = num(bat .. "/energy_now") or 0,        -- µWh
        energy_full= num(bat .. "/energy_full") or 0,
        energy_design = num(bat .. "/energy_full_design") or 0,
        power_now  = num(bat .. "/power_now") or 0,         -- µW
        cycles     = read_file(bat .. "/cycle_count") or "?",
        ac         = read_file("/sys/class/power_supply/AC/online"),
    }
end

local function fmt_time(hours)
    if hours <= 0 then return nil end
    local h = math.floor(hours)
    local m = math.floor((hours - h) * 60)
    return string.format("%dh %02dm", h, m)
end


-- MARK: CHARGE MODE

-- HP Battery Health Manager policy via hp-bioscfg firmware-attributes.
-- "maximize" caps charging at ~80% for daily longevity; "auto" lets HP
-- firmware manage (full charge for trips). Toggled via ~/bin/hp-battery-mode
-- which needs a sudoers rule for passwordless writes (see script header).
local CHARGE_MODE_ATTR = "/sys/class/firmware-attributes/hp-bioscfg/attributes/Battery Health Manager/current_value"

local function read_charge_mode()
    local f = io.open(CHARGE_MODE_ATTR, "r")
    if not f then return nil end
    local val = f:read("*l") or ""
    f:close()
    if val:match("Maximize") then return "maximize"
    elseif val:match("Let HP Manage") then return "auto"
    else return nil end
end

local function charge_mode_label(mode)
    if mode == "maximize" then return "80% Cap (Health)"
    elseif mode == "auto" then return "HP Managed (Full)"
    else return "Unknown" end
end

local function toggle_charge_mode()
    local cur = read_charge_mode()
    local target = (cur == "maximize") and "auto" or "maximize"
    awful.spawn.easy_async("hp-battery-mode " .. target, guarded(function(_, stderr, exit_code)
        -- only update the UI label if the command actually succeeded; on
        -- failure, keep the old label so the display reflects reality
        if exit_code ~= 0 then
            if charge_mode_text and stderr and stderr ~= "" then
                charge_mode_text.text = "Error"
            end
            return
        end
        current_charge_mode = target
        if charge_mode_text then
            charge_mode_text.text = charge_mode_label(target)
        end
    end))
end


-- MARK: WIDGETS

local pct_text, status_text, ac_text, energy_text, health_text, rate_text

local make_text = popup_common.make_text

-- one full-width profile button; highlighted when it matches active_profile
local function make_profile_button(p)
    local txt = wibox.widget {
        text  = p.label,
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
        forced_width = CONTENT_W,
        bg = COLOR_BLACK,
        fg = COLOR_WHITE,
        widget = wibox.container.background,
    }
    bg._key = p.key
    bg._inactive_bg = COLOR_BLACK
    bg._active_bg   = COLOR_PURPLE

    local function paint()
        local active = (p.key == active_profile)
        bg.bg = active and bg._active_bg or bg._inactive_bg
        bg.fg = active and COLOR_GOLD or COLOR_WHITE
        txt.fg = active and COLOR_GOLD or COLOR_WHITE
    end
    bg.paint = paint

    bg:connect_signal("mouse::enter", guarded(function()
        if p.key ~= active_profile then bg.bg = COLOR_HOVER end
    end))
    bg:connect_signal("mouse::leave", guarded(function()
        if p.key ~= active_profile then bg.bg = bg._inactive_bg end
    end))
    bg:buttons(gears.table.join(awful.button({}, 1, guarded(function()
        awful.spawn.easy_async("powerprofilesctl set " .. p.key, guarded(function()
            active_profile = p.key
            for _, b in ipairs(profile_buttons) do b:paint() end
        end))
    end))))
    paint()
    return bg
end

local function separator()
    return popup_common.separator(CONTENT_W)
end

local function build_content()
    pct_text    = make_text("100%", COLOR_WHITE, popup_common.fonts.FONT_HUGE)
    status_text = make_text("Unknown", COLOR_GREY)
    ac_text     = make_text("")
    energy_text = make_text("")
    health_text = make_text("")
    rate_text   = make_text("")

    local info_rows = wibox.widget {
        {
            pct_text,
            {
                status_text,
                ac_text,
                layout = wibox.layout.fixed.vertical,
                spacing = dpi(2),
            },
            spacing = dpi(8),
            layout = wibox.layout.fixed.horizontal,
        },
        energy_text,
        health_text,
        rate_text,
        layout = wibox.layout.fixed.vertical,
        spacing = dpi(4),
    }

    local profile_list = wibox.widget {
        layout = wibox.layout.fixed.vertical,
        spacing = dpi(2),
    }
    for _, p in ipairs(POWER_PROFILES) do
        local b = make_profile_button(p)
        profile_buttons[#profile_buttons + 1] = b
        profile_list:add(b)
    end

    -- pin toggle at the right of the header: gold = stays open on outside
    -- clicks, grey = any outside click closes it
    local pin_btn, pinned = popup_common.pin("battery_popup", function(on)
        if popup and popup.visible then
            if on then popup_common.outside_click_teardown(popup)
            else popup_common.outside_click_setup(popup, hide) end
        end
    end)
    is_pinned = pinned

    -- full-width purple header
    local header = wibox.widget {
        {
            {
                make_text("Battery", COLOR_WHITE, FONT_HEAD),
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

    -- padded info block (text left-aligned, full-width black bg)
    local info_block = wibox.widget {
        {
            info_rows,
            top = dpi(8), bottom = dpi(8),
            left = dpi(10), right = dpi(10),
            widget = wibox.container.margin,
        },
        forced_width = CONTENT_W,
        bg = COLOR_BLACK,
        widget = wibox.container.background,
    }

    local profile_label = wibox.widget {
        make_text("Power Profile", COLOR_GREY),
        left = dpi(10), top = dpi(8), bottom = dpi(4),
        widget = wibox.container.margin,
    }

    -- charge mode toggle: shows current HP battery health policy;
    -- click flips between 80% cap and HP managed (full charge)
    charge_mode_text = make_text(charge_mode_label(read_charge_mode() or "auto"), COLOR_WHITE)
    charge_mode_btn = wibox.widget {
        {
            charge_mode_text,
            halign = "center",
            valign = "center",
            fill_horizontal = true,
            widget = wibox.container.place,
        },
        forced_width = CONTENT_W,
        bg = COLOR_BLACK,
        fg = COLOR_WHITE,
        widget = wibox.container.background,
    }
    charge_mode_btn:connect_signal("mouse::enter", guarded(function()
        charge_mode_btn.bg = COLOR_HOVER
    end))
    charge_mode_btn:connect_signal("mouse::leave", guarded(function()
        charge_mode_btn.bg = COLOR_BLACK
    end))
    charge_mode_btn:buttons(gears.table.join(awful.button({}, 1, guarded(toggle_charge_mode))))

    local charge_mode_label_widget = wibox.widget {
        make_text("Charge Mode", COLOR_GREY),
        left = dpi(10), top = dpi(8), bottom = dpi(4),
        widget = wibox.container.margin,
    }

    return wibox.widget {
        header,
        info_block,
        separator(),
        profile_label,
        profile_list,
        separator(),
        charge_mode_label_widget,
        charge_mode_btn,
        layout = wibox.layout.fixed.vertical,
    }
end


-- MARK: REFRESH

local function refresh_popup()
    local i = battery_info()
    pct_text.text = i.pct .. "%"
    status_text.text = i.status
    ac_text.text = (i.ac == "1") and "Plugged in (AC)" or "On battery"

    energy_text.text = string.format("%.1f / %.1f Wh",
        i.energy_now / 1e6, i.energy_full / 1e6)

    local health = (i.energy_design > 0)
        and math.floor(i.energy_full / i.energy_design * 100) or nil
    health_text.text = (health and ("Health " .. health .. "%  ·  ") or "")
        .. i.cycles .. " cycles"

    local draw = i.power_now / 1e6
    if i.status == "Discharging" and i.power_now > 0 then
        local t = fmt_time(i.energy_now / i.power_now)
        rate_text.text = string.format("Discharging %.1f W%s", draw,
            t and ("  ·  " .. t .. " left") or "")
    elseif i.status == "Charging" and i.power_now ~= 0 then
        rate_text.text = string.format("Charging at %.1f W", math.abs(draw))
    else
        rate_text.text = ""
    end

    awful.spawn.easy_async("powerprofilesctl get", guarded(function(out)
        local got = (out or ""):gmatch("[^\r\n]+")()
        if got then
            active_profile = got
            for _, b in ipairs(profile_buttons) do b:paint() end
        end
    end))

    -- refresh charge mode display
    local mode = read_charge_mode()
    if mode and charge_mode_text then
        current_charge_mode = mode
        charge_mode_text.text = charge_mode_label(mode)
    end
end


-- MARK: POPUP

local function ensure_popup()
    if popup then return end
    local style = popup_common.popup_style()
    popup = awful.popup {
        widget   = build_content(),
        visible  = false,
        ontop    = true,
        bg       = COLOR_BLACK,
        border_width = style.border_width,
        border_color = COLOR_GOLD,
        shape = style.shape,
    }
end

hide = function()
    if not popup or not popup.visible then return end
    popup_common.hide(popup)
end

local function show(anchor)
    ensure_popup()
    if popup.visible then return end
    awesome.emit_signal("popup::opening")
    refresh_popup()
    popup_common.show_placement(popup, anchor, { is_pinned = is_pinned, hide = hide })
end

local function toggle(anchor)
    ensure_popup()
    if popup.visible then hide() else show(anchor) end
end


-- MARK: ATTACH

-- Wire left-click toggle (and right-click dismiss) on a battery widget. Safe
-- to call once per screen; all widgets share the single popup.
function M.attach(widget)
    ensure_popup()
    widget:buttons(gears.table.join(
        awful.button({}, 1, function()
            -- widget_press arms the wibar handler's ignore flag and returns
            -- true if that handler already closed the popup on this press
            if not popup_common.widget_press(popup) then toggle(widget) end
        end),
        awful.button({}, 3, hide)
    ))
end

-- close this popup when any other popup opens
popup_common.register_closer(hide)

return M
