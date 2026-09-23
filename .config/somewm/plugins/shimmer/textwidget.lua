-- plugins/shimmer/textwidget.lua
-- Direct-render text widget for shimmer animations
--
-- A drop-in wibox.widget.textbox replacement that accepts per-frame colour
-- updates as a span list instead of Pango markup. The layout text is set once
-- (Pango shaping is reused) and each animation frame only rebuilds the
-- foreground-colour attribute list, so no XML markup is parsed per frame.
--
-- Span list format (from animation.get_letter_shimmer_spans):
--   flat array {text_run, color_hex_or_false, text_run, color, ...}
--   byte offsets are accumulated over the raw (unescaped) text runs

local base = require("wibox.widget.base")
local gtable = require("gears.table")
local gdebug = require("gears.debug")
local beautiful = require("beautiful")
local lgi = require("lgi")
local Pango = lgi.Pango
local PangoCairo = lgi.PangoCairo

local shimmertext = { mt = {} }

local string_format = string.format
local table_concat = table.concat

-- scratch buffer for attribute-list spec strings; reused across frames
local attr_parts = {}

local function setup_dpi(box, dpi)
    if box._private.dpi ~= dpi then
        box._private.dpi = dpi
        box._private.ctx:set_resolution(dpi)
        box._private.layout:context_changed()
    end
end

local function setup_layout(box, width, height, dpi)
    box._private.layout.width = Pango.units_from_double(width)
    box._private.layout.height = Pango.units_from_double(height)
    setup_dpi(box, dpi)
end

function shimmertext:draw(context, cr, width, height)
    setup_layout(self, width, height, context.dpi)
    cr:update_layout(self._private.layout)
    local _, logical = self._private.layout:get_pixel_extents()
    local offset = 0
    if self._private.valign == "center" then
        offset = (height - logical.height) / 2
    elseif self._private.valign == "bottom" then
        offset = height - logical.height
    end
    cr:move_to(0, offset)
    cr:show_layout(self._private.layout)
end

local function do_fit_return(self)
    local _, logical = self._private.layout:get_pixel_extents()
    if logical.width == 0 or logical.height == 0 then
        return 0, 0
    end
    return logical.width, logical.height
end

function shimmertext:fit(context, width, height)
    setup_layout(self, width, height, context.dpi)
    return do_fit_return(self)
end

-- shimmer fast path: set layout text only when it changed, then rebuild the
-- foreground-colour attribute list from the span data. the whole attr list is
-- parsed in a single C call ("start end foreground #rgb, ..."), which is far
-- cheaper than one attr_foreground_new FFI call per span. sig covers colours
-- and run boundaries, so identical frames skip the rebuild entirely.
function shimmertext:set_shimmer_frame(text, spans, sig)
    local p = self._private
    if p.shimmer_sig == sig and p.layout.text == text then return end
    p.shimmer_sig = sig
    p.markup = nil
    if p.layout.text ~= text then
        p.layout.text = text
        self:emit_signal("widget::layout_changed")
    end
    local k = 0
    local pos = 0
    for i = 1, #spans, 2 do
        local t, color = spans[i], spans[i + 1]
        local next_pos = pos + #t
        if color then
            k = k + 1
            attr_parts[k] = string_format("%d %d foreground %s", pos, next_pos, color)
        end
        pos = next_pos
    end
    if k == 0 then
        p.layout.attributes = nil
    else
        p.layout.attributes = Pango.attr_list_from_string(table_concat(attr_parts, ",", 1, k))
    end
    for i = 1, k do attr_parts[i] = nil end
    self:emit_signal("widget::redraw_needed")
end

