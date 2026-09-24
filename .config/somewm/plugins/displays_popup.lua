-- plugins/displays_popup.lua
-- Monitor management popup, opened by middle-clicking the wibar brightness
-- widget. Lists every output the compositor reports with enable/primary
-- toggles and mode/scale/transform/adaptive-sync cyclers, topped by a
-- draggable mini-map of the output layout (drag a rectangle to set
-- output.position; edges snap to neighbouring monitors).
--
-- all state comes straight from the `output` capi object — no spawned tools.
-- HDR is not exposed by somewm's output object, so there is no control for it.
-- one shared popup is re-anchored to whichever widget was middle-clicked,
-- same pattern as the rest of the wibar popup family.

local awful   = require("awful")
local gears   = require("gears")
local wibox   = require("wibox")
local beautiful = require("beautiful")
local gshape  = require("gears.shape")
local guarded = require("error_guard")
local popup_common = require("plugins.popup_common")
local base    = require("wibox.widget.base")

local dpi = beautiful.xresources.apply_dpi

local mouse = mouse
local capi_screen = screen
local capi_output = output
local capi_mousegrabber = mousegrabber

local COLOR_PURPLE = popup_common.theme.PURPLE
local COLOR_BLACK  = popup_common.theme.BLACK
local COLOR_WHITE  = popup_common.theme.WHITE
local COLOR_GOLD   = popup_common.theme.GOLD
local COLOR_GREY   = popup_common.theme.GREY
local COLOR_GREEN  = popup_common.theme.GREEN
local COLOR_RED    = popup_common.theme.RED
local COLOR_HOVER  = popup_common.theme.HOVER
local FONT       = popup_common.fonts.FONT
local FONT_HEAD  = popup_common.fonts.FONT_HEAD
local FONT_SMALL = popup_common.fonts.FONT_SMALL
local CONTENT_W  = dpi(320)
local MAP_H      = dpi(110)

local M = {}

local popup
local popup_holder = {}
local rows_container_ref
local pending_bar_ref
local map_widget
local hide
local ctrl
local schedule_refresh  -- forward declaration; assigned under MARK: POPUP
local update_pending_bar  -- forward declaration; assigned under MARK: POPUP

-- staged output layout from map drags: output -> {x,y} in layout coords,
-- staged resolution/refresh picks from the mode cycler: output -> mode,
-- and staged scale picks from the scale cycler: output -> number.
-- nothing is committed until the apply chip is clicked; cancel drops it all
local pending = {}
local pending_mode = {}
local pending_scale = {}

-- wl_output_transform names; the C getter returns the enum integer
local TRANSFORMS = {
    "normal", "90", "180", "270",
    "flipped", "flipped-90", "flipped-180", "flipped-270",
}
local SCALE_STEPS = { 0.5, 0.75, 1, 1.25, 1.5, 1.75, 2, 2.5, 3 }

local make_text = popup_common.make_text

local function separator()
    return popup_common.separator(CONTENT_W)
end


-- MARK: OUTPUT MODEL

