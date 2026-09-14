-- plugins/popup_common.lua
-- Shared machinery for the wibar popups' "stay open vs close on outside
-- click" pin toggle, plus the click-ordering flags that keep a single press
-- from both closing (wibar handler) and reopening (widget handler) a popup.
--
-- outside-click detection: root.buttons() is X11-only and unavailable on
-- somewm, so the bare desktop can't be watched; clicks on client windows and
-- the wibar background are caught instead.

local awful   = require("awful")
local gears   = require("gears")
local wibox   = require("wibox")
local beautiful = require("beautiful")
local gfilesystem = require("gears.filesystem")
local gshape  = require("gears.shape")
local guarded = require("error_guard")
local font_utils = require("rc.font_utils")

local client = client  -- capi global, captured for outside-click detection
local root = root

local function get_xresources()
    if beautiful.xresources then return beautiful.xresources end
    local ok, xr = pcall(require, "beautiful.xresources")
    if ok then return xr end
    return nil
end
local dpi = (get_xresources() and get_xresources().apply_dpi) or function(v) return v end

local M = {}

-- shared theme colours and scaled fonts. the popup family previously
-- redefined these in every file; they now live here so the values track
-- beautiful and rc.font_utils in one place.
local COLOR_GOLD  = (beautiful.main_gold and beautiful.main_gold.base) or "#FFD700"
local COLOR_GREY  = "#AAAAAA"
local COLOR_PURPLE = (beautiful.main_purple and beautiful.main_purple.base) or "#623997"

M.theme = {
    GOLD   = COLOR_GOLD,
    GREY   = COLOR_GREY,
    PURPLE = COLOR_PURPLE,
    BLACK  = "#000000",
    WHITE  = "#FFFFFF",
    RED    = "#FF6B6B",
    GREEN  = "#69D665",
    HOVER  = "#ffffff33",
}

M.fonts = {
    FONT       = font_utils.FONT,
    FONT_BOLD  = font_utils.FONT_BOLD,
    FONT_HEAD  = font_utils.FONT_HEAD,
    FONT_MONO  = font_utils.FONT_MONO,
    FONT_SMALL = font_utils.FONT_SMALL,
    FONT_INFO  = font_utils.FONT_INFO,
    FONT_VALUE = font_utils.FONT_VALUE,
    FONT_HUGE  = font_utils.FONT_HUGE,
    FONT_STAR  = font_utils.FONT_STAR,
    FONT_CLEAR = font_utils.FONT_CLEAR,
}

-- keep FONT_HEAD alias for the pin widget below
local FONT_HEAD = font_utils.FONT_HEAD


-- MARK: PREF

local function pref_path(name)
    return gfilesystem.get_cache_dir() .. name .. "_stay_open"
end

function M.load_stay_open(name)
    local f = io.open(pref_path(name), "r")
    if not f then return true end
    local v = f:read("*l")
    f:close()
    return v ~= "0"
end

function M.save_stay_open(name, state)
    local f = io.open(pref_path(name), "w")
    if f then f:write(state and "1" or "0") f:close() end
end


-- MARK: PIN

-- pin glyph for a popup header: gold = stays open on outside clicks (the
-- default), grey = any outside click closes it. returns the button widget, a
-- getter for the current state, and a setter. on_change(state) runs after
-- user clicks and after setter calls that opt into it (run_cb). the setter's
-- persist flag controls whether the new state is written to disk; pass false
-- for a transient visual override (e.g. reflecting a detached popup) that
-- should not outlive a reload
function M.pin(name, on_change)
    local state = M.load_stay_open(name)
    local glyph = wibox.widget {
        align = "center",
        valign = "center",
        font = FONT_HEAD,
        widget = wibox.widget.textbox,
    }
    local function paint()
        -- somewm's textbox has no fg property; colour via pango markup
        glyph.markup = string.format('<span foreground="%s">󰐃</span>',
            state and COLOR_GOLD or COLOR_GREY)
    end
    local btn = wibox.widget { glyph, widget = wibox.container.background }
    awful.tooltip { objects = { btn }, text = "Keep open when clicking elsewhere" }
    local function set(new_state, persist, run_cb)
        if state == new_state and not persist then return end
        state = new_state
        if persist then M.save_stay_open(name, state) end
        paint()
        if run_cb and on_change then on_change(state) end
    end
    btn:buttons(gears.table.join(awful.button({}, 1, guarded(function()
        set(not state, true, true)
    end))))
    paint()
    return btn, function() return state end, set
