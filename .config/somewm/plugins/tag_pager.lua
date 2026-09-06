-- plugins/tag_pager.lua
-- Tag-aware pager for AwesomeWM, styled after the KDE Plasma pager.
--
-- Inline wibar widget:
--   A row of tag cells, one per tag on the screen. Each cell is a scaled
--   miniature of that tag's screen: window rectangles positioned by real
--   client geometry, each carrying a tiny client icon. The selected tag's
--   cell is gold, viewed-but-not-selected is purple, the rest are normal.
--   Clicking a cell opens the per-tag detail popup.
--
-- Per-tag detail popup:
--   Centered popup showing one tag's clients as larger tiles (icon + full
--   title). Clicking a tile views that tag and raises the client.
--
-- Tag semantics surfaced (vs a flat workspace switcher):
--   * a client may belong to several tags at once (it appears in each cell)
--   * each tag carries its own layout (shown in the detail popup header)
--   * multiple tags can be viewed simultaneously; only one is selected
--   * minimized clients are drawn dimmed in the cell
--
-- IPC / Clay reuse:
--   M.snapshot() returns a plain serializable table of all screens/tags/clients
--   with the semantics above. A future Clay (C) frontend can obtain this over
--   D-Bus/socket and render its own UI without re-deriving the tag model.
--
-- Trigger:
--   Mod+Alt+O           open detail popup for the focused tag (rc/keybindings.lua)
--   wibar pager widget  created via M.create_pager_widget(s), added in rc.lua
--   left-click a cell    switch to that tag (view_only)
--   right-click a cell   toggle that tag's view
--   middle-click a cell  open detail popup for that tag
--   Escape / click outside  close the popup
--
-- CRITICAL IMPLEMENTATION NOTES (same constraints as notification_center.lua):
--   * do NOT use awful.keygrabber / mousegrabber (they block global input)
--   * outside-click detection uses root.buttons(), client "button::press", and
--     wibar "button::press" signals
--   * ALL signal handlers added in show() MUST be disconnected in hide()

local awful = require("awful")
local beautiful = require("beautiful")
local gears = require("gears")
local wibox = require("wibox")
local gstring = require("gears.string")
local gsurface = require("gears.surface")
local cairo = require("lgi").cairo
local menubar = require("menubar")
local guarded = require("error_guard")

local root = root
local client = client
local screen = screen
local capi = { mousegrabber = mousegrabber }

local M = {}


-- MARK: DPI + THEME
-- // MARK --dpi


local function get_xresources()
    if beautiful.xresources then return beautiful.xresources end
    local ok, xr = pcall(require, "beautiful.xresources")
    if ok then return xr end
    return nil
end

local xresources = get_xresources()
local dpi = xresources and xresources.apply_dpi or function(v) return v end

-- colors: prefer theme, fall back to constants matching the rest of the config
local COLOR_GOLD   = beautiful.taglist_fg_focus or "#ffd700"
local COLOR_PURPLE = (beautiful.main_purple and beautiful.main_purple.base) or "#623997"
local COLOR_FG     = beautiful.taglist_fg_normal or "#ffffff"
local COLOR_BG     = beautiful.taglist_bg_normal or "#000000"
local COLOR_OCC    = beautiful.taglist_fg_occupied or "#cccccc"
local COLOR_DIM    = "#333333"


-- MARK: COLOR HELPERS


local function hex_to_rgba(hex, alpha)
    alpha = alpha or 1
    if not hex then return 0.5, 0.5, 0.5, alpha end
    hex = hex:gsub("#", "")
    if #hex == 3 then
        hex = hex:sub(1,1):rep(2) .. hex:sub(2,2):rep(2) .. hex:sub(3,3):rep(2)
    end
    local r = tonumber(hex:sub(1,2), 16) or 128
    local g = tonumber(hex:sub(3,4), 16) or 128
    local b = tonumber(hex:sub(5,6), 16) or 128
    return r/255, g/255, b/255, alpha
end


-- MARK: TAG MODEL
-- // MARK --snapshot