-- internal panels carry embedded connector prefixes (eDP/LVDS/DSI); HDMI and
-- DP outputs — including the ones exposed through a thunderbolt hub — are
-- external. listing internals first keeps the laptop panel on top
local INTERNAL_PREFIXES = { "eDP", "LVDS", "DSI" }
local function is_internal(o)
    local n = tostring(o.name)
    for _, p in ipairs(INTERNAL_PREFIXES) do
        if n:sub(1, #p) == p then return true end
    end
    return false
end

-- listing order: internal panels first, then HDMI, then DP, then anything
-- else — alphabetical inside each rank
local function conn_rank(o)
    local n = tostring(o.name)
    if is_internal(o) then return 0
    elseif n:match("^HDMI") then return 1
    elseif n:match("^DP") then return 2
    end
    return 3
end

local function all_outputs()
    local list = {}
    for i = 1, capi_output.count() do
        local o = capi_output[i]
        if o and o.valid then list[#list + 1] = o end
    end
    table.sort(list, function(a, b)
        local ra, rb = conn_rank(a), conn_rank(b)
        if ra ~= rb then return ra < rb end
        return tostring(a.name) < tostring(b.name)
    end)
    return list
end

-- effective (layout-space) rect of an enabled output: mode size with the
-- transform quarter-turn applied, divided by the scale. disabled outputs
-- have no current_mode and return nil
local function layout_rect(o)
    local m = pending_mode[o] or o.current_mode
    if not m or not o.enabled then return nil end
    local w, h = m.width, m.height
    if (o.transform or 0) % 2 == 1 then w, h = h, w end
    local s = pending_scale[o] or o.scale or 1
    local p = pending[o] or o.position or { x = 0, y = 0 }
    return { x = p.x, y = p.y, w = w / s, h = h / s }
end

local function mode_label(m)
    if not m then return "no mode" end
    return string.format("%dx%d@%d", m.width, m.height,
        math.floor((m.refresh or 0) / 1000 + 0.5))
end

local function scale_label(s)
    local str = string.format("%.2f", s or 1)
    return (str:gsub("0+$", ""):gsub("%.$", "")) .. "x"
end

-- two rects touch along an edge when one's border coincides with the other's
-- and their spans on the shared axis overlap by a positive length (corner
-- contact alone does not count)
local function share_edge(a, b)
    local y_ov = math.min(a.y + a.h, b.y + b.h) - math.max(a.y, b.y)
    if y_ov > 0 and (a.x + a.w == b.x or b.x + b.w == a.x) then return true end
    local x_ov = math.min(a.x + a.w, b.x + b.w) - math.max(a.x, b.x)
    return x_ov > 0 and (a.y + a.h == b.y or b.y + b.h == a.y)
end

-- the staged desktop is contiguous when no enabled outputs overlap and every
-- output is reachable from any other through shared edges (flood fill).
-- layout_rect already resolves pending drags, so this checks the would-be
-- result of clicking apply
local function layout_contiguous()
    local rects = {}
    for _, o in ipairs(all_outputs()) do
        local r = layout_rect(o)
        if r then rects[#rects + 1] = r end
    end
    local n = #rects
    if n <= 1 then return true end
    for i = 1, n do
        for j = i + 1, n do
            local a, b = rects[i], rects[j]
            if a.x < b.x + b.w and b.x < a.x + a.w
                and a.y < b.y + b.h and b.y < a.y + a.h then
                return false
            end
        end
    end
    local seen = { [1] = true }
    local stack = { 1 }
    while #stack > 0 do
        local i = table.remove(stack)
        for j = 1, n do
            if not seen[j] and share_edge(rects[i], rects[j]) then
                seen[j] = true
                stack[#stack + 1] = j
            end
        end
    end
    for j = 1, n do
        if not seen[j] then return false end
    end
    return true
end


-- MARK: CONTROL WIDGETS

-- small bordered text button; fg flips to gold on hover. a nil onclick
-- renders it inert (no hover, no binding) for disabled actions; the optional
-- border color overrides the default purple and is restored after hover
local function chip(text, fg, onclick, border)
    local txt = wibox.widget {
        text  = text,
        font  = FONT_SMALL,
        align = "center",
        valign = "center",
        widget = wibox.widget.textbox,
    }
    -- textbox has no fg of its own in somewm; the background container's fg
    -- sets the cairo source the text is painted with
    local bg = wibox.widget {
        {
            txt,
            left = dpi(6), right = dpi(6),
            top = dpi(2), bottom = dpi(2),
            widget = wibox.container.margin,
        },
        bg = COLOR_BLACK,
        fg = fg or COLOR_WHITE,
        border_width = dpi(1),
        border_color = border or COLOR_PURPLE,
        shape = function(cr, w, h)
            gshape.rounded_rect(cr, w, h, dpi(3))
        end,
        widget = wibox.container.background,
    }
    if onclick then
        bg:connect_signal("mouse::enter", function() bg.border_color = COLOR_GOLD end)
        bg:connect_signal("mouse::leave", function()
            bg.border_color = border or COLOR_PURPLE
        end)
        bg:buttons(gears.table.join(awful.button({}, 1, guarded(function()
            onclick(txt)
        end))))
    end
    return bg, txt
end

-- ◀ label ▶ cycler: calls on_step(-1|1); the label is rebuilt by the caller's
-- refresh so cyclers never track their own state. border_color wraps the
-- label in a bordered box — used to flag a staged (uncommitted) value
local function cycler(get_label, on_step, border_color)
    local lbl = make_text(get_label(), COLOR_GOLD, FONT)
    lbl.align = "center"
    local lbl_widget = lbl
    if border_color then
        lbl_widget = wibox.widget {
            {
                lbl,
                left = dpi(4), right = dpi(4),
                widget = wibox.container.margin,
            },
            border_width = dpi(1),
            border_color = border_color,
            shape = function(cr, w, h)
                gshape.rounded_rect(cr, w, h, dpi(3))
            end,
            widget = wibox.container.background,
        }
    end
    local function wrap(step)
        return function()
            on_step(step)
            -- the property:: signal round-trip may not have rebuilt the row
            -- yet; set the label optimistically so the click feels instant
            lbl.text = get_label()
        end
    end
    local l, _ = chip("◀", COLOR_WHITE, wrap(-1))
    local r, _ = chip("▶", COLOR_WHITE, wrap(1))
    return wibox.widget {
        l,
        {
            lbl_widget,
            halign = "center",
            fill_horizontal = true,
            widget = wibox.container.place,
        },
        r,
        layout = wibox.layout.align.horizontal,
        expand = "inside",
    }
end


-- MARK: OUTPUT SECTION

local function output_section(o)
    local enabled = o.enabled
    local is_primary = enabled and o.screen and o.screen == capi_screen.primary

    -- line 1: primary star + connector name + make/model on the left; the
    -- power chip on the right is a single glyph so it keeps the same
    -- footprint as the cycler arrow chips and can't be squished away by
    -- long make/model strings
    local name_lbl = make_text(o.name, COLOR_WHITE, FONT_HEAD)
    local desc = {}
    local make  = o.make  ~= nil and o.make  ~= "Unknown" and o.make  or nil
    local model = o.model ~= nil and o.model ~= "Unknown" and o.model or nil
    -- a model that is a bare EDID hex id or already appears inside the make
    -- string adds noise, not info — drop it
    if model and (model:match("^0x%x+$")
        or (make and make:lower():find(model:lower(), 1, true))) then
        model = nil
    end
    if make then desc[#desc + 1] = make end
    if model then desc[#desc + 1] = model end
    if is_internal(o) then desc[#desc + 1] = "(internal)" end
    if o.virtual then desc[#desc + 1] = "(virtual)" end
    -- keep the make/model line on one row: textboxes wrap (word_char) when
    -- the width cap kicks in, so trim the string rather than rely on
    -- ellipsize, which loses to wrapping in Pango
    local desc_str = table.concat(desc, " ")
    if #desc_str > 34 then desc_str = desc_str:sub(1, 32) .. "…" end
    local desc_lbl = make_text(desc_str ~= "" and "  " .. desc_str or "",
        COLOR_GREY, FONT_SMALL)

    local power_chip
    power_chip = chip(enabled and "●" or "○",
        enabled and COLOR_GOLD or COLOR_GREY, function()
            -- dropping the output that hosts this popup orphans it; close
            -- first so the teardown happens while its screen still exists
            if enabled and o.screen and popup and popup.screen == o.screen then
                hide()
            end
            o.enabled = not enabled
            schedule_refresh()
        end)

    local primary_txt = wibox.widget {
        text  = "★",
        font  = FONT_HEAD,
        align = "center",
        valign = "center",
        widget = wibox.widget.textbox,
    }
    local primary_bg = wibox.widget {
        {
            primary_txt,
            left = dpi(4), right = dpi(4),
            widget = wibox.container.margin,
        },
        bg = COLOR_BLACK,
        fg = is_primary and COLOR_GOLD or COLOR_GREY,
        widget = wibox.container.background,
    }
    if enabled and o.screen then
        primary_bg:buttons(gears.table.join(awful.button({}, 1, guarded(function()
            if o.screen then capi_screen.primary = o.screen end
            schedule_refresh()
        end))))
    end

    local line1 = wibox.widget {
        {
            -- cap the left group's width so a long make/model ellipsizes
            -- instead of pushing the power chip off the row
            {
                {
                    primary_bg,
                    halign = "center",
                    valign = "center",
                    widget = wibox.container.place,
                },
                name_lbl,
                desc_lbl,
                layout = wibox.layout.fixed.horizontal,
            },
            strategy = "max",
            width = CONTENT_W - dpi(40),
            widget = wibox.container.constraint,
        },
        nil,
        power_chip,
        layout = wibox.layout.align.horizontal,
        expand = "inside",
    }

    local col = wibox.widget {
        line1,
        layout = wibox.layout.fixed.vertical,
        spacing = dpi(3),
    }

    if enabled then
        -- mode cycler: step through the driver-reported mode list
        local modes = o.modes or {}
        local cur = o.current_mode
        local cur_idx = 0
        for i, m in ipairs(modes) do
            if cur and m.width == cur.width and m.height == cur.height
                and m.refresh == cur.refresh then
                cur_idx = i
                break
            end
        end
        if #modes > 0 then
            -- mode cycling is staged: the label shows the pending pick (with a
            -- '*' marker) and nothing commits until apply layout is clicked.
            -- cycling back onto the live mode unstages it
            col:add(cycler(
                function()
                    local m = pending_mode[o] or o.current_mode
                    local s = mode_label(m)
                    if m and m.preferred then s = s .. " ★" end
                    if pending_mode[o] then s = s .. " *" end
                    return s
                end,
                function(step)
                    local m = pending_mode[o] or o.current_mode
                    local idx = 0
                    for i, mm in ipairs(modes) do
                        if m and mm.width == m.width and mm.height == m.height
                            and mm.refresh == m.refresh then
                            idx = i
                            break
                        end
                    end
                    local next_m = modes[((idx - 1 + step) % #modes) + 1]
                    local cur = o.current_mode
                    if next_m and cur and next_m.width == cur.width
                        and next_m.height == cur.height
                        and next_m.refresh == cur.refresh then
                        pending_mode[o] = nil
                    else
                        pending_mode[o] = next_m
                    end
                    update_pending_bar()
                    -- rebuild the row so the staged label gains/loses its
                    -- green border
                    schedule_refresh()
                end, pending_mode[o] and COLOR_GREEN))
        end

        -- scale + transform cyclers on one row, adaptive-sync chip at the end
        -- scale cycling is staged like mode: the label shows the pending
        -- pick with a '*' marker and nothing commits until apply; cycling
        -- back onto the live scale unstages it
        local scale_cyc = cycler(
            function()
                local s = scale_label(pending_scale[o] or o.scale)
                if pending_scale[o] then s = s .. " *" end
                return s
            end,
            function(step)
                local cur_s = pending_scale[o] or o.scale or 1
                local best, best_d = 1, math.huge
                for i, v in ipairs(SCALE_STEPS) do
                    local dd = math.abs(v - cur_s)
                    if dd < best_d then best, best_d = i, dd end
                end
                local ni = math.max(1, math.min(#SCALE_STEPS, best + step))
                local next_s = SCALE_STEPS[ni]
                if next_s == (o.scale or 1) then
                    pending_scale[o] = nil
                else
                    pending_scale[o] = next_s
                end
                update_pending_bar()
                schedule_refresh()
            end, pending_scale[o] and COLOR_GREEN)
        local tr_cyc = cycler(
            function() return TRANSFORMS[(o.transform or 0) + 1] or "?" end,
            function(step)
                o.transform = TRANSFORMS[((o.transform or 0) + step) % #TRANSFORMS + 1]
            end)
        local vrr_chip
        vrr_chip = chip(o.adaptive_sync and "vrr" or "vrr",
            o.adaptive_sync and COLOR_GOLD or COLOR_GREY, function()
                o.adaptive_sync = not o.adaptive_sync
                schedule_refresh()
            end)
        col:add(wibox.widget {
            scale_cyc,
            tr_cyc,
            {
                vrr_chip,
                halign = "right",
                valign = "center",
                widget = wibox.container.place,
            },
            layout = wibox.layout.align.horizontal,
            expand = "inside",
        })
    else
        col:add(make_text("disabled", COLOR_GREY, FONT_SMALL))
    end

    return wibox.widget {
        {
            col,
            left = dpi(6), right = dpi(6),
            top = dpi(4), bottom = dpi(4),
            widget = wibox.container.margin,
        },
        forced_width = CONTENT_W,
        bg = COLOR_BLACK,
        widget = wibox.container.background,
    }
end


-- MARK: LAYOUT MAP

-- canvas of monitor rectangles at effective size, scaled to fit CONTENT_W.
-- dragging a rect shows a snapped ghost; release commits output.position
local function make_map()
    local w = base.make_widget(nil, nil, { enable_properties = true })
    w._rects = {}    -- { o, x, y, w, h } in map coords (o = output)
    w._k, w._ox, w._oy = 1, 0, 0
    w._drag = nil    -- { o, offx, offy, gx, gy, ax, ay } while a drag runs

    function w:fit(_, avail_w)
        return math.min(avail_w, CONTENT_W - dpi(20)), MAP_H
    end

    -- (re)compute the layout->map transform and each rect's map coords
    function w:relayout(avail_w)
        local bbox
        local rects = {}
        for _, o in ipairs(all_outputs()) do
            local r = layout_rect(o)
            if r then
                local e = { o = o, lx = r.x, ly = r.y, lw = r.w, lh = r.h }
                rects[#rects + 1] = e
                if not bbox then
                    bbox = { x = r.x, y = r.y, r = r.x + r.w, b = r.y + r.h }
                else
                    bbox.x = math.min(bbox.x, r.x)
                    bbox.y = math.min(bbox.y, r.y)
                    bbox.r = math.max(bbox.r, r.x + r.w)
                    bbox.b = math.max(bbox.b, r.y + r.h)
                end
            end
        end
        self._rects = rects
        self._bbox = bbox
        if not bbox then return end
        local bw = math.max(1, bbox.r - bbox.x)
        local bh = math.max(1, bbox.b - bbox.y)
        local pad = dpi(4)
        local mw = (avail_w or CONTENT_W - dpi(20)) - 2 * pad
        local mh = MAP_H - 2 * pad
        local k = math.min(mw / bw, mh / bh)
        self._k = k
        self._ox = pad + (mw - bw * k) / 2
        self._oy = pad + (mh - bh * k) / 2
        for _, e in ipairs(rects) do
            e.x = self._ox + (e.lx - bbox.x) * k
            e.y = self._oy + (e.ly - bbox.y) * k
            e.w = e.lw * k
            e.h = e.lh * k
        end
    end

    local function rect_xy(e)
        if w._drag and w._drag.o == e.o then
            return w._drag.gx, w._drag.gy
        end
        return e.x, e.y
    end

    local GAP = dpi(2)  -- visual inset between adjacent monitor rectangles

    function w:draw(_, cr, width, height)
        if not self._bbox then self:relayout(width) end
        cr:set_source_rgb(0.04, 0.04, 0.04)
        cr:rectangle(0, 0, width, height)
        cr:fill()
        cr:select_font_face("monospace")
        cr:set_font_size(dpi(9))
        for _, e in ipairs(self._rects) do
            local x, y = rect_xy(e)
            local primary = e.o.screen and e.o.screen == capi_screen.primary
            local ghost = self._drag and self._drag.o == e.o
            local staged = pending[e.o] ~= nil or pending_mode[e.o] ~= nil
                or pending_scale[e.o] ~= nil
            -- inset so edge-snapped monitors still read as separate panels
            local rx, ry = x + GAP, y + GAP
            local rw, rh = math.max(1, e.w - 2 * GAP), math.max(1, e.h - 2 * GAP)
            cr:set_source_rgba(0.38, 0.22, 0.59, ghost and 0.25 or 0.45)
            cr:rectangle(rx, ry, rw, rh)
            cr:fill()
            if staged then
                -- any staged change: dashed green border until applied
                cr:set_source_rgba(0.41, 0.84, 0.40, 0.9)
                cr:set_dash({ dpi(4), dpi(3) }, 0)
            else
                cr:set_source_rgba(1, 0.84, 0, primary and 1 or 0.35)
            end
            cr:set_line_width(primary and dpi(1.5) or dpi(1))
            cr:rectangle(rx + 0.5, ry + 0.5, rw - 1, rh - 1)
            cr:stroke()
            cr:set_dash({}, 0)
            local label = tostring(e.o.name)
            local te = cr:text_extents(label)
            -- rotate the name by the output's transform so the map reads
            -- like the physical panel: 90/270 run vertically, 180 upside
            -- down, flipped variants mirrored. sideways text fits when its
            -- width clears the rect's height instead
            local t = e.o.transform or 0
            local sideways = t % 2 == 1
            local fits = sideways
                and (te.width < rh - 4 and te.height < rw - 4)
                or (te.width < rw - 4)
            if fits then
                cr:save()
                cr:translate(rx + rw / 2, ry + rh / 2)
                cr:rotate(-(t % 4) * math.pi / 2)
                if t >= 4 then cr:scale(-1, 1) end
                cr:set_source_rgba(1, 1, 1, ghost and 0.6 or 0.9)
                cr:move_to(-te.width / 2 - te.x_bearing,
                           -te.height / 2 - te.y_bearing)
                cr:show_text(label)
                cr:restore()
            end
        end
    end

    -- snap a layout-space rect to the edges of the other rects; returns the
    -- corrected x,y. SNAP is in layout px (a few map px at typical scale)
    local SNAP = 120
    local function snapped(self, lx, ly, lw, lh, skip_o)
        local function best(cur, cands)
            local pick, dist = cur, SNAP
            for _, c in ipairs(cands) do
                local d = math.abs(c - cur)
                if d < dist then pick, dist = c, d end
            end
            return pick
        end
        local xs, ys = { 0 }, { 0 }
        for _, e in ipairs(self._rects) do
            if e.o ~= skip_o then
                xs[#xs + 1] = e.lx            -- align left edge
                xs[#xs + 1] = e.lx + e.lw     -- abut right edge
                xs[#xs + 1] = e.lx - lw       -- abut left edge
                xs[#xs + 1] = e.lx + e.lw - lw -- align right edge
                ys[#ys + 1] = e.ly
                ys[#ys + 1] = e.ly + e.lh
                ys[#ys + 1] = e.ly - lh
                ys[#ys + 1] = e.ly + e.lh - lh
            end
        end
        return best(lx, xs), best(ly, ys)
    end

    w:connect_signal("button::press", function(_, lx, ly, button)
        if #w._rects == 0 then return end
        local hit
        for _, e in ipairs(w._rects) do
            if lx >= e.x and lx <= e.x + e.w and ly >= e.y and ly <= e.y + e.h then
                hit = e
                break
            end
        end
        if not hit then return end
        -- right-click rotates the monitor through the four unflipped
        -- transforms; flipped variants stay on the row cycler
        if button == 3 then
            local t = hit.o.transform or 0
            hit.o.transform = TRANSFORMS[(t % 4 + 1) % 4 + 1]
            return
        end
        if button ~= 1 then return end
        if capi_mousegrabber.isrunning and capi_mousegrabber.isrunning() then
            return
        end
        local mc = mouse.coords()
        local map_ax = mc.x - lx   -- map widget's absolute origin
        local map_ay = mc.y - ly
        w._drag = {
            o = hit.o,
            offx = lx - hit.x, offy = ly - hit.y,
            gx = hit.x, gy = hit.y,
        }
        local safety = gears.timer {
            timeout = 15, single_shot = true,
            callback = guarded(function()
                if capi_mousegrabber.isrunning and capi_mousegrabber.isrunning() then
                    capi_mousegrabber.stop()
                end
                w._drag = nil
                w:emit_signal("widget::redraw_needed")
            end),
        }
        capi_mousegrabber.run(function(m)
            if not w._drag then return false end
            if not (m.buttons and m.buttons[1]) then
                -- release: convert ghost to layout space, snap, and stage it.
                -- nothing is committed until the apply chip is clicked
                local d = w._drag
                local lx2 = (d.gx - w._ox) / w._k + w._bbox.x
                local ly2 = (d.gy - w._oy) / w._k + w._bbox.y
                lx2, ly2 = snapped(w, lx2, ly2, hit.lw, hit.lh, d.o)
                local px, py = math.floor(lx2 + 0.5), math.floor(ly2 + 0.5)
                local cur = d.o.position or { x = 0, y = 0 }
                if px == cur.x and py == cur.y then
                    pending[d.o] = nil  -- dropped back in place: unstage
                else
                    pending[d.o] = { x = px, y = py }
                end
                w._drag = nil
                safety:stop()
                w._bbox = nil  -- staged extents can differ; refit on next draw
                update_pending_bar()
                w:emit_signal("widget::redraw_needed")
                return false
            end
            local gx = m.x - map_ax - w._drag.offx
            local gy = m.y - map_ay - w._drag.offy
            -- live-snap the ghost so the preview shows where it will land
            local lx2 = (gx - w._ox) / w._k + w._bbox.x
            local ly2 = (gy - w._oy) / w._k + w._bbox.y
            lx2, ly2 = snapped(w, lx2, ly2, hit.lw, hit.lh, hit.o)
            w._drag.gx = w._ox + (lx2 - w._bbox.x) * w._k
            w._drag.gy = w._oy + (ly2 - w._bbox.y) * w._k
            w:emit_signal("widget::redraw_needed")
            return true
        end, "fleur")
    end)

    return w
end


-- MARK: KANSHI PERSIST

-- persist the live layout into ~/.config/kanshi/config so a restart keeps it:
-- rewrite the first profile whose output criteria exactly match the
-- connected set, else prepend a new profile — kanshi activates the first
-- profile whose outputs are all connected, so a fresh block must lead the
-- file or a looser subset profile would shadow it
local KANSHI_CFG = os.getenv("HOME") .. "/.config/kanshi/config"

local function kanshi_output_line(o, dx, dy)
    if not o.enabled then
        return string.format("    output %s disable", o.name)
    end
    local parts = { "    output " .. o.name }
    local m = o.current_mode
    if m then
        parts[#parts + 1] = string.format("mode %dx%d@%g",
            m.width, m.height, (m.refresh or 0) / 1000)
    end
    local p = o.position
    if p then
        parts[#parts + 1] = string.format("position %d,%d",
            p.x + dx, p.y + dy)
    end
    if (o.scale or 1) ~= 1 then
        parts[#parts + 1] = string.format("scale %g", o.scale)
    end
    local t = TRANSFORMS[(o.transform or 0) + 1]
    if t ~= "normal" then parts[#parts + 1] = "transform " .. t end
    parts[#parts + 1] = "adaptive_sync " .. (o.adaptive_sync and "on" or "off")
    return table.concat(parts, " ")
end

local function save_to_kanshi()
    local f = io.open(KANSHI_CFG, "r")
    if not f then return false, "cannot read " .. KANSHI_CFG end
    local content = f:read("*a")
    f:close()

    -- translate the layout to a non-negative origin, same normalization as
    -- commit(): relative arrangement unchanged, but somewm's wallpaper path
    -- cannot represent negative coordinates
    local minx, miny = 0, 0
    for _, o in ipairs(all_outputs()) do
        if o.valid and o.enabled and o.position then
            minx = math.min(minx, o.position.x)
            miny = math.min(miny, o.position.y)
        end
    end
    local present, body = {}, {}
    for _, o in ipairs(all_outputs()) do
        if o.valid then
            present[o.name] = true
            body[#body + 1] = kanshi_output_line(o, -minx, -miny)
        end
    end

    -- a profile matches when its output criteria set equals the connected
    -- set exactly; profiles with wildcard criteria are never rewritten.
    -- %f[^%w] word boundaries keep "profile" inside comments like
    -- "profiles are applied" from matching, and criteria are read
    -- line-anchored so comment text can't leak into the output set
    local pos, replaced = 1, false
    while true do
        local bs, be = content:find("%f[%w]profile%f[^%w][^%{]*%b{}", pos)
        if not bs then break end
        local block = content:sub(bs, be)
        local set, exact = {}, true
        for line in block:gmatch("[^\n]+") do
            local c = line:match('^%s*output%s+"([^"]+)"')
                or line:match("^%s*output%s+([%w%._%-*]+)")
            if c then
                if c:find("*", 1, true) then exact = false end
                set[c] = true
            end
        end
        for c in pairs(set) do
            if not present[c] then exact = false end
        end
        for c in pairs(present) do
            if not set[c] then exact = false end
        end
        if exact then
            local name = block:match("profile%s+([^%s%{]+)")
            local header = name and "profile " .. name .. " {" or "profile {"
            content = content:sub(1, bs - 1)
                .. header .. "\n" .. table.concat(body, "\n") .. "\n}"
                .. content:sub(be + 1)
            replaced = true
            break
        end
        pos = be + 1
    end
    if not replaced then
        content = "profile displays_popup {\n" .. table.concat(body, "\n")
            .. "\n}\n\n" .. content
    end

    -- timestamped backup before overwriting, rotated like other .bak files
    local dir = KANSHI_CFG:match("^(.*)/[^/]+$")
    os.execute(string.format(
        'cd %q && cp config "config.%s.bak" && mkdir -p old/week old/month old/year'
        .. ' && { ls -1t config.*.bak | tail -n +6 | xargs -r mv -t old/'
        .. ' ; find old -maxdepth 1 -name "config.*.bak" -mtime +1 -exec mv -t old/week {} +'
        .. ' ; find old/week -name "config.*.bak" -mtime +7 -exec mv -t old/month {} +'
        .. ' ; find old/month -name "config.*.bak" -mtime +30 -exec mv -t old/year {} +'
        .. ' ; } 2>/dev/null; true', dir, os.date("%Y%m%d_%H%M")))

    local wf, werr = io.open(KANSHI_CFG, "w")
    if not wf then return false, tostring(werr) end
    wf:write(content)
    wf:close()

    -- kanshi reloads its config on SIGHUP, so the saved layout also wins on
    -- the next hotplug without a daemon restart
    os.execute("pkill -HUP kanshi 2>/dev/null")
    return true
end


-- MARK: POPUP

local refresh_popup
local refresh_timer = gears.timer {
    timeout = 0.12, single_shot = true, autostart = false,
    callback = guarded(function()
        if popup and popup.visible and refresh_popup then refresh_popup() end
    end),
}
schedule_refresh = function()
    refresh_timer:stop()
    refresh_timer:start()
end

-- per-output property signals re-render the popup while it is open; the set
-- keeps one connection per output object across rebuilds
local wired_outputs = setmetatable({}, { __mode = "k" })
local function wire_output(o)
    if wired_outputs[o] then return end
    wired_outputs[o] = true
    for _, sig in ipairs {
        "property::enabled", "property::mode", "property::scale",
        "property::transform", "property::position", "property::adaptive_sync",
    } do
        o:connect_signal(sig, function() schedule_refresh() end)
    end
end

local function build_content()
    local header
    header, ctrl = popup_common.draggable_header {
        holder = popup_holder,
        name  = "displays_popup",
        title = "Displays",
        width = CONTENT_W,
        hide  = function() hide() end,
    }

    map_widget = make_map()

    -- apply/cancel bar for staged map drags; empty until a drag stages a move
    local pending_bar = wibox.container.margin()
    pending_bar_ref = pending_bar

    local rows_container = wibox.widget {
        layout = wibox.layout.fixed.vertical,
        spacing = dpi(6),
    }

    return wibox.widget {
        header,
        {
            map_widget,
            top = dpi(6), bottom = dpi(2),
            left = dpi(10), right = dpi(10),
            widget = wibox.container.margin,
        },
        {
            pending_bar,
            bottom = dpi(4),
            left = dpi(10), right = dpi(10),
            widget = wibox.container.margin,
        },
        separator(),
        {
            rows_container,
            top = dpi(6), bottom = dpi(8),
            left = dpi(10), right = dpi(10),
            widget = wibox.container.margin,
        },
        separator(),
        {
            -- save captures the *live* layout: staged changes still need an
            -- apply first
            {
                chip("save to kanshi", COLOR_GREY, function(txt)
                    local ok, err = save_to_kanshi()
                    if not ok then
                        gears.debug.print_error("displays_popup: kanshi: "
                            .. tostring(err))
                    end
                    txt.text = ok and "saved" or "failed"
                    gears.timer {
                        timeout = 1.5, single_shot = true, autostart = true,
                        callback = guarded(function()
                            txt.text = "save to kanshi"
                        end),
                    }
                end),
                halign = "center",
                valign = "center",
                widget = wibox.container.place,
            },
            top = dpi(4), bottom = dpi(6),
            left = dpi(10), right = dpi(10),
            widget = wibox.container.margin,
        },
        layout = wibox.layout.fixed.vertical,
    }, rows_container
end

-- shows the apply/cancel chips while staged drags are pending, clears it
-- otherwise. apply commits every staged position; cancel drops them
update_pending_bar = function()
    if not pending_bar_ref then return end
    if next(pending) == nil and next(pending_mode) == nil
        and next(pending_scale) == nil then
        pending_bar_ref.widget = nil
        return
    end
    local function commit()
        -- somewm's wallpaper surface is drawn in layout coordinates starting
        -- at (0,0); negative positions leave a slice of the monitor
        -- unwallpapered. translate the whole layout so its origin is
        -- non-negative — the relative arrangement is unchanged
        local min_x, min_y = math.huge, math.huge
        for _, o in ipairs(all_outputs()) do
            if o.enabled then
                local r = layout_rect(o)
                min_x = math.min(min_x, r.x)
                min_y = math.min(min_y, r.y)
            end
        end
        local dx = min_x < 0 and -min_x or 0
        local dy = min_y < 0 and -min_y or 0
        for _, o in ipairs(all_outputs()) do
            if o.enabled and o.valid then
                local r = layout_rect(o)
                local tx, ty = r.x + dx, r.y + dy
                local cur = o.position or { x = 0, y = 0 }
                if tx ~= cur.x or ty ~= cur.y then
                    local ok, err = pcall(function()
                        o.position = { x = tx, y = ty }
                    end)
                    if not ok then
                        gears.debug.print_error("displays_popup: position: " .. tostring(err))
                    end
                end
            end
        end
        for o, m in pairs(pending_mode) do
            if o.valid then
                local ok, err = pcall(function()
                    o.mode = { width = m.width, height = m.height,
                               refresh = m.refresh }
                end)
                if not ok then
                    gears.debug.print_error("displays_popup: mode: " .. tostring(err))
                end
            end
        end
        for o, v in pairs(pending_scale) do
            if o.valid then
                local ok, err = pcall(function()
                    o.scale = v
                end)
                if not ok then
                    gears.debug.print_error("displays_popup: scale: " .. tostring(err))
                end
            end
        end
        pending = {}
        pending_mode = {}
        pending_scale = {}
        update_pending_bar()
        if map_widget then
            map_widget._bbox = nil
            map_widget:emit_signal("widget::redraw_needed")
        end
    end
    -- a staged layout that isn't contiguous can't be applied: the apply chip
    -- renders inert and explains itself until the rects touch edge-to-edge
    local contiguous = layout_contiguous()
    local apply = chip(
        contiguous and "apply layout" or "not contiguous",
        contiguous and COLOR_GOLD or COLOR_GREY,
        contiguous and commit or nil, COLOR_GREEN)
    local cancel = chip("cancel", COLOR_GREY, function()
        pending = {}
        pending_mode = {}
        pending_scale = {}
        -- a full refresh so the mode cyclers drop their staged '*' labels
        refresh_popup()
    end, COLOR_RED)
    pending_bar_ref.widget = wibox.widget {
        {
            apply,
            cancel,
            spacing = dpi(6),
            layout = wibox.layout.fixed.horizontal,
        },
        halign = "center",
        valign = "center",
        widget = wibox.container.place,
    }
end

refresh_popup = function()
    if not rows_container_ref then return end
    rows_container_ref:reset()
    local outs = all_outputs()
    if #outs == 0 then
        rows_container_ref:add(make_text("No outputs", COLOR_GREY))
        return
    end
    for _, o in ipairs(outs) do
        wire_output(o)
        rows_container_ref:add(output_section(o))
    end
    update_pending_bar()
    if map_widget then
        map_widget._bbox = nil
        map_widget:emit_signal("widget::redraw_needed")
    end
end

local function ensure_popup()
    if popup then return end
    local style = popup_common.popup_style()
    local content, rc = build_content()
    rows_container_ref = rc
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
    popup_common.hide(popup)
end

local function show(anchor)
    ensure_popup()
    if popup.visible or popup._showing then return end
    ctrl.set_anchor(anchor)
    -- emit before setting _showing, for the same closer race reason as the
    -- rest of the popup family (see brightness_popup.show)
    awesome.emit_signal("popup::opening")
    popup._showing = true
    refresh_popup()
    popup_common.show_placement(popup, anchor, ctrl.show_opts())
    popup._showing = false
end

local function toggle(anchor)
    ensure_popup()
    ctrl.toggle(anchor, show)
end


-- MARK: ATTACH

-- middle-click toggle on the brightness widget; a connect_signal (not
-- widget:buttons) so the existing left-click brightness popup, scroll and
-- right-click bindings are untouched
function M.attach(widget)
    ensure_popup()
    popup_common.sticky_border(popup, widget)
    widget:connect_signal("button::press", guarded(function(_, _, _, pressed)
        if pressed ~= 2 then return end
        popup._anchor_geo    = mouse.current_widget_geometry
        popup._anchor_screen = mouse.current_wibox and mouse.current_wibox.screen
        popup._anchor_wibox  = mouse.current_wibox
        if not popup_common.widget_press(popup) then toggle(widget) end
    end))
end

function M.is_visible()
    return popup and popup.visible or false
end

M.refresh = refresh_popup

-- close this popup when any other popup opens; re-render on hotplug
popup_common.register_closer(hide)
capi_output.connect_signal("added",   function() schedule_refresh() end)
capi_output.connect_signal("removed", function() schedule_refresh() end)


return M
