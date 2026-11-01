-- plugins/style.lua
-- Shared visual constants for the widget/popup family: spacing scale,
-- colours, fonts, popup metrics. Modules require this instead of redefining
-- values per-file, so widgets track the theme and stay consistent.
--
-- Every value resolves theme (beautiful) keys first — standard upstream
-- names (fg_normal, bg_focus, border_focus, menu_font, ...) before this
-- config's custom milktheme keys (main_gold, main_purple) — with a literal
-- fallback last, so a module depending only on this file still renders
-- sanely under an arbitrary theme.
--
-- rc.font_utils supplies the font list when present (it applies the ui_scale
-- factor); without it, fonts fall back to beautiful.font / generic families.
--
-- Central overrides: style.configure{ spacing = { m = dpi(8) }, ... } merges
-- into the tables below before modules are built.

local beautiful = require("beautiful")

local M = {}

-- dpi helper: the theme's scaling when present, else identity
local xr = beautiful.xresources
M.dpi = (xr and xr.apply_dpi) or function(v) return v end
local dpi = M.dpi

-- resolve the first defined theme value from a list of keys. a colour
-- group table (milktheme's main_gold/main_purple style) yields .base
local function theme_value(keys, fallback)
    for _, k in ipairs(keys) do
        local v = beautiful[k]
        if type(v) == "table" then v = v.base end
        if v ~= nil then return v end
    end
    return fallback
end


-- MARK: COLOURS

M.color = {
    accent  = theme_value({ "main_gold", "border_focus", "fg_focus" }, "#FFD700"),
    accent2 = theme_value({ "main_purple", "bg_focus" }, "#623997"),
    fg      = theme_value({ "fg_normal" }, "#ffffff"),
    fg_dim  = theme_value({ "fg_minimize" }, "#aaaaaa"),
    bg      = theme_value({ "bg_normal" }, "#000000"),
    ok      = theme_value({ "ok_color" }, "#69D665"),
    err     = theme_value({ "error_color" }, "#FF6B6B"),
    hover   = theme_value({ "hover_color" }, "#ffffff33"),
}


-- MARK: SPACING

-- spacing scale: name by role, not pixel count, so a theme-wide rescale is
-- one edit. values are dpi-scaled
M.spacing = {
    none = 0,
    hair = dpi(1),    -- separators, 1px lines
    xxs  = dpi(2),    -- hairline insets
    xs   = dpi(3),    -- small insets
    s    = dpi(4),    -- tight row spacing / vertical padding
    m    = dpi(6),    -- default widget spacing
    l    = dpi(8),    -- section spacing
    xl   = dpi(10),   -- side margins
    xxl  = dpi(12),   -- large margins / section gaps
    huge = dpi(20),   -- block gaps
}


-- MARK: FONTS

-- prefer rc.font_utils (ui_scale-aware); fall back to theme.font/generic
local ok_fu, font_utils = pcall(require, "rc.font_utils")
local function font(key, fallback)
    if ok_fu and font_utils[key] then return font_utils[key] end
    return fallback or beautiful.font or "sans 10"
end

M.font = {
    normal  = font("FONT", beautiful.font),
    bold    = font("FONT_BOLD"),
    head    = font("FONT_HEAD"),
    mono    = font("FONT_MONO", "monospace 10"),
    mono_sm = font("FONT_MONO_SM", "monospace 9"),
    small   = font("FONT_SMALL", "sans 8"),
    info    = font("FONT_INFO", "sans 9"),
    value   = font("FONT_VALUE"),
    huge    = font("FONT_HUGE", "sans 22"),
    tiny    = font("FONT_TINY", "sans 6"),
    clear   = font("FONT_CLEAR"),
    menu    = font("FONT_MENU", beautiful.menu_font),
    star    = font("FONT_STAR"),
}

-- build "<mono family> <size>" from the configured mono font's family name;
-- widgets that vary glyph size at the call site use this instead of
-- hardcoding a family (e.g. font_utils.mono_size)
function M.font_size(size, base)
    base = base or M.font.mono
    local name = base:match("^(.-)%s+%d+$") or base
    return string.format("%s %d", name, math.floor(size or 12))
end


-- MARK: POPUP METRICS

M.popup = {
    border_width = theme_value({ "bar_edge_width", "border_width" }, dpi(1)),
    border_color = theme_value({ "menu_border_color" }, M.color.accent2),
    radius       = theme_value({ "border_radius" }, dpi(3)),
    margin_x     = M.spacing.xl,
    margin_y     = M.spacing.m,
    spacing      = M.spacing.m,
    header_bg    = M.color.accent2,
    content_w    = dpi(240),   -- default content width; modules may override
}


-- MARK: MISC

M.size = {
    icon      = theme_value({ "icon_size" }, dpi(16)),
    separator = M.spacing.hair,
}


-- MARK: CONFIGURE

-- merge user opts into a module's CFG table (shallow). modules expose this
-- as M.configure(opts) = function M.configure(o) style.merge(CFG, o) end
function M.merge(dst, opts)
    for k, v in pairs(opts or {}) do dst[k] = v end
    return dst
end

-- merge user overrides into the top-level tables; opts keys name a section
-- (color/spacing/font/popup/size) whose entries are shallow-merged
function M.configure(opts)
    for section, values in pairs(opts or {}) do
        local target = M[section]
        if type(target) == "table" and type(values) == "table" then
            for k, v in pairs(values) do target[k] = v end
        end
    end
end


return M