-- true if tag has at least one unminimized, non-hidden client
local function tag_has_unminimized(t)
    if not t or not t.valid then return false end
    for _, c in ipairs(t:clients() or {}) do
        if c.valid and not c.minimized and not c.hidden then
            return true
        end
    end
    return false
end

-- Build a plain serializable snapshot of all screens/tags/clients.
-- IPC-ready abstraction a Clay frontend can reuse later.
function M.snapshot()
    local out = { screens = {} }
    local focused = awful.screen.focused()
    local focused_tag = focused and focused.selected_tag
    for s in screen do
        local st = { index = s.index, tags = {} }
        for _, t in ipairs(s.tags) do
            local clients = {}
            local any_unmin = false
            for _, c in ipairs(t:clients() or {}) do
                local ctags = c:tags() or {}
                table.insert(clients, {
                    id        = tostring(c),
                    name      = c.name or c.class or "?",
                    class     = c.class or "",
                    icon      = c.icon,
                    minimized = c.minimized,
                    hidden    = c.hidden,
                    tag_count = #ctags,
                    multi_tag = #ctags > 1,
                })
                if not c.minimized and not c.hidden then any_unmin = true end
            end
            local n = #clients
            table.insert(st.tags, {
                name            = t.name,
                index           = t.index,
                selected        = (focused_tag == t),
                viewed          = t.selected,
                layout_name      = (t.layout and t.layout.name) or "?",
                empty           = n == 0,
                has_unminimized = any_unmin,
                only_minimized  = (n > 0 and not any_unmin),
                clients         = clients,
            })
        end
        out.screens[s.index] = st
    end
    return out
end


-- MARK: INLINE PAGER CELL
-- // MARK --cell


-- each cell is tracked as { imagebox, tag, width, height, screen }
local cells = {}

-- forward declaration: refresh is defined later but used by start_drag
local refresh
local debounced_refresh


-- // MARK --landscape-rotation
-- Pager cells are always rendered in landscape so they have enough width
-- in the horizontal wibar. When a screen is portrait (rotated 90 or 270),
-- client geometries are in the rotated (logical) coordinate space and must
-- be unrotated to map correctly into the landscape cell.
-- The kanshi config uses transform 90 (CCW) for DP-10; if a profile uses
-- transform 270 instead, swap the unrotate formula accordingly.


-- return true if the screen geometry is portrait (height > width)
local function is_portrait(sg)
    return sg and sg.height > sg.width
end


-- given a screen geometry (logical, possibly portrait), return landscape
-- dimensions (width and height swapped if portrait)
local function landscape_geom(sg)
    if not is_portrait(sg) then return sg end
    return { x = sg.x, y = sg.y, width = sg.height, height = sg.width }
end


-- unrotate a client geometry from logical (portrait) to landscape space
-- transform 90 (CCW): phys_x = log_h - ly - lh, phys_y = lx, phys_w = lh, phys_h = lw
local function unrotate_client(cg, sg)
    if not is_portrait(sg) then return cg end
    return {
        x      = sg.height - cg.y - cg.height,
        y      = cg.x,
        width  = cg.height,
        height = cg.width,
    }
end


-- rotate a point from landscape cell space back to logical (portrait) space
-- inverse of unrotate_client for transform 90 (CCW)
local function rotate_point(px, py, sg)
    if not is_portrait(sg) then return px, py end
    -- lx = py, ly = sg.height - px - 1  (approximate, good enough for hit-test)
    return py, sg.height - px
end


-- MARK: ICON RESOLUTION
-- // MARK --icons


-- resolve a client icon to an LGI cairo surface
-- c.icon can be raw userdata (from awesome.load_image) or a string path;
-- fall back to menubar.utils.lookup_icon for terminal/generic icons
local icon_cache = {}