-- any non-shimmer write invalidates the span signature so the next shimmer
-- frame is applied rather than deduplicated against stale state
function shimmertext:set_markup_silently(text)
    if self._private.markup == text then
        return true
    end

    local attr, parsed = Pango.parse_markup(text, -1, 0)
    if not attr then
        return false, parsed.message or tostring(parsed)
    end

    self._private.shimmer_sig = nil
    self._private.markup = text
    self._private.layout.text = parsed
    self._private.layout.attributes = attr
    self:emit_signal("widget::redraw_needed")
    self:emit_signal("widget::layout_changed")
    self:emit_signal("property::markup", text)
    return true
end

function shimmertext:set_markup(text)
    local success, message = self:set_markup_silently(text)
    if not success then
        gdebug.print_error(debug.traceback("Error parsing markup: "..message.."\nFailed with string: '"..text.."'"))
    end
end

function shimmertext:get_markup()
    return self._private.markup
end

function shimmertext:set_text(text)
    if self._private.layout.text == text and self._private.layout.attributes == nil then
        return
    end
    self._private.shimmer_sig = nil
    self._private.markup = nil
    self._private.layout.text = text
    self._private.layout.attributes = nil
    self:emit_signal("widget::redraw_needed")
    self:emit_signal("widget::layout_changed")
    self:emit_signal("property::text", text)
end

function shimmertext:get_text()
    return self._private.layout.text
end

function shimmertext:set_ellipsize(mode)
    local allowed = { none = "NONE", start = "START", middle = "MIDDLE", ["end"] = "END" }
    if allowed[mode] then
        if self._private.layout:get_ellipsize() == allowed[mode] then
            return
        end
        self._private.layout:set_ellipsize(allowed[mode])
        self:emit_signal("widget::redraw_needed")
        self:emit_signal("widget::layout_changed")
        self:emit_signal("property::ellipsize", mode)
    end
end

function shimmertext:set_wrap(mode)
    local allowed = { word = "WORD", char = "CHAR", word_char = "WORD_CHAR" }
    if allowed[mode] then
        if self._private.layout:get_wrap() == allowed[mode] then
            return
        end
        self._private.layout:set_wrap(allowed[mode])
        self:emit_signal("widget::redraw_needed")
        self:emit_signal("widget::layout_changed")
        self:emit_signal("property::wrap", mode)
    end
end

function shimmertext:set_valign(mode)
    local allowed = { top = true, center = true, bottom = true }
    if allowed[mode] then
        if self._private.valign == mode then
            return
        end
        self._private.valign = mode
        self:emit_signal("widget::redraw_needed")
        self:emit_signal("widget::layout_changed")
        self:emit_signal("property::valign", mode)
    end
end

function shimmertext:set_halign(mode)
    local allowed = { left = "LEFT", center = "CENTER", right = "RIGHT" }
    if allowed[mode] then
        if self._private.layout:get_alignment() == allowed[mode] then
            return
        end
        self._private.layout:set_alignment(allowed[mode])
        self:emit_signal("widget::redraw_needed")
        self:emit_signal("widget::layout_changed")
        self:emit_signal("property::halign", mode)
    end
end

function shimmertext:set_font(font)
    if font == self._private.font then return end

    self._private.font = font
    self._private.layout:set_font_description(beautiful.get_font(font))
    self:emit_signal("widget::redraw_needed")
    self:emit_signal("widget::layout_changed")
    self:emit_signal("property::font", font)
end

function shimmertext:get_font()
    return self._private.font
end

local function new(text)
    local ret = base.make_widget(nil, nil, {enable_properties = true})

    gtable.crush(ret, shimmertext, true)

    ret._private.dpi = -1
    ret._private.ctx = PangoCairo.font_map_get_default():create_context()
    ret._private.layout = Pango.Layout.new(ret._private.ctx)
    ret._private.layout:set_font_description(beautiful.get_font(beautiful.font))

    ret:set_ellipsize("end")
    ret:set_wrap("word_char")
    ret:set_valign("center")
    ret:set_halign("left")

    if text then
        ret:set_text(text)
    end

    return ret
end

function shimmertext.mt.__call(_, ...)
    return new(...)
end

return setmetatable(shimmertext, shimmertext.mt)
