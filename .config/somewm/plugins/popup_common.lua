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
local mouse = mouse    -- capi global, for widget geometry capture at press time
local capi_mousegrabber = mousegrabber  -- capi global, drives the header drag

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
    local btn = wibox.widget { glyph, widget = wibox.container.background }
    awful.tooltip { objects = { btn }, text = "Keep open when clicking elsewhere" }
    -- hover feedback: a translucent purple wash + white glyph so the pin
    -- reads as interactive while the pointer is over it
    local hovering = false
    local hover_bg = COLOR_PURPLE .. "33"
    local function paint()
        local color = hovering and COLOR_WHITE or (state and COLOR_GOLD or COLOR_GREY)
        glyph.markup = string.format('<span foreground="%s">󰐃</span>', color)
        btn.bg = hovering and hover_bg or nil
    end
    btn:connect_signal("mouse::enter", function() hovering = true; paint() end)
    btn:connect_signal("mouse::leave", function() hovering = false; paint() end)
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

-- compute the anchor widget's absolute screen rectangle from a widget
-- geometry table (as returned by mouse.current_widget_geometry). somewm's
-- find_widgets reports x/y in drawable-surface coords (wibox-relative,
-- inside the border); the wibox's global position + border must be added —
-- the same offset awful.placement applies internally (placement.lua:770).
-- returns nil when the input is insufficient for manual placement
function M.abs_anchor_rect(widget_geo)
    if not widget_geo or not widget_geo.width or not widget_geo.height then
        return nil
    end
    local ox, oy = 0, 0
    local d = widget_geo.drawable
    local wb = d and d.get_wibox and d.get_wibox()
    if wb then
        local dg = wb:geometry()
        local bw = wb.border_width or 0
        ox, oy = dg.x + bw, dg.y + bw
    end
    return {
        x = ox + widget_geo.x,
        y = oy + widget_geo.y,
        width = widget_geo.width,
        height = widget_geo.height,
    }
end