local function resolve_icon_surface(c)
    if not c then return nil end
    local key = tostring(c.class or c.instance or c)
    if icon_cache[key] ~= nil then return icon_cache[key] end

    -- try c.icon directly (may be string path or raw surface userdata)
    local icon = c.icon
    if icon then
        local ok, surf = pcall(gsurface.load, icon)
        if ok and surf then icon_cache[key] = surf; return surf end
    end

    -- fallback: look up by class name via menubar
    local cls = tostring(c.class or ""):lower()
    local is_term = cls:find("term") ~= nil or cls == "urxvt" or cls == "xterm" or cls == "alacritty" or cls == "wezterm"

    local names = {}
    if is_term then
        names = { "utilities-terminal", "org.gnome.Terminal", "terminal", "xterm" }
    end
    table.insert(names, c.class or "")
    table.insert(names, "application-x-executable")
    table.insert(names, "applications-system")

    local utils = menubar and menubar.utils
    if utils and utils.lookup_icon then
        for _, n in ipairs(names) do
            local p = utils.lookup_icon(n)
            if p and gears.filesystem.file_readable(p) then
                local ok, surf = pcall(gsurface.load, p)
                if ok and surf then icon_cache[key] = surf; return surf end
            end
        end
    end

    icon_cache[key] = false
    return nil
end


-- return the tag's clients sorted by stacking order: focused on top,
-- then non-minimized by index, then minimized at the bottom.
-- Both the renderer and hit-test use this so visual order matches click order.
local function tag_clients_stacked(t)
    local clients = t:clients() or {}
    if #clients <= 1 then return clients end
    local focused = client.focus
    -- only treat the focused client as "on top" if it actually belongs to
    -- this tag; otherwise it would bleed into cells of tags it's not on
    local focused_on_tag = false
    for _, c in ipairs(clients) do
        if c == focused then focused_on_tag = true; break end
    end
    local visible, minimized = {}, {}
    for _, c in ipairs(clients) do
        if c.valid then
            if c == focused and focused_on_tag then
                -- focused client goes last (drawn on top)
            elseif c.minimized then
                table.insert(minimized, c)
            else
                table.insert(visible, c)
            end
        end
    end
    local sorted = {}
    for _, c in ipairs(minimized) do table.insert(sorted, c) end
    for _, c in ipairs(visible)  do table.insert(sorted, c) end
    if focused and focused.valid and focused_on_tag then table.insert(sorted, focused) end
    return sorted
end


