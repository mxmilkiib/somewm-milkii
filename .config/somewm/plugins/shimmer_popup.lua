-- plugins/shimmer_popup.lua
-- Clickable popup anchored to the wibar shimmer widget. Exposes the shimmer
-- animation controls (preset, colour/shine progression, speeds, run toggle)
-- as interactive rows, replacing the notification-based status for mouse use.
--
-- Talks to plugins.shimmer.animation directly so cycling happens without the
-- _notify wrappers (the popup itself shows the resulting state, so a parallel
-- naughty notification would be redundant).
--
-- One shared popup is created lazily and re-anchored to whichever shimmer
-- widget is clicked (the wibar is built per-screen).

local awful   = require("awful")
local gears   = require("gears")
local wibox   = require("wibox")
local beautiful = require("beautiful")
local guarded = require("error_guard")
local popup_common = require("plugins.popup_common")
local animation = require("plugins.shimmer.animation")
local gshape  = require("gears.shape")

local dpi = beautiful.xresources.apply_dpi

local COLOR_PURPLE = popup_common.theme.PURPLE
local COLOR_BLACK  = popup_common.theme.BLACK
local COLOR_WHITE  = popup_common.theme.WHITE
local COLOR_GOLD   = popup_common.theme.GOLD
local COLOR_GREY   = popup_common.theme.GREY
local COLOR_GREEN  = popup_common.theme.GREEN
local COLOR_RED    = popup_common.theme.RED
local COLOR_HOVER  = popup_common.theme.HOVER
local FONT       = popup_common.fonts.FONT
local FONT_INFO  = popup_common.fonts.FONT_INFO
local FONT_VALUE = popup_common.fonts.FONT_VALUE
-- two-column body: preset list left, controls right
local CONTENT_W    = dpi(560)
local PRESET_COL_W = dpi(170)
local CTRL_COL_W   = CONTENT_W - PRESET_COL_W - dpi(12)
-- label/value column widths shared by every control row so the values form
-- a single left-aligned column rather than hugging each row's buttons
local LABEL_W = dpi(112)
local VALUE_W = dpi(150)

local M = {}

local popup
-- holder table: draggable_header reads popup from here so build_content can
-- run before the awful.popup is constructed (awful.popup requires a widget arg)
local popup_holder = {}
local hide
local ctrl
-- forward declarations: glyph_button/state-button click handlers call these
-- to re-read state and repaint the mode grids
local refresh_popup
local paint_mode_cells
-- value textboxes, refreshed by refresh_popup after each control click
local run_label
local speed_val, colspd_val, shnspd_val, fps_val
-- on/off textboxes in the prog section headers (folded-in disable flags)
local colour_state_val, shine_state_val
local animchars_val, strategy_val
-- direct-select mode cells in the prog grids, keyed by mode name
local colour_mode_cells, shine_mode_cells = {}, {}
local colour_mode_cell_bg, shine_mode_cell_bg = {}, {}
-- palette preview bar + live sample lines + preset list cells
local preview_bar, sample_w, swatch_w
local preset_cells = {}
local preset_cell_bg = {}
local preset_tints = {}
local preset_head
local preset_list_widget
-- slider sync functions: refresh_popup pushes engine state into the sliders
-- without triggering their property::value write-back
local sync_speed, sync_colspd, sync_shnspd
-- confirm/cancel: config snapshot taken on show; Apply keeps the live edits,
-- Cancel restores them. transient closes (outside click, pin) keep changes
local snapshot
-- live sample: local phase offset drives get_letter_shimmer_markup so the
-- example animates even while the engine is stopped
local preview_phase = 0
local preview_timer
-- border shimmer: sweeps the popup's own border through the preset palette
-- while visible. persisted separately from the confirm/cancel snapshot since
-- it is a popup preference, not engine state
local border_fx
local border_fx_val, border_fx_timer
-- ping-pong sweep state, same parameters as the client border animation in
-- shimmer/border.lua (speed 0.15s, step 1.0, phase offset 3.0)
local border_loop = 1.0
local border_step = 1.0
local BORDER_PHASE_OFFSET = 3.0
local BORDER_FX_PREF = require("gears.filesystem").get_cache_dir()
    .. "shimmer_popup_border_fx"

local function load_border_fx()
    local f = io.open(BORDER_FX_PREF, "r")
    if not f then return false end
    local v = f:read("*l")
    f:close()
    return v == "1"
end

local function save_border_fx()
    local f = io.open(BORDER_FX_PREF, "w")
    if f then f:write(border_fx and "1" or "0") f:close() end
end

border_fx = load_border_fx()


-- // MARK -- WIDGET HELPERS

local make_text = popup_common.make_text

-- separators inside the controls column shrink to its width; the full-width
-- ones between body sections take the default
local function separator(width)
    return popup_common.separator(width or CONTENT_W)
end