-- place `popup` next to an anchor widget whose absolute rectangle is `rect`
-- (screen coords). prefers above + right-aligned (back), flipping below when
-- above won't fit, and clamps to the screen workarea. opts mirror the
-- awful.placement.next_to names so callers can override. returns false when
-- rect is missing so the caller can fall back to awful.placement.next_to
function M.place_next_to(popup, rect, opts)
    opts = opts or {}
    if not rect or rect.width == 0 then return false end
    local s = popup.screen
    local wa = s and s.workarea
    -- read the popup's actual rendered size from its width/height properties
    -- (set by awful.popup's internal _apply_size_now), not popup:geometry()
    -- which can return stale/zero values before the first layout flush
    local pw = popup.width or 0
    local ph = popup.height or 0
    if pw == 0 or ph == 0 then return false end
    local pref_pos   = opts.preferred_positions or "top"
    local pref_anchor = opts.preferred_anchors or "back"
    local x, y
    if pref_pos == "top" then
        y = rect.y - ph
        if wa and y < wa.y then y = rect.y + rect.height end
    else
        y = rect.y + rect.height
        if wa and y + ph > wa.y + wa.height then y = rect.y - ph end
    end
    if pref_anchor == "back" then
        x = rect.x + rect.width - pw
    else
        x = rect.x
    end
    if wa then
        if x < wa.x then x = wa.x end
        if x + pw > wa.x + wa.width then x = wa.x + wa.width - pw end
        if y < wa.y then y = wa.y end
        if y + ph > wa.y + wa.height then y = wa.y + wa.height - ph end
    end
    -- set position and size atomically via :geometry() (like awful.placement
    -- does internally). callers invoke this while the popup is still
    -- invisible so the drawin never maps at the screen origin (see
    -- show_placement for why that matters on somewm)
    popup:geometry { x = x, y = y, width = pw, height = ph }
    return true
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
    -- use the geometry captured at button-press time; falls back to the
    -- current mouse state for callers that didn't capture (e.g. programmatic)
    local widget_geo   = popup._anchor_geo or mouse.current_widget_geometry
    local anchor_screen = popup._anchor_screen or (mouse.current_wibox and mouse.current_wibox.screen)
    popup:_apply_size_now(false)
    local is_detached = opts.detached and opts.detached()
    if not is_detached then
        -- ensure the popup is on the same screen as the clicked wibar widget,
        -- otherwise workarea clamping uses the wrong screen
        if anchor_screen then popup.screen = anchor_screen end
        -- place BEFORE mapping: somewm's drawin_set_visible auto-expands a
        -- drawin that maps at the screen origin with over-screen size to the
        -- full screen. set_screen parks the drawin at the origin, so placing
        -- after visible=true let that shrink inflate the popup and clobber
        -- the anchor position (the top-left full-height column bug)
        if opts.placement then
            opts.placement(popup, anchor)
        else
            -- manual placement: compute the anchor's absolute screen rect and
            -- position the popup directly, bypassing awful.placement.next_to
            -- (which reads mouse.current_widget_geometry internally and breaks
            -- for async popups where the mouse state is stale by placement time,
            -- and which clamps to the wrong screen's workarea on multi-monitor)
            local rect = M.abs_anchor_rect(widget_geo)
            if not rect or not M.place_next_to(popup, rect, opts) then
                awful.placement.next_to(popup, {
                    geometry = widget_geo,
                    preferred_positions = opts.preferred_positions or "top",
                    preferred_anchors = opts.preferred_anchors or "back",
                    honor_workarea = true,
                })
            end
        end
    end
    popup.visible = true
    local skip_outside = is_detached or (opts.is_pinned and opts.is_pinned())
    if not skip_outside then
        M.outside_click_setup(popup, hide, opts.also_release)
    end
    popup._escape_key = awful.key({}, "Escape", hide)
    if root._append_key then root._append_key(popup._escape_key) end
end

-- keep a widget's hover_border outline drawn while the popup is visible.
-- wrappers that don't implement set_sticky_hover are ignored, so this is
-- safe to call with any attach target
function M.sticky_border(popup, widget)
    popup:connect_signal("property::visible", guarded(function()
        if widget.set_sticky_hover then widget:set_sticky_hover(popup.visible) end
    end))
end

-- wire left-click toggle (and optional right-click dismiss / scroll-swallow)
-- on a wibar widget. on_left(widget) is the toggle callback. opts:
--   right_hide     function  called on right-click (default: opts.hide)
--   swallow_scroll bool      swallow wibar click while scrolling (volume_popup)
--   highlight      widget    hover_border wrapper to outline while the popup
--                            is open (default: the attached widget itself)
function M.attach(popup, widget, on_left, opts)
    opts = opts or {}
    M.sticky_border(popup, opts.highlight or widget)
    widget:connect_signal("button::press", guarded(function(_, _, _, pressed)
        if pressed == 1 then
            -- capture the widget geometry and screen at press time, before
            -- the popup becomes visible or async refresh runs. placement.next_to
            -- ignores the widget= arg and reads mouse.current_widget_geometry,
            -- which can be nil by the time the async callback fires
            popup._anchor_geo    = mouse.current_widget_geometry
            popup._anchor_screen = mouse.current_wibox and mouse.current_wibox.screen
            popup._anchor_wibox  = mouse.current_wibox
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


-- // MARK -- DRAGGABLE HEADER


-- Build a popup header carrying a title (drag handle) and a pin button, plus
-- all the detach/drag state machinery. This centralises the
-- behaviour first developed in resource_popup so every wibar popup can float
-- free and be dragged by its title with one call.
--
-- opts:
--   popup        awful.popup   the popup (must already be constructed)
--   name         string        pin-persistence key (e.g. "battery_popup")
--   title        string        header title text
--   width        number        forced header width (the popup's CONTENT_W)
--   hide         function      close callback (also stops caller timers etc.)
--   also_release bool          pass to outside_click_setup (ontop focus transfer)
--   on_pin       function(on)  optional extra hook run after a pin change
--
-- returns the header widget and a controller table:
--   ctrl.is_pinned()      -> bool
--   ctrl.is_detached()    -> bool
--   ctrl.set_detached(on)
--   ctrl.start_drag()
--   ctrl.place(anchor)       place popup next to anchor (respects captured geo)
--   ctrl.show_opts()         {is_pinned, detached, hide} for show_placement
--   ctrl.set_anchor(anchor)  record which widget the popup is anchored to
--   ctrl.toggle(anchor, show_fn)  generic toggle handling detach + re-anchor
function M.draggable_header(opts)
    -- popup is captured by reference through a holder table so callers can
    -- construct the awful.popup with the returned header widget as its
    -- `widget` arg (which awful.popup requires at construction) and then
    -- assign holder.popup afterwards; the closures below read holder.popup
    -- at runtime so they see the assigned popup
    local holder     = opts.holder or {}
    local name        = opts.name
    local width       = opts.width
    local hide        = opts.hide
    local also_release = opts.also_release
    local on_pin_hook  = opts.on_pin

    local detached = false
    local current_anchor
    -- forward-declared so the pin callback and start_drag (defined below)
    -- close over this local rather than the global; assigned at the end
    local ctrl
    -- real stay-open pref captured before detach drives the pin gold; restored
    -- on re-anchor so floating doesn't clobber the saved preference
    local pin_state_before_detach

    -- read the popup from the holder so closures see the post-construction
    -- assignment; nil before the popup is constructed (all runtime guards
    -- already check for nil)
    local function popup() return holder.popup end

    -- pin toggle: gold = stays open on outside clicks, grey = any outside
    -- click closes it. the on_change wires outside-click detection and the
    -- detach interaction (un-pinning while floating re-anchors). set_pin is
    -- forward-declared: the callback runs inside the M.pin call that
    -- produces it, so a plain local in the same assignment would still be
    -- out of scope there
    local set_pin
    local pin_btn, is_pinned
    pin_btn, is_pinned, set_pin = M.pin(name, function(on)
        -- un-pinning while floating is a close gesture, not a preference
        -- change: the click already persisted the toggle, so restore the
        -- pre-detach pref to disk, then re-anchor (set_detached(false) hides)
        if not on and detached then
            set_pin(pin_state_before_detach ~= false, true, false)
            ctrl.set_detached(false)
            return
        end
        local p = popup()
        if not on then
            -- un-pinning an anchored popup is a close gesture: with no
            -- stay-open behaviour left, the popup has no reason to stay up
            if p and p.visible then hide() end
            return
        end
        if p and p.visible then
            M.outside_click_teardown(p)
        end
        if on_pin_hook then on_pin_hook(on) end
    end)

    -- set_pin drives the pin icon from set_detached: a detached popup is
    -- sticky, so the pin shows gold. transient (not persisted) so re-anchoring
    -- restores the pref captured in pin_state_before_detach
    local function set_sticky(on)
        set_pin(on, false, false)
    end

    -- the title and the stretch beside it are the drag handle; the buttons
    -- on the right sit outside the handle so they keep their own clicks. a
    -- space textbox gives the stretchy middle real geometry to receive
    -- button::press, else an empty container can miss the press on somewm
    local title_w = wibox.widget {
        text = opts.title,
        fg = M.theme.WHITE,
        font = FONT_HEAD,
        widget = wibox.widget.textbox,
    }
    local drag_area = wibox.widget {
        { text = " ", widget = wibox.widget.textbox },
        bg = "#00000000",
        widget = wibox.container.background,
    }
    local function on_drag_press(_, _, _, button)
        if button == 1 then ctrl.start_drag() end
    end
    title_w:connect_signal("button::press", on_drag_press)
    drag_area:connect_signal("button::press", on_drag_press)

    local header = wibox.widget {
        {
            {
                title_w,
                drag_area,
                {
                    pin_btn,
                    spacing = dpi(6),
                    layout = wibox.layout.fixed.horizontal,
                },
                layout = wibox.layout.align.horizontal,
            },
            left = dpi(10), right = dpi(10),
            top = dpi(6), bottom = dpi(6),
            widget = wibox.container.margin,
        },
        bg = M.theme.PURPLE,
        widget = wibox.container.background,
    }
    -- a fixed content-width popup pins the header to that width so the purple
    -- bar sets the popup's width floor; a min/max-width popup (media) omits
    -- `width` so the header stretches to whatever the rows settle on
    if width then header.forced_width = width end

    -- drag the popup by its header: a mousegrabber tracks the pointer until
    -- the left button releases. entering the grabber also engages detach so
    -- the popup stays where it is dropped. the 10s safety timer mirrors
    -- tag_pager's: a missed release can never leave the grabber swallowing all
    -- pointer input. position is set via a single popup:geometry{x,y} call:
    -- omitting width/height skips the widget-tree refit that caused the old
    -- drag judder, while one configure per move halves the property::x/y
    -- signal traffic of separate x/y sets. drag_begin/drag_end let popups
    -- pause their own refresh timers so a graph rebuild can't hitch mid-drag
    local drag_gen = 0
    local function start_drag()
        local p = popup()
        if not p or not p.visible then return end
        if not detached then ctrl.set_detached(true) end
        drag_gen = drag_gen + 1
        local gen = drag_gen
        local off_x, off_y
        local geo = { x = 0, y = 0 }
        p:emit_signal("popup::drag_begin")
        -- suspend shape re-application for the drag: property::geometry fires
        -- on every move and somewm's _apply_shape rebuilds three full-size
        -- cairo masks per event (~3ms on a tall popup) even though the shape
        -- only depends on size, which cannot change while dragging. it is
        -- reconnected and reapplied once when the drag ends
        local shape_fn = p._apply_shape
        if shape_fn then p:disconnect_signal("property::geometry", shape_fn) end
        local safety
        local function end_drag()
            if safety then safety:stop() end
            local pp = popup()
            if pp then
                if shape_fn then
                    pp:connect_signal("property::geometry", shape_fn)
                    shape_fn(pp)
                end
                pp:emit_signal("popup::drag_end")
            end
        end
        safety = gears.timer {
            timeout = 10, single_shot = true,
            callback = guarded(function()
                if capi_mousegrabber.isrunning and capi_mousegrabber.isrunning() then
                    capi_mousegrabber.stop()
                end
                -- grabber killed externally: the callback never runs again,
                -- so drag_end must be emitted from here too
                end_drag()
            end),
        }
        capi_mousegrabber.run(function(m)
            if gen ~= drag_gen then end_drag() return false end
            if not (m.buttons and m.buttons[1]) then end_drag() return false end
            local pp = popup()
            if not pp or not pp.visible then end_drag() return false end
            if not off_x then
                local g = pp:geometry()
                off_x = m.x - g.x
                off_y = m.y - g.y
            end
            -- move the drawin directly: x/y only, so no widget refit, and the
            -- reused table keeps the grabber allocation-free
            geo.x = m.x - off_x
            geo.y = m.y - off_y
            pp:geometry(geo)
            return true
        end, "fleur")
    end

    local function set_detached(on)
        if detached == on then return end
        detached = on
        -- detached implies sticky: while floating free the popup also ignores
        -- outside clicks so it stays open until explicitly re-anchored. the pin
        -- icon is driven to gold to reflect this; the pin's persisted state is
        -- left untouched (set_sticky passes persist=false) so re-anchoring
        -- restores the user's actual stay-open preference
        if on then pin_state_before_detach = is_pinned() end
        set_sticky(on or pin_state_before_detach ~= false)
        local p = popup()
        if p and p.visible then
            if on then M.outside_click_teardown(p)
            elseif not is_pinned() then M.outside_click_setup(p, hide, also_release) end
        end
        if not on and p and p.visible then hide() end
    end

    local function place(anchor)
        local p = popup()
        if p._anchor_screen then p.screen = p._anchor_screen end
        local rect = M.abs_anchor_rect(
            p._anchor_geo or mouse.current_widget_geometry)
        if not rect or not M.place_next_to(p, rect, {
            preferred_positions = "top", preferred_anchors = "back",
        }) then
            awful.placement.next_to(p, {
                geometry = p._anchor_geo or mouse.current_widget_geometry,
                preferred_positions = "top",
                preferred_anchors = "back",
                honor_workarea = true,
            })
        end
    end

    local function show_opts()
        return {
            is_pinned = is_pinned,
            detached = function() return detached end,
            also_release = also_release,
            hide = hide,
        }
    end

    local function set_anchor(anchor)
        current_anchor = anchor
    end

    local function toggle(anchor, show_fn)
        local p = popup()
        if not p.visible then
            show_fn(anchor)
        elseif anchor == current_anchor then
            hide()
        elseif not detached then
            current_anchor = anchor
            place(anchor)
        end
        -- else: detached + different anchor -> leave it floating
    end

    ctrl = {
        header = header,
        holder = holder,
        is_pinned = is_pinned,
        is_detached = function() return detached end,
        set_detached = set_detached,
        start_drag = start_drag,
        place = place,
        show_opts = show_opts,
        set_anchor = set_anchor,
        toggle = toggle,
    }
    return header, ctrl
end


return M