end


-- MARK: CLICK FLAGS

-- call from the toggle widget's own press handler BEFORE toggling. returns
-- true when the wibar outside-click handler already ran for this press and
-- closed the popup — in that case the toggle must be skipped or it would
-- immediately reopen
function M.widget_press(popup)
    if not popup then return false end
    -- consumed by the wibar button::press/release handlers fired by this same
    -- click. the press flag is cleared next mainloop iteration so it can
    -- never go stale; the release flag must persist until consumed or the
    -- handlers are torn down, because the release event can arrive after a
    -- mainloop pass and would otherwise see a visible popup and close it
    popup._ignore_wibar = true
    popup._ignore_wibar_release = true
    gears.timer.delayed_call(function() popup._ignore_wibar = false end)
    if popup._press_closed then
        popup._press_closed = false
        return true
    end
    return false
end

-- mark the current press as "inside" without toggling (e.g. scrolling on the
-- toggle widget while the popup is open)
function M.swallow_next_wibar_click(popup)
    if popup then
        popup._ignore_wibar = true
        popup._ignore_wibar_release = true
    end
end


-- MARK: OUTSIDE CLICK

-- also_release: additionally listen for button::release on the wibar. when
-- the popup is ontop, the compositor can consume the first button::press to
-- transfer focus from the popup layer, so the press signal never fires; the
-- release still fires after the focus transfer, closing the popup on the
-- first click instead of requiring two
function M.outside_click_setup(popup, hide_fn, also_release)
    popup._client_click_handler = function() hide_fn() end
    client.connect_signal("button::press", popup._client_click_handler)
    popup._screen_handlers = {}
    for s in screen do
        if s.mywibox then
            local handler = function()
                if not popup.visible then return end
                if popup._ignore_wibar then
                    popup._ignore_wibar = false
                    return
                end
                hide_fn()
                -- the toggle widget's press handler may still run for this
                -- same click; stop it from reopening what we just closed
                popup._press_closed = true
                gears.timer.delayed_call(function() popup._press_closed = false end)
            end
            local entry = { wibox = s.mywibox, handler = handler }
            s.mywibox:connect_signal("button::press", handler)
            if also_release then
                local release_handler = function()
                    if not popup.visible then return end
                    if popup._ignore_wibar_release then
                        popup._ignore_wibar_release = false
                        return
                    end
                    hide_fn()
                end
                s.mywibox:connect_signal("button::release", release_handler)
                entry.release_handler = release_handler
            end
            table.insert(popup._screen_handlers, entry)
        end
    end
end

function M.outside_click_teardown(popup)
    if not popup then return end
    if popup._client_click_handler then
        client.disconnect_signal("button::press", popup._client_click_handler)
        popup._client_click_handler = nil
    end
    if popup._screen_handlers then
        for _, entry in ipairs(popup._screen_handlers) do
            entry.wibox:disconnect_signal("button::press", entry.handler)
            if entry.release_handler then
                entry.wibox:disconnect_signal("button::release", entry.release_handler)
            end
        end
        popup._screen_handlers = nil
    end
    popup._ignore_wibar = false
    popup._ignore_wibar_release = false
    popup._press_closed = false
end


-- MARK: SHARED WIDGET HELPERS