-- render a tag cell to a cairo.ImageSurface and return it
local function render_cell_surface(width, height, t)
    local surf = cairo.ImageSurface(cairo.Format.ARGB32, width, height)
    local cr = cairo.Context(surf)

    if not t or not t.valid then return surf end
    local s = t.screen
    -- guard against invalid/stale screen objects during hotplug
    local sg = (s and s.valid and s.geometry) or { x = 0, y = 0, width = 1920, height = 1080 }
    local lg = landscape_geom(sg)
    local sw, sh = lg.width, lg.height
    local scale = math.min(width / sw, height / sh)

    local selected_tag = (s and s.valid) and s.selected_tag or nil
    local is_selected = (selected_tag == t)
    local is_viewed   = t.selected
    local tag_clients = tag_clients_stacked(t)
    local has_clients = #tag_clients > 0
    -- check if the selected tag has any visible (non-minimized) window
    local has_visible = false
    if is_selected then
        for _, c in ipairs(tag_clients) do
            if c.valid and not c.minimized then has_visible = true; break end
        end
    end
    -- selected with visible windows: solid purple bg
    -- selected with no visible windows: black bg, purple border
    -- viewed but not selected: normal bg, gold border
    -- everything else: normal bg, dim border
    local bg = (is_selected and has_visible) and COLOR_PURPLE or COLOR_BG
    -- active (selected) tag name renders yellow so it stands out from viewed/empty tags
    local fg = is_selected and COLOR_GOLD or (has_clients and COLOR_FG or COLOR_FG)

    -- background
    cr:set_source_rgba(hex_to_rgba(bg, 1))
    cr:rectangle(0, 0, width, height)
    cr:fill()

    -- window rectangles (positioned by real client geometry, scaled to cell)
    for _, c in ipairs(tag_clients) do
        if c.valid then
            local cg = unrotate_client(c:geometry(), sg)
            local rx = (cg.x - lg.x) * scale
            local ry = (cg.y - lg.y) * scale
            local rw = math.max(1, cg.width * scale)
            local rh = math.max(1, cg.height * scale)
            -- clamp to cell
            if rx < 0 then rx = 0 end
            if ry < 0 then ry = 0 end
            if rx + rw > width then rw = math.max(0, width - rx) end
            if ry + rh > height then rh = math.max(0, height - ry) end

            if rw > 0 and rh > 0 then
                -- focused client on the selected tag renders purple;
                -- minimized clients render dim; others render grey
                local c_fill
                if c == client.focus and is_selected then
                    c_fill = COLOR_PURPLE
                elseif c.minimized then
                    c_fill = COLOR_DIM
                else
                    c_fill = COLOR_OCC
                end
                cr:set_source_rgba(hex_to_rgba(c_fill, 0.85))
                cr:rectangle(rx, ry, rw, rh)
                cr:fill()
                cr:set_source_rgba(hex_to_rgba(COLOR_FG, 0.6))
                cr:set_line_width(0.5)
                cr:rectangle(rx + 0.25, ry + 0.25, math.max(0, rw - 0.5), math.max(0, rh - 0.5))
                cr:stroke()

                -- tiny client icon, only when the rect is big enough to read it
                if rw >= 10 and rh >= 10 then
                    local isurf = resolve_icon_surface(c)
                    if isurf and cairo.Surface:is_type_of(isurf) then
                        local iw, ih = gsurface.get_size(isurf)
                        if iw and ih and iw > 0 and ih > 0 then
                            local target = math.min(rw, rh) * 0.7
                            local iscale = target / math.max(iw, ih)
                            cr:save()
                            cr:translate(rx, ry)
                            cr:scale(iscale, iscale)
                            cr:set_source_surface(isurf, (rw / iscale - iw) / 2, (rh / iscale - ih) / 2)
                            cr:paint()
                            cr:restore()
                        end
                    end
                end
            end
        end
    end

    -- border: purple (2px) for selected, gold for viewed, black for the rest
    cr:set_source_rgba(hex_to_rgba(is_selected and COLOR_PURPLE or (is_viewed and COLOR_GOLD or COLOR_BG), 1))
    cr:set_line_width((is_selected or is_viewed) and 2 or 1)
    cr:rectangle(0.5, 0.5, width - 1, height - 1)
    cr:stroke()

    -- tag name (first token, e.g. "1", "0", "-", "=") top-left
    -- draw a semi-transparent background pill so the name is readable over any content
    cr:set_font_size(9)
    local first = t.name:match("^(%S+)") or t.name
    local text_w = cr:text_extents(first).width
    -- fixed pill height for consistent placement regardless of glyph height
    local pill_h = 12
    cr:set_source_rgba(0, 0, 0, 0.6)
    cr:rectangle(1, 1, text_w + 4, pill_h)
    cr:fill()
    cr:set_source_rgba(hex_to_rgba(fg, 1))
    cr:move_to(3, 10)
    cr:show_text(first)

    return surf
end


-- hit-test: find which client rectangle was clicked within a cell
-- returns the client or nil
-- uses the same stacked order as the renderer; iterates in reverse
-- (topmost first) so the visually topmost client is selected on overlap
local function hit_test_client(t, cell_w, cell_h, click_x, click_y)
    if not t or not t.valid then return nil end
    local s = t.screen
    local sg = (s and s.valid and s.geometry) or { x = 0, y = 0, width = 1920, height = 1080 }
    local lg = landscape_geom(sg)
    local scale = math.min(cell_w / lg.width, cell_h / lg.height)
    local tag_clients = tag_clients_stacked(t)
    for i = #tag_clients, 1, -1 do
        local c = tag_clients[i]
        if c.valid then
            local cg = unrotate_client(c:geometry(), sg)
            local rx = (cg.x - lg.x) * scale
            local ry = (cg.y - lg.y) * scale
            local rw = math.max(1, cg.width * scale)
            local rh = math.max(1, cg.height * scale)
            if click_x >= rx and click_x <= rx + rw and click_y >= ry and click_y <= ry + rh then
                return c
            end
        end
    end
    return nil
end