-- small clickable glyph button with hover feedback. returns the widget
local function glyph_button(label, on_click)
    local txt = wibox.widget {
        markup = string.format('<span foreground="%s">%s</span>', COLOR_WHITE, label),
        font = FONT,
        align = "center",
        valign = "center",
        widget = wibox.widget.textbox,
    }
    local bg = wibox.widget {
        { txt, halign = "center", valign = "center", widget = wibox.container.place },
        forced_width = dpi(22),
        top = dpi(2), bottom = dpi(2),
        shape = function(cr, w, h)
            gshape.rounded_rect(cr, w, h, dpi(3))
        end,
        widget = wibox.container.background,
    }
    bg:connect_signal("mouse::enter", function() bg.bg = COLOR_HOVER end)
    bg:connect_signal("mouse::leave", function() bg.bg = nil end)
    bg:buttons(gears.table.join(awful.button({}, 1, guarded(function()
        on_click()
        refresh_popup()
    end))))
    return bg
end

-- label + value pair pinned to LABEL_W/VALUE_W columns so every row's value
-- text starts at the same x, forming a readable column. spacing keeps the
-- value from touching a long label ("Border shimmer" + "off")
local function make_label_value(label, value_text)
    local label_w = make_text(label, COLOR_GREY, FONT)
    local value_w = make_text(value_text, COLOR_GOLD, FONT_VALUE)
    value_w.align = "left"
    local pair = wibox.widget {
        { label_w, forced_width = LABEL_W, widget = wibox.container.background },
        { value_w, forced_width = VALUE_W, widget = wibox.container.background },
        spacing = dpi(8),
        layout = wibox.layout.fixed.horizontal,
    }
    return pair, value_w
end

-- one control row: "Label | value        ◄ ►"
-- the value textbox is returned via `value_w` so refresh_popup can update it.
-- on_cycle(dir) is called on scroll-wheel over the row so long lists can be
-- spun through without clicking the arrows per step
local function make_row(label, value_text, left_btn, right_btn, on_cycle, extra_btn)
    local pair, value_w = make_label_value(label, value_text)
    local buttons = wibox.widget {
        left_btn, right_btn, extra_btn,
        spacing = dpi(4),
        layout = wibox.layout.fixed.horizontal,
    }
    local row = wibox.widget {
        {
            pair,
            wibox.widget { widget = wibox.container.background },
            buttons,
            expand = "inside",
            layout = wibox.layout.align.horizontal,
        },
        left = dpi(8), right = dpi(6),
        top = dpi(3), bottom = dpi(3),
        widget = wibox.container.margin,
    }
    if on_cycle then
        row:buttons(gears.table.join(
            awful.button({}, 4, guarded(function() on_cycle(-1); refresh_popup() end)),
            awful.button({}, 5, guarded(function() on_cycle(1);  refresh_popup() end))
        ))
    end
    return row, value_w
end

-- small on/off state button for the prog rows: the text shows the current
-- state so it reads as a status, not just a control. returns widget + the
-- textbox so refresh_popup can repaint it
local function state_button(on_toggle)
    local txt = wibox.widget {
        font = FONT,
        align = "center",
        valign = "center",
        widget = wibox.widget.textbox,
    }
    local bg = wibox.widget {
        { txt, halign = "center", valign = "center", widget = wibox.container.place },
        forced_width = dpi(30),
        top = dpi(2), bottom = dpi(2),
        shape = function(cr, w, h)
            gshape.rounded_rect(cr, w, h, dpi(3))
        end,
        widget = wibox.container.background,
    }
    bg:connect_signal("mouse::enter", function() bg.bg = COLOR_HOVER end)
    bg:connect_signal("mouse::leave", function() bg.bg = nil end)
    bg:buttons(gears.table.join(awful.button({}, 1, guarded(function()
        on_toggle()
        refresh_popup()
    end))))
    return bg, txt
end

-- a row whose right side is a single toggle button (used for run/disable)
local function make_toggle_row(label, value_text, btn)
    local pair, value_w = make_label_value(label, value_text)
    local row = wibox.widget {
        {
            pair,
            wibox.widget { widget = wibox.container.background },
            btn,
            expand = "inside",
            layout = wibox.layout.align.horizontal,
        },
        left = dpi(8), right = dpi(6),
        top = dpi(3), bottom = dpi(3),
        widget = wibox.container.margin,
    }
    return row, value_w
end


