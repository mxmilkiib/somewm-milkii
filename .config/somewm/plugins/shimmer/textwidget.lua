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
local wclay = require("wibox.clay")
local gtable = require("gears.table")
local gdebug = require("gears.debug")
local beautiful = require("beautiful")
local lgi = require("lgi")
local lgi_core = require("lgi.core")
local Pango = lgi.Pango
local PangoCairo = lgi.PangoCairo

local shimmertext = { mt = {} }

-- shimmer fast path: set layout text only when it changed, then turn the
-- span colours straight into the attribute runs the text element declares
-- ({start, end, kind, r, g, b, a} flat tuples, kind 0 = foreground; a
-- translucent span adds a foreground-alpha run). sig covers colours and run
-- boundaries, so identical frames skip the rebuild entirely.
function shimmertext:set_shimmer_frame(text, spans, sig)
    local p = self._private
    if p.shimmer_sig == sig and p.layout.text == text then return end
    p.shimmer_sig = sig
    p.markup = nil
    if p.layout.text ~= text then
        p.layout.text = text
        self:emit_signal("widget::layout_changed")
    end
    local runs, pos = {}, 0
    for i = 1, #spans, 2 do
        local t, color = spans[i], spans[i + 1]
        local next_pos = pos + #t
        if color then
            local c = wclay.solid_rgba(color)
            if c then
                local n = #runs
                runs[n + 1], runs[n + 2], runs[n + 3] = pos, next_pos, 0
                runs[n + 4], runs[n + 5], runs[n + 6], runs[n + 7] =
                    c[1], c[2], c[3], c[4]
                if c[4] < 1 then
                    runs[n + 8], runs[n + 9], runs[n + 10] = pos, next_pos, 1
                    runs[n + 11], runs[n + 12], runs[n + 13], runs[n + 14] =
                        c[4], 0, 0, 0
                end
            end
        end
        pos = next_pos
    end
    p.shimmer_attrs = #runs > 0 and runs or nil
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
    self._private.shimmer_attrs = nil
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
    self._private.shimmer_attrs = nil
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

-- a Pango colour attribute, straight alpha 0-1
local function attr_rgba(attr)
    local c = lgi_core.record.cast(attr, Pango.AttrColor).color
    return { c.red / 65535, c.green / 65535, c.blue / 65535, 1 }
end

local draw_attrs = { "FOREGROUND", "FOREGROUND_ALPHA", "BACKGROUND",
    "BACKGROUND_ALPHA", "UNDERLINE", "STRIKETHROUGH" }

-- the layout's attribute list as text-element run records, for the markup
-- path; shimmer frames carry their own
local function layout_attrs(layout, text)
    local attrs = layout.attributes
    if not attrs then return nil end
    local it = attrs:get_iterator()
    local start, finish = it:range()
    if start == 0 and finish >= #text and #it:get_attrs() == 0 then
        return nil
    end
    local runs = {}
    repeat
        local start, finish = it:range()
        if start < #text then
            for kind, name in ipairs(draw_attrs) do
                local attr = it:get(Pango.AttrType[name])
                if attr then
                    local value
                    if name == "FOREGROUND" or name == "BACKGROUND" then
                        value = attr_rgba(attr)
                    else
                        local v = lgi_core.record.cast(attr, Pango.AttrInt).value
                        if name == "FOREGROUND_ALPHA" or name == "BACKGROUND_ALPHA" then
                            v = v / 65535
                        end
                        value = { v, 0, 0, 0 }
                    end
                    runs[#runs + 1] = start
                    runs[#runs + 1] = math.min(finish, #text)
                    runs[#runs + 1] = kind - 1
                    for i = 1, 4 do runs[#runs + 1] = value[i] end
                end
            end
        end
    until not it:next()
    return #runs > 0 and runs or nil
end

-- interned font ids keyed by desc+dpi, as wibox.widget.textbox keeps them
local font_cache = setmetatable({}, { __mode = "v" })
local function font_id(w, layout, dpi)
    local desc = layout:get_font_description() or Pango.FontDescription.new()
    local key = tostring(dpi) .. ":" .. desc:to_string()
    if font_cache[key] then return font_cache[key] end
    local size = desc:get_size() / Pango.SCALE
    if size <= 0 then
        return wclay.refuse(w, "font", "has no size and the text is not drawn")
    end
    if not desc:get_size_is_absolute() then size = size * dpi / 72 end
    desc = desc:copy()
    desc:set_absolute_size(size * Pango.SCALE)
    local id = awesome._clay_font(desc:to_string())
    if not id then return wclay.refuse(w, "font", "could not be interned") end
    font_cache[key] = id
    return id
end

local function describe(w, fg, st)
    local p = w._private
    local layout = p.layout
    local text = layout.text or ""
    if text == "" then return {} end
    local font = font_id(w, layout, st.context.dpi)
    if not font then return nil end
    local ellipsize = layout:get_ellipsize()
    if ellipsize ~= "NONE" and ellipsize ~= "END" then
        wclay.ignore(w, "ellipsize", "start and middle ellipsize at the end")
        ellipsize = "END"
    end
    local c = wclay.solid_rgba(fg)
    if not c then
        wclay.ignore(w, "fg", "is not solid and the text is transparent")
        c = { 0, 0, 0, 0 }
    end
    local halign = ({ LEFT = "left", CENTER = "center", RIGHT = "right" })
        [layout:get_alignment()] or "left"
    return { align = { x = halign, y = p.valign or "center" },
        specs = { { text = text, font = font, name = "text",
            color = { c[1], c[2], c[3], c[4] },
            attrs = p.shimmer_attrs or layout_attrs(layout, text),
            wrap = layout:get_wrap() == "NONE" and "none" or "words",
            halign = halign, ellipsize = ellipsize == "END" } } }
end

local function new(text)
    local ret = base.make_widget(nil, nil, {enable_properties = true})

    gtable.crush(ret, shimmertext, true)

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

shimmertext._clay = { describe = describe }

return setmetatable(shimmertext, shimmertext.mt)
