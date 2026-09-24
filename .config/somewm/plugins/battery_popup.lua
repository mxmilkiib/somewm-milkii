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
local CONTENT_W  = dpi(240)   -- fixed popup content width (full-width rows)

local M = {}

local POWER_PROFILES = {
    { key = "performance", label = "Performance" },
    { key = "balanced",    label = "Balanced" },
    { key = "power-saver", label = "Power Saver" },
}

local popup
-- holder table: draggable_header reads popup from here so build_content can
-- run before the awful.popup is constructed (awful.popup requires a widget arg)
local popup_holder = {}
local profile_buttons = {}
local active_profile  = nil
-- forward declarations: `hide` is referenced by the draggable_header
-- controller before assignment; `ctrl` is built in build_content once the
-- popup exists
local hide
local ctrl

-- charge mode state: "maximize" (80% cap) or "auto" (HP managed / full)
local charge_mode_text, charge_mode_hint_text, charge_mode_btn
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
        voltage    = num(bat .. "/voltage_now") or 0,       -- µV
        cycles     = read_file(bat .. "/cycle_count") or "?",
        ac         = read_file("/sys/class/power_supply/AC/online"),
    }
end

-- HP adaptive battery state from firmware-attributes. "Activated" means the
-- adaptive algorithm is actively intervening (holding/reducing charge); "Not
-- Activated" means it is enabled but has not triggered. Read-only.
local ADAPTIVE_STATUS_ATTR = "/sys/class/firmware-attributes/hp-bioscfg/attributes/Adaptive Battery Optimizer Status/current_value"
local FAST_CHARGE_ATTR     = "/sys/class/firmware-attributes/hp-bioscfg/attributes/Fast Charge/current_value"

local function read_adaptive_status()
    return read_file(ADAPTIVE_STATUS_ATTR)
end

local function read_fast_charge()
    return read_file(FAST_CHARGE_ATTR)
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

-- HP firmware rejects runtime WMI writes to Battery Health Manager with
-- error 0x4 ("Invalid command type"). The mode can only be changed in BIOS
-- setup (F10 at boot > Power > Battery Health Manager). The popup shows
-- the current mode as a read-only display with a BIOS hint.
local function charge_mode_hint(mode)
    if mode == "maximize" then return "80% cap - change in BIOS"
    elseif mode == "auto" then return "HP managed - change in BIOS"
    else return "Set in BIOS (F10 at boot)" end
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
    voltage_text = make_text("")
    adaptive_text = make_text("")

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
        voltage_text,
        adaptive_text,
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

    -- header (title drag handle + detach + pin) and the detach/drag controller
    -- come from popup_common so this popup can float and be dragged like the
    -- rest of the wibar popups
    local header
    header, ctrl = popup_common.draggable_header {
        holder = popup_holder,
        name  = "battery_popup",
        title = "Battery",
        width = CONTENT_W,
        hide  = function() hide() end,
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

    -- charge mode: read-only display (HP firmware rejects runtime writes;
    -- change in BIOS setup). Shows current mode + hint below.
    local mode = read_charge_mode() or "auto"
    charge_mode_text = make_text(charge_mode_label(mode), COLOR_WHITE)
    charge_mode_hint_text = make_text(charge_mode_hint(mode), COLOR_GREY)
    -- old: the rows sat in a wibox.container.place (halign/valign center,
    --      fill_horizontal) as the row's outermost widget with dead bg/fg
    --      properties on it — it rendered as a 1px line under somewm, so
    --      this now mirrors info_block's background > margin structure
    charge_mode_btn = wibox.widget {
        {
            {
                charge_mode_text,
                charge_mode_hint_text,
                layout = wibox.layout.fixed.vertical,
                spacing = dpi(2),
            },
            left = dpi(10), right = dpi(10),
            top = dpi(4), bottom = dpi(8),
            widget = wibox.container.margin,
        },
        forced_width = CONTENT_W,
        bg = COLOR_BLACK,
        widget = wibox.container.background,
    }

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

    -- energy now / full, with design in parens if trimmed (shows the
    -- Intelligent Charging capacity reduction when energy_full < design)
    if i.energy_design > 0 and i.energy_full < i.energy_design then
        local trim_pct = math.floor((1 - i.energy_full / i.energy_design) * 100)
        energy_text.text = string.format("%.1f / %.1f Wh  (trim %d%%, design %.1f)",
            i.energy_now / 1e6, i.energy_full / 1e6, trim_pct,
            i.energy_design / 1e6)
    else
        energy_text.text = string.format("%.1f / %.1f Wh",
            i.energy_now / 1e6, i.energy_full / 1e6)
    end

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

    -- voltage (cell voltage in V; useful for health diagnosis)
    if i.voltage > 0 then
        voltage_text.text = string.format("%.2f V", i.voltage / 1e6)
    else
        voltage_text.text = ""
    end

    -- adaptive battery optimizer status + fast charge: tells you if the HP
    -- adaptive algorithm is actively intervening (Activated) or idle
    local adapt = read_adaptive_status()
    local fast = read_fast_charge()
    local parts = {}
    if adapt and adapt ~= "" then
        table.insert(parts, "Adaptive: " .. adapt)
    end
    if fast and fast ~= "" then
        table.insert(parts, "Fast Charge: " .. fast)
    end
    adaptive_text.text = table.concat(parts, "  ·  ")

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
        if charge_mode_hint_text then
            charge_mode_hint_text.text = charge_mode_hint(mode)
        end
    end
end


-- MARK: POPUP

local function ensure_popup()
    if popup then return end
    local style = popup_common.popup_style()
    -- build content first so the awful.popup constructor gets its required
    -- widget arg; draggable_header reads popup via popup_holder, assigned
    -- right after construction
    local content = build_content()
    popup = awful.popup {
        -- awful.popup sizes the drawin by fitting the widget tree at
        -- unbounded width, but long info lines wrap once laid out at
        -- CONTENT_W — the drawin ends up short by the wrapped-line growth
        -- and the fixed.vertical clips the last row (Charge Mode) to a few
        -- px. Capping the fit width makes the popup height account for
        -- wrapped lines.
        widget   = wibox.widget {
            content,
            strategy = "max",
            width    = CONTENT_W,
            widget   = wibox.container.constraint,
        },
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
    if not popup or not popup.visible then return end
    popup_common.hide(popup)
end

local function show(anchor)
    ensure_popup()
    if popup.visible then return end
    ctrl.set_anchor(anchor)
    awesome.emit_signal("popup::opening")
    refresh_popup()
    popup_common.show_placement(popup, anchor, ctrl.show_opts())
end

local function toggle(anchor)
    ensure_popup()
    ctrl.toggle(anchor, show)
end


-- MARK: ATTACH

-- Wire left-click toggle (and right-click dismiss) on a battery widget. Safe
-- to call once per screen; all widgets share the single popup.
function M.attach(widget)
    ensure_popup()
    popup_common.sticky_border(popup, widget)
    widget:buttons(gears.table.join(
        awful.button({}, 1, function()
            -- capture geometry at press time (see popup_common.attach comment)
            popup._anchor_geo    = mouse.current_widget_geometry
            popup._anchor_screen = mouse.current_wibox and mouse.current_wibox.screen
            popup._anchor_wibox  = mouse.current_wibox
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