-- draggable slider row: "Label  ──●─────  value". get/set bridge to the
-- engine; fmt renders the value text. returns the row and a sync(v) that
-- pushes engine state into the slider without firing its write-back
local function make_slider_row(label, min, max, to_slider, from_slider, set, fmt)
    local pair, value_w = make_label_value(label, " ")
    local slider = wibox.widget {
        bar_shape = gshape.rounded_rect,
        bar_height = dpi(3),
        bar_color = COLOR_GREY .. "44",
        bar_active_color = COLOR_PURPLE,
        handle_color = COLOR_GOLD,
        handle_shape = gshape.circle,
        handle_width = dpi(10),
        minimum = min,
        maximum = max,
        value = min,
        widget = wibox.widget.slider,
    }
    local syncing = false
    slider:connect_signal("property::value", guarded(function(_, v)
        if syncing then return end
        set(from_slider(v))
        value_w.text = fmt(from_slider(v))
    end))
    local row = wibox.widget {
        {
            pair,
            {
                -- slider fit is unbounded; the popup sizes itself from content
                -- fit, so the track must be clamped explicitly
                {
                    slider,
                    strategy = "exact",
                    width = CTRL_COL_W - dpi(24),
                    height = dpi(14),
                    widget = wibox.container.constraint,
                },
                left = dpi(2), top = dpi(2), bottom = dpi(2),
                widget = wibox.container.margin,
            },
            layout = wibox.layout.fixed.vertical,
        },
        left = dpi(8), right = dpi(6),
        top = dpi(3), bottom = dpi(3),
        widget = wibox.container.margin,
    }
    return row, value_w, function(engine_v)
        syncing = true
        slider.value = to_slider(engine_v)
        syncing = false
        value_w.text = fmt(engine_v)
    end
end