-- drag state
-- drag_gen is a generation token: each start_drag increments it and the
-- active grabber captures the current value. a stale grabber closure from
-- a previous drag bails out when it sees gen ~= drag_gen, so it can never
-- move the client captured by an earlier drag.
local drag_gen = 0
local drag_client = nil
local drag_source_tag = nil
local drag_start_x, drag_start_y = nil, nil
local DRAG_THRESHOLD = 5


-- find which cell the mouse is over by checking each cell's screen geometry
-- via the wibar's widget hierarchy
local function find_cell_under_mouse(mx, my)
    local wb = mouse.current_wibox
    if not wb then return nil end

    -- find_widgets expects coordinates relative to the wibox drawable
    local wgeo = wb:geometry()
    local lx = mx - wgeo.x
    local ly = my - wgeo.y

    local hits = wb:find_widgets(lx, ly)
    if not hits then return nil end

    for _, hit in ipairs(hits) do
        for _, entry in ipairs(cells) do
            if hit.widget == entry.imagebox and entry.tag and entry.tag.valid then
                return entry.tag
            end
        end
    end
    return nil
end


local function start_drag(c, source_tag, start_x, start_y)
    drag_gen = drag_gen + 1
    local gen = drag_gen
    drag_client = c
    drag_source_tag = source_tag
    drag_start_x = start_x
    drag_start_y = start_y

    -- stop any grabber left over from a previous drag before starting a
    -- new one. somewm's mousegrabber does not reliably replace a running
    -- grabber, so without this the previous drag's closure (capturing the
    -- previous client) could handle this drag's drop and move the wrong
    -- client. the gen guard below is a backstop for the same race.
    if capi.mousegrabber.isrunning and capi.mousegrabber.isrunning() then
        capi.mousegrabber.stop()
    end

    -- safety timeout: force-stop the grabber after 10 seconds so a missed
    -- button-release event (or a Lua error in the callback) can never
    -- leave the grabber permanently intercepting all mouse input
    local drag_safety_timer = gears.timer {
        timeout = 10,
        single_shot = true,
        callback = guarded(function()
            if gen == drag_gen then
                drag_client = nil
                drag_source_tag = nil
                drag_start_x = nil
                drag_start_y = nil
            end
            if capi.mousegrabber.isrunning and capi.mousegrabber.isrunning() then
                capi.mousegrabber.stop()
            end
        end),
    }

    capi.mousegrabber.run(function(m)
        -- a newer drag has started; ignore this stale closure
        if gen ~= drag_gen then
            drag_safety_timer:stop()
            return false
        end

        if not c or not c.valid then
            if gen == drag_gen then
                drag_client = nil
                drag_source_tag = nil
            end
            drag_safety_timer:stop()
            return false
        end

        -- drop on left button release
        if not (m.buttons and m.buttons[1]) then
            -- wrap drop/click logic in pcall so a Lua error can never
            -- prevent return false from being reached, which would leave
            -- the grabber running and swallow all mouse input
            local ok, err = pcall(function()
                local moved = math.abs(m.x - start_x) > DRAG_THRESHOLD
                    or math.abs(m.y - start_y) > DRAG_THRESHOLD

                if moved then
                    -- drag: move client to target tag
                    local target_tag = find_cell_under_mouse(m.x, m.y)
                    if target_tag and target_tag.valid and target_tag ~= source_tag then
                        c:move_to_tag(target_tag)
                        -- awful.layout.arrange is async (timer.delayed_call):
                        -- calling target_tag:view_only() immediately would
                        -- switch the selected tag before the source tag's
                        -- layout reflows, leaving the remaining client at
                        -- its stale geometry. defer view_only until the
                        -- source screen's arrange signal fires, so the
                        -- remaining client gets its new full-screen geometry
                        -- first and the pager renders it correctly.
                        local src_screen = source_tag and source_tag.valid and source_tag.screen
                        if src_screen and src_screen.valid then
                            local arrange_handler
                            arrange_handler = function()
                                src_screen:disconnect_signal("arrange", arrange_handler)
                                if target_tag and target_tag.valid then
                                    target_tag:view_only()
                                end
                                debounced_refresh()
                            end
                            src_screen:connect_signal("arrange", guarded(arrange_handler))
                            -- safety fallback in case arrange never fires
                            gears.timer {
                                timeout = 0.1,
                                single_shot = true,
                                callback = guarded(function()
                                    src_screen:disconnect_signal("arrange", arrange_handler)
                                    if target_tag and target_tag.valid then
                                        target_tag:view_only()
                                    end
                                    debounced_refresh()
                                end),
                            }:start()
                        else
                            target_tag:view_only()
                        end
                    end
                else
                    -- click without drag: switch to source tag and focus client
                    source_tag:view_only()
                    c.minimized = false
                    c:emit_signal("request::activate", "tag_pager", { raise = true })
                end
            end)
            if not ok then
                require("gears.debug").print_warning("tag_pager drag error: " .. tostring(err))
            end

            if gen == drag_gen then
                drag_client = nil
                drag_source_tag = nil
                drag_start_x = nil
                drag_start_y = nil
            end
            drag_safety_timer:stop()
            debounced_refresh()
            return false
        end

        return true
    end, "fleur")

    drag_safety_timer:start()