-- textbox helper shared by the popup family (was duplicated verbatim in
-- volume_popup, brightness_popup and resource_popup)
function M.make_text(text, fg, font)
    return wibox.widget {
        text  = text or "",
        fg    = fg or M.theme.WHITE,
        font  = font or M.fonts.FONT,
        align = "left",
        valign = "center",
        widget = wibox.widget.textbox,
    }
end

-- full-width separator line. width is the already-dpi'd content width of the
-- popup (each popup keeps its own CONTENT_W)
function M.separator(width, color)
    return wibox.widget {
        forced_height = dpi(1),
        forced_width  = width,
        bg = color or M.theme.PURPLE,
        widget = wibox.container.background,
    }
end

-- standard popup border width + rounded-rect shape, shared by every popup
function M.popup_style()
    return {
        border_width = beautiful.bar_edge_width or beautiful.border_width or dpi(1),
        shape = function(cr, w, h)
            gshape.rounded_rect(cr, w, h, beautiful.border_radius or dpi(3))
        end,
    }
end


-- MARK: POPUP LIFECYCLE


-- standard hide: clear the showing flag, tear down outside-click + escape key.
-- callers with extra cleanup (e.g. resource_popup clearing its anchor) do that
-- before calling this
function M.hide(popup)
    if not popup then return end
    popup._showing = false
    if not popup.visible then return end
    popup.visible = false
    M.outside_click_teardown(popup)
    if popup._escape_key then
        if root._remove_key then root._remove_key(popup._escape_key) end
        popup._escape_key = nil
    end
end

-- standard show scaffolding: size, reveal, place, install outside-click and
-- escape key. the caller emits "popup::opening" and refreshes content first,
-- then calls this (synchronously, or from inside an async refresh callback).
-- opts:
--   is_pinned      function() -> bool   skip outside-click when true
--   also_release   bool                 pass to outside_click_setup (ontop focus transfer)
--   detached       function() -> bool   skip placement + outside-click (resource_popup)
--   hide           function              escape-key + outside-click callback (defaults to M.hide)
--   placement      function(popup, anchor)  override default next_to placement
function M.show_placement(popup, anchor, opts)
    opts = opts or {}
    local hide = opts.hide or function() M.hide(popup) end
    popup:_apply_size_now(false)
    popup.visible = true
    local is_detached = opts.detached and opts.detached()
    if opts.placement then
        opts.placement(popup, anchor)
    elseif not is_detached then
        awful.placement.next_to(popup, {
            widget = anchor,
            preferred_positions = opts.preferred_positions or "top",
            preferred_anchors = opts.preferred_anchors or "back",
            honor_workarea = true,
        })
    end
    local skip_outside = is_detached or (opts.is_pinned and opts.is_pinned())
    if not skip_outside then
        M.outside_click_setup(popup, hide, opts.also_release)
    end
    popup._escape_key = awful.key({}, "Escape", hide)
    if root._append_key then root._append_key(popup._escape_key) end
end

-- wire left-click toggle (and optional right-click dismiss / scroll-swallow)
-- on a wibar widget. on_left(widget) is the toggle callback. opts:
--   right_hide     function  called on right-click (default: opts.hide)
--   swallow_scroll bool      swallow wibar click while scrolling (volume_popup)
function M.attach(popup, widget, on_left, opts)
    opts = opts or {}
    widget:connect_signal("button::press", guarded(function(_, _, _, pressed)
        if pressed == 1 then
            if not M.widget_press(popup) then on_left(widget) end
        elseif pressed == 3 and opts.right_hide then
            opts.right_hide()
        elseif (pressed == 4 or pressed == 5) and popup and popup.visible and opts.swallow_scroll then
            M.swallow_next_wibar_click(popup)
        end
    end))
end

-- register the "close this popup when any other popup opens" handler. the
-- hide callback must be safe to call when the popup is not visible (it should
-- no-op in that case). returns the connection so the caller can disconnect it
function M.register_closer(hide)
    return awesome.connect_signal("popup::opening", guarded(function()
        hide()
    end))
end


return M