-- palette preview: a thin gradient bar sampled from the current preset's
-- palette so the selected flavour is visible without enabling animation
local function paint_preview()
    if not preview_bar then return end
    local pal = animation.get_palette and animation.get_palette(animation.get_current_preset())
    if not pal or #pal == 0 then
        preview_bar.bg = nil
        return
    end
    local n, stops = 8, {}
    for i = 0, n do
        stops[#stops + 1] = { i / n, pal[1 + math.floor(i * (#pal - 1) / n)] }
    end
    preview_bar.bg = gears.color {
        type = "linear", from = { 0, 0 }, to = { CONTENT_W - dpi(20), 0 },
        stops = stops,
    }
end

-- preset list column: every preset as a clickable row, current one gold.
-- direct selection beats cycling 18 entries with ◄ ►
local CHAR_STRATEGIES = { "wave", "center_out", "edges_in", "random" }

local function paint_preset_cells()
    local cur = animation.get_current_preset()
    -- column header carries the position: "Preset 5/18"
    if preset_head then
        local list = animation.get_preset_list()
        local idx = 0
        for i, name in ipairs(list) do
            if name == cur then idx = i break end
        end
        preset_head.text = string.format("Preset %d/%d", idx, #list)
    end
    for name, cell in pairs(preset_cells) do
        -- each name is tinted with a colour from its own palette; the current
        -- preset is marked by the background wash rather than a recolour
        cell.markup = string.format('<span foreground="%s">%s</span>',
            preset_tints[name] or COLOR_GREY, name)
        local bg = preset_cell_bg[name]
        if bg then bg.bg = name == cur and COLOR_PURPLE .. "66" or nil end
    end
end

-- one clickable preset row in the left column; called once per preset at
-- build time and again by the save button when a user preset is added
local function add_preset_cell(list, name)
    if preset_cells[name] then return end
    local cell = wibox.widget {
        font = FONT_INFO,
        align = "left",
        valign = "center",
        widget = wibox.widget.textbox,
    }
    preset_cells[name] = cell
    -- a colour sampled near the bright end of the preset's own palette;
    -- lazy palette generation is cached, so this also warms it for the
    -- real engine
    local pal = animation.get_palette and animation.get_palette(name)
    if pal and #pal > 0 then
        preset_tints[name] = pal[math.max(1, math.floor(#pal * 0.8))]
    end
    local bg = wibox.widget {
        { cell, left = dpi(8), top = dpi(2), bottom = dpi(2), widget = wibox.container.margin },
        forced_width = PRESET_COL_W,
        shape = function(cr, w, h) gshape.rounded_rect(cr, w, h, dpi(3)) end,
        widget = wibox.container.background,
    }
    preset_cell_bg[name] = bg
    bg:connect_signal("mouse::enter", function() bg.bg = COLOR_HOVER end)
    -- restore the selection wash on leave rather than clearing blindly
    bg:connect_signal("mouse::leave", function()
        bg.bg = name == animation.get_current_preset() and COLOR_PURPLE .. "66" or nil
    end)
    bg:buttons(gears.table.join(awful.button({}, 1, guarded(function()
        animation.set_mode(name)
        refresh_popup()
    end))))
    list:add(bg)
end

local function build_preset_list()
    local list = wibox.widget {
        spacing = dpi(1),
        layout = wibox.layout.fixed.vertical,
    }
    for _, name in ipairs(animation.get_preset_list()) do
        add_preset_cell(list, name)
    end
    -- scroll over the list cycles presets, same as the old row buttons
    list:buttons(gears.table.join(
        awful.button({}, 4, guarded(function() animation.cycle_preset(-1); refresh_popup() end)),
        awful.button({}, 5, guarded(function() animation.cycle_preset(1);  refresh_popup() end))
    ))
    paint_preset_cells()
    return list
end


-- render a mode name through the real markup generator with that mode
-- applied and the other aspect switched off, so each cell previews its own
-- progression. phase tracks preview_phase so the cells animate in step
-- with the sample lines
local function mode_preview_markup(name, aspect)
    local opts = aspect == "colour"
        and { colour_prog_mode = name, shine_prog_mode = "shine_prog_off" }
        or  { shine_prog_mode = name, colour_prog_mode = "colour_prog_off" }
    return animation.get_letter_shimmer_markup(name, preview_phase, opts) or name
end

-- two-column grid of every progression mode for one aspect (colour or
-- shine): each cell is a live preview of its mode, selection shown by the
-- purple wash like the preset cells. direct click selects
local function build_mode_grid(modes, cells, cell_bg, set_mode)
    local grid = wibox.layout.grid()
    grid.forced_num_cols = 2
    grid.spacing = dpi(1)
    for _, name in ipairs(modes) do
        local cell = wibox.widget {
            font = FONT_INFO,
            align = "left",
            valign = "center",
            widget = wibox.widget.textbox,
        }
        cells[name] = cell
        local bg = wibox.widget {
            { cell, left = dpi(8), top = dpi(2), bottom = dpi(2), widget = wibox.container.margin },
            shape = function(cr, w, h) gshape.rounded_rect(cr, w, h, dpi(3)) end,
            widget = wibox.container.background,
        }
        cell_bg[name] = bg
        local current = name
        bg:connect_signal("mouse::enter", function() bg.bg = COLOR_HOVER end)
        bg:connect_signal("mouse::leave", function() bg.bg = nil; paint_mode_cells() end)
        bg:buttons(gears.table.join(awful.button({}, 1, guarded(function()
            set_mode(current)
            refresh_popup()
        end))))
        grid:add(bg)
    end
    return grid
end

-- repaint both mode grids: live per-mode previews in the cells, purple
-- wash on the active mode
paint_mode_cells = function()
    local cc = animation.get_colour_prog_mode and animation.get_colour_prog_mode() or "—"
    local cs = animation.get_shine_prog_mode and animation.get_shine_prog_mode() or "—"
    for name, cell in pairs(colour_mode_cells) do
        cell.markup = mode_preview_markup(name, "colour")
        local bg = colour_mode_cell_bg[name]
        if bg then bg.bg = name == cc and COLOR_PURPLE .. "66" or nil end
    end
    for name, cell in pairs(shine_mode_cells) do
        cell.markup = mode_preview_markup(name, "shine")
        local bg = shine_mode_cell_bg[name]
        if bg then bg.bg = name == cs and COLOR_PURPLE .. "66" or nil end
    end
end


-- live example: the sample text runs through the real span/markup generator
-- with a locally-advanced phase offset, so it reflects the pending settings
-- even while the engine itself is stopped
local SAMPLE_TEXT = "The quick brown fox jumps over the lazy dog - somewm"

local function paint_sample()
    if not sample_w then return end
    sample_w.markup = animation.get_letter_shimmer_markup(SAMPLE_TEXT, preview_phase)
        or SAMPLE_TEXT
end

-- palette spread line: the same sample painted with colours taken at
-- successive palette positions so the whole range is visible at a glance,
-- rotated by preview_phase so the spread drifts instead of sitting static
local function paint_swatch()
    if not swatch_w then return end
    local pal = animation.get_palette and animation.get_palette(animation.get_current_preset())
    if not pal or #pal == 0 then
        swatch_w.markup = ""
        return
    end
    local n = #SAMPLE_TEXT
    local parts = {}
    for i = 1, n do
        local pos = (i - 1) / math.max(n - 1, 1) + preview_phase * 0.05
        local idx = 1 + math.floor((pos % 1) * #pal)
        local ch = SAMPLE_TEXT:sub(i, i)
        parts[#parts + 1] = string.format('<span foreground="%s">%s</span>',
            pal[idx], ch == " " and " " or gears.string.xml_escape(ch))
    end
    swatch_w.markup = table.concat(parts)
end

local function ensure_preview_timer()
    if preview_timer then return end
    -- ~1 palette step per tick (offset ×0.3 ×8 ≈ 2.4 steps per +1.0)
    preview_timer = gears.timer {
        timeout = 0.1,
        autostart = false,
        single_shot = false,
        callback = guarded(function()
            preview_phase = preview_phase + 0.4
            paint_sample()
            paint_swatch()
            -- the mode cells are live previews, so they advance in step
            paint_mode_cells()
            return popup and popup.visible
        end),
    }
end

-- border shimmer: the same sweep the client border animation uses — a
-- ping-pong walk across the palette with RGB lerp between adjacent entries,
-- applied to the popup's border while the option is on and it is open
local function ensure_border_fx_timer()
    if border_fx_timer then return end
    border_fx_timer = gears.timer {
        timeout = 0.15,
        autostart = false,
        single_shot = false,
        callback = guarded(function()
            if not (popup and popup.visible and border_fx) then return false end
            local pal = animation.get_palette
                and animation.get_palette(animation.get_current_preset())
            if not pal or #pal < 2 then return true end
            local len = #pal

            border_loop = border_loop + border_step
            if border_loop >= len - 1 then
                border_loop = len - 1
                border_step = -1.0
            elseif border_loop <= 0 then
                border_loop = 0
                border_step = 1.0
            end

            local phase = border_loop + BORDER_PHASE_OFFSET
            local base_index = math.floor(phase)
            local index = (base_index % len) + 1
            local fraction = phase - base_index
            local next_index = (index % len) + 1

            local color1 = pal[index]
            local color2 = pal[next_index]
            local color = color1
            if fraction > 0 and color1 ~= color2 then
                local r1, g1, b1 = color1:match("#(%x%x)(%x%x)(%x%x)")
                local r2, g2, b2 = color2:match("#(%x%x)(%x%x)(%x%x)")
                if r1 and r2 then
                    r1, g1, b1 = tonumber(r1, 16), tonumber(g1, 16), tonumber(b1, 16)
                    r2, g2, b2 = tonumber(r2, 16), tonumber(g2, 16), tonumber(b2, 16)
                    color = string.format("#%02x%02x%02x",
                        math.floor(r1 + (r2 - r1) * fraction),
                        math.floor(g1 + (g2 - g1) * fraction),
                        math.floor(b1 + (b2 - b1) * fraction))
                end
            end
            popup.border_color = color
            return true
        end),
    }
end


-- confirm/cancel: snapshot the mutable config on show so Cancel can revert.
-- the set_mode restore runs first since it applies preset speeds, then the
-- explicit values overwrite them with the snapshotted ones
local SNAPSHOT_KEYS = {
    { get = "get_mode",                        set = "set_mode" },
    { get = "get_color_progression_mode",      set = "set_colour_prog_mode" },
    { get = "get_shine_progression_mode",      set = "set_shine_prog_mode" },
    { get = "get_speed_multiplier",            set = "set_speed_multiplier" },
    { get = "get_color_speed",                 set = "set_color_speed" },
    { get = "get_shine_speed",                 set = "set_shine_speed" },
    { get = "get_global_max_animated_chars",   set = "set_global_max_animated_chars" },
    { get = "get_char_selection_strategy",     set = "set_char_selection_strategy" },
    { get = "get_disable_shine",               set = "set_disable_shine" },
    { get = "get_disable_color",               set = "set_disable_color" },
}

local function take_snapshot()
    snapshot = {}
    for _, k in ipairs(SNAPSHOT_KEYS) do
        if animation[k.get] then snapshot[k.get] = animation[k.get]() end
    end
end

local function restore_snapshot()
    if not snapshot then return end
    if animation.set_mode and snapshot.get_mode then
        animation.set_mode(snapshot.get_mode)
    end
    for _, k in ipairs(SNAPSHOT_KEYS) do
        if k.set ~= "set_mode" and animation[k.set] then
            animation[k.set](snapshot[k.get])
        end
    end
    snapshot = nil
end


-- // MARK -- CONTENT

-- progression modes: every colour and shine mode listed at once in two
-- side-by-side grids, direct click to select, current one highlighted.
-- the on/off state button in each section header is the old disable flag;
-- the flag getters treat a zeroed speed as disabled, so it stays consistent
-- with the speed sliders. separate function so build_content stays under
-- the 60-upvalue limit
local function build_modes_row()
    local colour_state_btn, colour_state_txt = state_button(function()
        animation.set_disable_color(not animation.get_disable_color())
    end)
    colour_state_val = colour_state_txt
    local shine_state_btn, shine_state_txt = state_button(function()
        animation.set_disable_shine(not animation.get_disable_shine())
    end)
    shine_state_val = shine_state_txt

    local function prog_section(title, state_btn, modes, cells, cell_bg, set_mode)
        return wibox.widget {
            {
                {
                    make_text(title, COLOR_GREY, FONT),
                    wibox.widget { widget = wibox.container.background },
                    state_btn,
                    expand = "inside",
                    layout = wibox.layout.align.horizontal,
                },
                left = dpi(8), right = dpi(6),
                top = dpi(3), bottom = dpi(3),
                widget = wibox.container.margin,
            },
            {
                build_mode_grid(modes, cells, cell_bg, set_mode),
                left = dpi(6), right = dpi(6), bottom = dpi(4),
                widget = wibox.container.margin,
            },
            forced_width = (CONTENT_W - dpi(1)) / 2,
            layout = wibox.layout.fixed.vertical,
        }
    end

    local colour_modes_col = prog_section("Colour prog", colour_state_btn,
        animation.get_colour_progression_modes_list(),
        colour_mode_cells, colour_mode_cell_bg,
        function(m) animation.set_colour_prog_mode(m) end)
    local shine_modes_col = prog_section("Shine prog", shine_state_btn,
        animation.get_shine_progression_modes_list(),
        shine_mode_cells, shine_mode_cell_bg,
        function(m) animation.set_shine_prog_mode(m) end)

    local row = wibox.widget {
        colour_modes_col,
        wibox.widget {
            forced_width = dpi(1),
            bg = COLOR_GREY .. "33",
            widget = wibox.container.background,
        },
        shine_modes_col,
        layout = wibox.layout.fixed.horizontal,
    }
    paint_mode_cells()
    return row
end

local function build_content()
    -- header (title drag handle + detach + pin) and the detach/drag controller
    local header
    header, ctrl = popup_common.draggable_header {
        holder = popup_holder,
        name  = "shimmer_popup",
        title = "Shimmer",
        width = CONTENT_W,
        hide  = function() hide() end,
    }

    -- run toggle: value shows Running/Stopped; the glyph button starts/stops
    -- goes through the facade so border animation follows the same switch
    local run_row
    run_row, run_label = make_toggle_row("Animation", "Stopped",
        glyph_button("⏯", function()
            local shimmer = require("plugins.shimmer")
            if shimmer.is_running() then
                shimmer.stop()
            else
                shimmer.start()
            end
        end))

    -- live example: rendered through the same markup generator the tasklist
    -- uses, phase-advanced by the preview timer while the popup is visible
    sample_w = wibox.widget {
        text = SAMPLE_TEXT,
        font = FONT_VALUE,
        align = "center",
        valign = "center",
        widget = wibox.widget.textbox,
    }
    swatch_w = wibox.widget {
        text = SAMPLE_TEXT,
        font = FONT_VALUE,
        align = "center",
        valign = "center",
        widget = wibox.widget.textbox,
    }
    local sample_row = wibox.widget {
        {
            -- place containers centre the text regardless of how the fixed
            -- column sizes the textboxes
            { sample_w, halign = "center", widget = wibox.container.place },
            { swatch_w, halign = "center", widget = wibox.container.place },
            layout = wibox.layout.fixed.vertical,
        },
        forced_width = CONTENT_W,
        top = dpi(6), bottom = dpi(2),
        widget = wibox.container.margin,
    }

    -- palette preview strip under the sample: the preset's colours at a glance
    preview_bar = wibox.widget {
        forced_height = dpi(8),
        widget = wibox.container.background,
    }
    local preview_strip = wibox.widget {
        {
            preview_bar,
            shape = function(cr, w, h) gshape.rounded_rect(cr, w, h, dpi(2)) end,
            shape_border_width = dpi(1),
            shape_border_color = COLOR_GREY .. "66",
            widget = wibox.container.background,
        },
        left = dpi(10), right = dpi(10),
        top = dpi(2), bottom = dpi(4),
        widget = wibox.container.margin,
    }

    -- left column: the full preset list; the preset row is gone since direct
    -- click-select + scroll covers it
    preset_head = make_text("Preset", COLOR_GREY, FONT_INFO)
    preset_list_widget = build_preset_list()

    -- save: snapshots the effective current config as a new preset named
    -- "custom_N", persisted by animation.lua to the XDG data dir. click
    -- again to iterate the name
    local save_name_i = 0
    local function next_custom_name()
        repeat
            save_name_i = save_name_i + 1
            local name = "custom_" .. save_name_i
            local exists = false
            for _, p in ipairs(animation.get_preset_list()) do
                if p == name then exists = true break end
            end
            if not exists then return name end
        until false
    end
    local save_btn = glyph_button("＋ save", function()
        local name = animation.save_preset_as(next_custom_name())
        if name then
            add_preset_cell(preset_list_widget, name)
            animation.set_mode(name)
        end
    end)
    local preset_col = wibox.widget {
        {
            preset_head,
            left = dpi(8), bottom = dpi(2),
            widget = wibox.container.margin,
        },
        preset_list_widget,
        {
            save_btn,
            left = dpi(8), top = dpi(4),
            widget = wibox.container.margin,
        },
        forced_width = PRESET_COL_W,
        layout = wibox.layout.fixed.vertical,
    }

    -- progression modes get their own full-width section below the two
    -- columns; built by build_modes_row (build_content is at the 60-upvalue
    -- limit, so the section builders are separate functions)
    local modes_row = build_modes_row()

    -- speed multiplier: log-mapped slider 0.1–10 so ×0.5 and ×2 get equal
    -- travel (linear mapping would squeeze the whole useful band left of 10%)
    local LOG_LO, LOG_HI = 0.1, 10.0
    local function mult_to_slider(m) return math.log((m or 1) / LOG_LO) / math.log(LOG_HI / LOG_LO) end
    local function slider_to_mult(v) return LOG_LO * (LOG_HI / LOG_LO) ^ v end
    local speed_row, speed_v, sync_s = make_slider_row("Speed", 0, 1,
        mult_to_slider, slider_to_mult,
        function(m) animation.set_speed_multiplier(m) end,
        function(m) return string.format("×%.1f", m) end)
    speed_val, sync_speed = speed_v, sync_s

    -- colour/shine progression speeds: linear 0–5, 0 = disabled
    local colspd_row, colspd_v, sync_c = make_slider_row("Colour speed", 0, 5,
        function(s) return s or 0 end, function(v) return v end,
        function(v) animation.set_color_speed(v) end,
        function(v) return v == 0 and "off" or string.format("%.1f", v) end)
    colspd_val, sync_colspd = colspd_v, sync_c

    local shnspd_row, shnspd_v, sync_sh = make_slider_row("Shine speed", 0, 5,
        function(s) return s or 0 end, function(v) return v end,
        function(v) animation.set_shine_speed(v) end,
        function(v) return v == 0 and "off" or string.format("%.1f", v) end)
    shnspd_val, sync_shnspd = shnspd_v, sync_sh

    -- animated-character limit + selection strategy (the rotation window
    -- fixed in animation.lua; "all" clears the limit entirely)
    local ANIMCHARS_MAX = 32
    local function step_animchars(dir)
        local cur = animation.get_max_animated_chars() or 0
        cur = cur + dir
        if cur < 0 then cur = ANIMCHARS_MAX end
        if cur > ANIMCHARS_MAX then cur = 0 end
        -- the global override (not the per-preset field) is what the getter
        -- reads first, so the displayed value always matches the control
        animation.set_global_max_animated_chars(cur == 0 and nil or cur)
    end
    local animchars_row, animchars_v = make_row("Anim chars", "--",
        glyph_button("◄", function() step_animchars(-1) end),
        glyph_button("►", function() step_animchars(1) end),
        step_animchars)
    animchars_val = animchars_v

    local function step_strategy(dir)
        local cur = animation.get_char_selection_strategy() or "wave"
        local idx = 1
        for i, s in ipairs(CHAR_STRATEGIES) do if s == cur then idx = i break end end
        idx = ((idx - 1 + dir) % #CHAR_STRATEGIES) + 1
        animation.set_char_selection_strategy(CHAR_STRATEGIES[idx])
    end
    local strategy_row, strategy_v = make_row("Char select", "--",
        glyph_button("◄", function() step_strategy(-1) end),
        glyph_button("►", function() step_strategy(1) end),
        step_strategy)
    strategy_val = strategy_v

    -- border shimmer: sweeps this popup's border through the palette while
    -- visible. a popup preference rather than engine state, so it lives
    -- outside the confirm/cancel snapshot
    local bfx_row, bfx_v = make_toggle_row("Border shimmer", "off",
        glyph_button("⏯", function()
            border_fx = not border_fx
            save_border_fx()
            if border_fx then
                ensure_border_fx_timer()
                border_fx_timer:start()
            else
                if border_fx_timer then border_fx_timer:stop() end
                if popup then popup.border_color = COLOR_GOLD end
            end
        end))
    border_fx_val = bfx_v

    -- fps / timing line from get_speed_breakdown
    fps_val = make_text(" ", COLOR_GREY, FONT_INFO)
    local fps_block = wibox.widget {
        { fps_val, left = dpi(8), right = dpi(6),
            top = dpi(4), bottom = dpi(4), widget = wibox.container.margin },
        widget = wibox.container.background,
    }

    -- right column: every control row stacked; prog selection lives in the
    -- full-width modes section below the columns
    local controls_col = wibox.widget {
        run_row,
        separator(CTRL_COL_W),
        speed_row,
        colspd_row,
        shnspd_row,
        separator(CTRL_COL_W),
        animchars_row,
        strategy_row,
        separator(CTRL_COL_W),
        bfx_row,
        separator(CTRL_COL_W),
        fps_block,
        forced_width = CTRL_COL_W,
        layout = wibox.layout.fixed.vertical,
    }

    -- vertical divider between the preset list and the controls
    local vsep = wibox.widget {
        forced_width = dpi(1),
        bg = COLOR_GREY .. "33",
        widget = wibox.container.background,
    }

    -- wide text buttons for the bottom bar; confirm keeps the live edits,
    -- cancel restores the snapshot taken on show. glyph carries the colour,
    -- the label stays white
    local function bar_button(glyph, label, color, on_click)
        local t = wibox.widget {
            markup = string.format('<span foreground="%s">%s</span> %s',
                color, glyph, gears.string.xml_escape(label)),
            font = FONT,
            align = "center",
            valign = "center",
            widget = wibox.widget.textbox,
        }
        local bg = wibox.widget {
            { t, top = dpi(6), bottom = dpi(6), widget = wibox.container.margin },
            forced_width = dpi(150),
            shape = function(cr, w, h) gshape.rounded_rect(cr, w, h, dpi(3)) end,
            shape_border_width = dpi(1),
            shape_border_color = color .. "55",
            widget = wibox.container.background,
        }
        bg:connect_signal("mouse::enter", function() bg.bg = COLOR_HOVER end)
        bg:connect_signal("mouse::leave", function() bg.bg = nil end)
        bg:buttons(gears.table.join(awful.button({}, 1, guarded(on_click))))
        return bg
    end

    local confirm_bar = wibox.widget {
        {
            {
                {
                    bar_button("✔", "apply", COLOR_GREEN, function()
                        snapshot = nil
                        hide()
                    end),
                    bar_button("✘", "cancel", COLOR_RED, function()
                        restore_snapshot()
                        hide()
                    end),
                    spacing = dpi(10),
                    layout = wibox.layout.fixed.horizontal,
                },
                halign = "center",
                widget = wibox.container.place,
            },
            top = dpi(4), bottom = dpi(6),
            widget = wibox.container.margin,
        },
        forced_width = CONTENT_W,
        widget = wibox.container.background,
    }

    return wibox.widget {
        header,
        sample_row,
        preview_strip,
        separator(),
        {
            preset_col,
            vsep,
            controls_col,
            layout = wibox.layout.fixed.horizontal,
        },
        separator(),
        modes_row,
        separator(),
        confirm_bar,
        layout = wibox.layout.fixed.vertical,
    }
end


-- // MARK -- REFRESH

function refresh_popup()
    if not popup or not popup.visible then return end
    local running = animation.is_running and animation.is_running()
    run_label.markup = string.format('<span foreground="%s">%s</span>',
        running and COLOR_GREEN or COLOR_GREY,
        running and "Running" or "Stopped")

    paint_mode_cells()

    -- push engine state into the sliders (sync suppresses their write-back)
    if sync_speed then sync_speed(animation.get_speed_multiplier() or 1.0) end
    if sync_colspd then sync_colspd(animation.get_color_speed and animation.get_color_speed() or 0) end
    if sync_shnspd then sync_shnspd(animation.get_shine_speed and animation.get_shine_speed() or 0) end

    -- anim-chars limit: nil means every character animates
    if animchars_val then
        local mac = animation.get_max_animated_chars and animation.get_max_animated_chars()
        animchars_val.text = mac and tostring(mac) or "all"
    end
    if strategy_val then
        strategy_val.text = animation.get_char_selection_strategy
            and animation.get_char_selection_strategy() or "wave"
    end

    -- prog row state buttons: "off" when the disable flag (or a zeroed
    -- speed) is in effect, otherwise "on"
    if colour_state_val then
        local on = not (animation.get_disable_color and animation.get_disable_color())
        colour_state_val.markup = string.format('<span foreground="%s">%s</span>',
            on and COLOR_GREEN or COLOR_GREY, on and "on" or "off")
    end
    if shine_state_val then
        local on = not (animation.get_disable_shine and animation.get_disable_shine())
        shine_state_val.markup = string.format('<span foreground="%s">%s</span>',
            on and COLOR_GREEN or COLOR_GREY, on and "on" or "off")
    end
    if border_fx_val then border_fx_val.text = border_fx and "on" or "off" end

    paint_preview()
    paint_preset_cells()
    paint_sample()
    paint_swatch()

    -- timing: effective fps + the timer interval that actually drives it
    local sb = animation.get_speed_breakdown and animation.get_speed_breakdown() or nil
    if sb then
        local fps = sb.fps or 0
        local ms = sb.actual_timer_ms or sb.base_interval_ms or 0
        if sb.is_active == false then
            fps_val.text = string.format("inactive  ·  timer %dms", math.floor(ms + 0.5))
        else
            fps_val.text = string.format("%.1f fps  ·  timer %dms", fps, math.floor(ms + 0.5))
        end
    else
        fps_val.text = " "
    end
end


-- // MARK -- POPUP LIFECYCLE

local function ensure_popup()
    if popup then return end
    local style = popup_common.popup_style()
    -- build content first so the awful.popup constructor gets its required
    -- widget arg; draggable_header reads popup via popup_holder, assigned
    -- right after construction
    local content = build_content()
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
    if not popup or not popup.visible then return end
    if preview_timer then preview_timer:stop() end
    if border_fx_timer then border_fx_timer:stop() end
    -- leave the border on the static colour rather than a mid-sweep frame
    popup.border_color = COLOR_GOLD
    popup_common.hide(popup)
end

local function show(anchor)
    ensure_popup()
    if popup.visible then return end
    ctrl.set_anchor(anchor)
    awesome.emit_signal("popup::opening")
    take_snapshot()
    ensure_preview_timer()
    preview_timer:start()
    if border_fx then
        ensure_border_fx_timer()
        border_fx_timer:start()
    end
    popup_common.show_placement(popup, anchor, ctrl.show_opts())
    -- refresh_popup guards on popup.visible, which show_placement has only
    -- just set; refresh after it so values don't open as "--" placeholders
    refresh_popup()
end

local function toggle(anchor)
    ensure_popup()
    ctrl.toggle(anchor, show)
end


-- // MARK -- ATTACH

-- Wire left-click toggle (and right-click dismiss) on a shimmer widget. Safe
-- to call once per screen; all widgets share the single popup.
function M.attach(widget)
    ensure_popup()
    popup_common.attach(popup, widget, toggle, { right_hide = hide })
end

-- close this popup when any other popup opens
popup_common.register_closer(hide)

return M