end


local function make_cell(t, cell_height)
    local s = t.screen
    local sg = (s and s.valid and s.geometry) or { width = 1920, height = 1080 }
    local lg = landscape_geom(sg)
    local aspect = lg.width / lg.height
    local cell_w = math.floor(cell_height * aspect)
    local cell_h = cell_height

    local img = wibox.widget.imagebox()
    img.resize = true
    img.forced_width = cell_w
    img.forced_height = cell_h

    local surf = render_cell_surface(cell_w, cell_h, t)
    img:set_image(surf)

    img:connect_signal("button::press", function(_, lx, ly, button)
        if button == 1 and t and t.valid then
            -- hit-test: was a window rectangle clicked?
            local clicked_c = hit_test_client(t, cell_w, cell_h, lx, ly)
            if clicked_c then
                -- start drag/click handler (threshold distinguishes click from drag)
                local coords = mouse.coords()
                start_drag(clicked_c, t, coords.x, coords.y)
            else
                -- empty area: switch to this tag
                t:view_only()
            end
        elseif button == 3 and t and t.valid then
            awful.tag.viewtoggle(t)
        elseif button == 2 and t and t.valid then
            M.show(t)
        elseif (button == 4 or button == 5) and t and t.valid then
            -- scroll wheel: cycle through tags relative to the currently selected tag
            local s = t.screen
            if not s or not s.valid then return end
            local stags = s.tags
            local sel = s.selected_tag
            if not sel then return end
            local cur_idx = sel.index
            if not cur_idx then return end
            local dir = (button == 4) and -1 or 1
            local new_idx = ((cur_idx - 1 + dir) % #stags) + 1
            stags[new_idx]:view_only()
        end
    end)

    table.insert(cells, { imagebox = img, tag = t, width = cell_w, height = cell_h, screen = s })
    return img
end


-- MARK: INLINE PAGER WIDGET


function M.create_pager_widget(s, cell_height)
    cell_height = cell_height or 24
    local layout = wibox.layout.fixed.horizontal()
    layout.spacing = 0
    for _, t in ipairs(s.tags) do
        layout:add(make_cell(t, cell_height))
    end
    -- vertically center the row within the (taller) bar
    return wibox.widget {
        layout,
        valign = "center",
        widget = wibox.container.place,
    }
end


-- MARK: REFRESH


refresh = function()
    for _, entry in ipairs(cells) do
        if entry and entry.imagebox and entry.tag and entry.tag.valid then
            local surf = render_cell_surface(entry.width, entry.height, entry.tag)
            entry.imagebox:set_image(surf)
        end
    end
end


-- MARK: DEBOUNCED REFRESH
-- // MARK --debounce


-- coalesce rapid signal bursts (e.g. on restart when all clients are
-- re-managed and each fires property::geometry, tagged, focus, ...) into
-- a single render pass. without this, 15 signal connections × N clients
-- × 12 cells = thousands of cairo surface renders in interpreted Lua
-- (jit.off is active), freezing the UI for several seconds on restart.
local refresh_timer
local refresh_pending = false
local REFRESH_DELAY = 1 / 60  -- one frame; fast enough to feel immediate

debounced_refresh = function()
    if refresh_pending then return end
    refresh_pending = true
    if not refresh_timer then
        refresh_timer = gears.timer {
            timeout   = REFRESH_DELAY,
            single_shot = true,
            callback  = guarded(function()
                refresh_pending = false
                refresh()
            end),
        }
    end
    refresh_timer:again()
end


-- MARK: PER-TAG DETAIL POPUP
-- // MARK --detail


local popup_instance
local ignore_next_wibar_click = false


local function build_detail_tile(c, t)
    local icon = wibox.widget {
        image         = c.icon,
        forced_width  = dpi(48),
        forced_height = dpi(48),
        resize       = true,
        widget       = wibox.widget.imagebox,
    }
    local title = wibox.widget {
        text          = c.name or c.class or "?",
        wrap          = "word_char",
        forced_width  = dpi(140),
        widget        = wibox.widget.textbox,
    }
    local ntags = #(c:tags() or {})
    local badge = ntags > 1 and string.format("  x%d", ntags) or ""
    local badge_w = wibox.widget {
        markup = "<span fgcolor='" .. COLOR_GOLD .. "' size='small'>" .. badge .. "</span>",
        widget = wibox.widget.textbox,
    }
    local inner = wibox.widget {
        icon,
        { title, badge_w, layout = wibox.layout.fixed.vertical },
        spacing = dpi(4),
        layout  = wibox.layout.fixed.vertical,
    }
    local bg = wibox.widget {
        inner,
        forced_width  = dpi(150),
        bg            = c.minimized and COLOR_DIM or COLOR_BG,
        border_width  = dpi(1),
        border_color  = c.minimized and COLOR_DIM or COLOR_OCC,
        widget       = wibox.container.background,
    }
    bg:connect_signal("mouse::enter", function() bg.bg = "#ffffff22" end)
    bg:connect_signal("mouse::leave", function()
        bg.bg = c.minimized and COLOR_DIM or COLOR_BG
    end)
    bg:connect_signal("button::press", function(_, _, _, button)
        if button == 1 and c and c.valid and t and t.valid then
            t:view_only()
            c.minimized = false
            c:emit_signal("request::activate", "tag_pager", { raise = true })
            M.hide()
        end
    end)
    return bg
end


local function build_detail_body(tag)
    local clients = tag:clients() or {}
    local per_row = math.max(1, math.ceil(math.sqrt(#clients)))

    local header = wibox.widget {
        markup = "<span fgcolor='" .. COLOR_GOLD .. "'><b>"
            .. gstring.xml_escape(tag.name)
            .. "</b></span>  <span fgcolor='" .. COLOR_OCC .. "'>"
            .. gstring.xml_escape((tag.layout and tag.layout.name) or "?")
            .. "</span>",
        align  = "center",
        widget = wibox.widget.textbox,
    }

    local grid = wibox.layout.fixed.vertical()
    grid.spacing = dpi(8)
    local row
    for i, c in ipairs(clients) do
        if (i - 1) % per_row == 0 then
            row = wibox.layout.fixed.horizontal()
            row.spacing = dpi(8)
            grid:add(row)
        end
        row:add(build_detail_tile(c, tag))
    end

    return wibox.widget {
        header,
        { grid, margins = dpi(12), widget = wibox.container.margin },
        layout = wibox.layout.fixed.vertical,
    }
end


-- MARK: POPUP LIFECYCLE


local function ensure_popup()
    if popup_instance then return popup_instance end
    popup_instance = awful.popup {
        ontop        = true,
        visible      = false,
        border_width = dpi(2),
        border_color = COLOR_GOLD,
        widget       = wibox.widget.textbox(""),
    }
    return popup_instance
end


function M.show(opt_tag)
    local popup = ensure_popup()
    if popup.visible then return end

    local s = awful.screen.focused()
    local tag = opt_tag or (s and s.selected_tag)
    if not tag then return end

    popup.screen = s
    popup.widget = build_detail_body(tag)
    popup.visible = true
    awful.placement.centered(popup, { honor_workarea = true })

    -- outside-click detection via client + wibar button::press signals
    -- (root:get_buttons()/set_buttons() are X11-only and not available in somewm)
    popup._client_click_handler = guarded(function()
        if popup_instance and popup_instance.visible then M.hide() end
    end)
    client.connect_signal("button::press", popup._client_click_handler)

    popup._screen_handlers = {}
    for sc in screen do
        if sc.mywibox then
            local handler = function()
                if not popup_instance or not popup_instance.visible then return end
                if ignore_next_wibar_click then
                    ignore_next_wibar_click = false
                    return
                end
                M.hide()
            end
            sc.mywibox:connect_signal("button::press", handler)
            table.insert(popup._screen_handlers, { wibox = sc.mywibox, handler = handler })
        end
    end

    -- Escape closes the popup (added temporarily via root._append_key)
    -- (root:get_keys()/set_keys() are X11-only and not available in somewm)
    popup._escape_key = awful.key({}, "Escape", function()
        if popup_instance and popup_instance.visible then M.hide() end
    end)
    if root._append_key then
        root._append_key(popup._escape_key)
    end
end


function M.hide()
    if not popup_instance or not popup_instance.visible then return end

    -- safety net: stop any lingering drag grabber so closing the popup
    -- can never leave mouse input intercepted
    if capi.mousegrabber.isrunning and capi.mousegrabber.isrunning() then
        capi.mousegrabber.stop()
    end
    drag_gen = drag_gen + 1
    drag_client = nil
    drag_source_tag = nil

    if popup_instance._escape_key then
        if root._remove_key then
            root._remove_key(popup_instance._escape_key)
        end
        popup_instance._escape_key = nil
    end
    if popup_instance._client_click_handler then
        client.disconnect_signal("button::press", popup_instance._client_click_handler)
        popup_instance._client_click_handler = nil
    end
    if popup_instance._screen_handlers then
        for _, entry in ipairs(popup_instance._screen_handlers) do
            entry.wibox:disconnect_signal("button::press", entry.handler)
        end
        popup_instance._screen_handlers = nil
    end

    popup_instance.visible = false
end


function M.toggle(opt_tag)
    if popup_instance and popup_instance.visible then
        M.hide()
    else
        M.show(opt_tag)
    end
end


-- MARK: INITIALIZATION


function M.init()
    ensure_popup()

    -- redraw cells on any change that affects their appearance.
    -- all signal handlers use debounced_refresh so a burst of signals
    -- (e.g. on restart when every client is re-managed) coalesces into
    -- a single render pass instead of freezing the UI.
    local guarded_refresh = guarded(debounced_refresh)
    tag.connect_signal("property::selected", guarded_refresh)
    tag.connect_signal("property::clients", guarded_refresh)
    client.connect_signal("property::geometry", guarded_refresh)
    client.connect_signal("property::minimized", guarded_refresh)
    client.connect_signal("property::hidden", guarded_refresh)
    client.connect_signal("tagged", guarded_refresh)
    client.connect_signal("untagged", guarded_refresh)
    -- maximized/fullscreen/floating changes affect geometry but may not
    -- always emit property::geometry before the layout settles, so listen
    -- to these explicitly to catch maximized-window state changes
    client.connect_signal("property::maximized", guarded_refresh)
    client.connect_signal("property::maximized_horizontal", guarded_refresh)
    client.connect_signal("property::maximized_vertical", guarded_refresh)
    client.connect_signal("property::fullscreen", guarded_refresh)
    client.connect_signal("property::floating", guarded_refresh)
    -- focus changes affect stacking order in the cell rendering
    client.connect_signal("focus", guarded_refresh)
    client.connect_signal("unfocus", guarded_refresh)
    -- somewm emits this on tag view changes
    screen.connect_signal("tag::history::update", guarded_refresh)
end

-- pre-build the popup so the first open has no delay
ensure_popup()

return M
