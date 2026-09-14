-- rc/font_utils.lua
-- Single source for Pango font strings scaled by the persistent UI scale
-- factor (rc/ui_scale). theme.lua and the popup/widget modules share these
-- so font sizes track ui_scale changes instead of being hardcoded.

local ui_scale = require("rc.ui_scale")

local M = {}

local scale = ui_scale.get_scale()

-- scale the numeric size in a Pango font string like "Hack Nerd Font Mono 9".
-- if the string has no trailing size the original is returned unchanged.
function M.scale_font(font_str, s)
    s = s or scale
    local name, size = font_str:match("^(.-)%s+(%d+)$")
    if name and size then
        return string.format("%s %d", name, math.floor(tonumber(size) * s))
    end
    return font_str
end

-- re-read the scale factor; call after ui_scale.set_scale before a restart so
-- freshly required modules pick up the new value
function M.refresh_scale()
    scale = ui_scale.get_scale()
end

function M.get_scale()
    return scale
end

-- build a "Hack Nerd Font Mono <size>" string at the native (unscaled) size.
-- used by widgets that vary the glyph size at the call site (e.g. system_widgets)
function M.mono_size(size)
    return string.format("Hack Nerd Font Mono %d", math.floor(size or 12))
end

-- standard font strings at their native (unscaled) sizes. the original
-- widget code hardcoded these without ui_scale; theme.font is the only
-- string that goes through scale_font. keeping these unscaled preserves
-- the rendered sizes one sees at any ui_scale setting.
M.FONT          = "Hack Nerd Font 10"
M.FONT_BOLD     = "Hack Nerd Font Bold 11"
M.FONT_HEAD     = "Hack Nerd Font Bold 11"
M.FONT_MONO     = "Hack Nerd Font Mono 10"
M.FONT_MONO_SM  = "Hack Nerd Font Mono 9"
M.FONT_SMALL    = "Hack Nerd Font 8"
M.FONT_INFO     = "Hack Nerd Font 9"
M.FONT_VALUE    = "Hack Nerd Font Bold 12"
M.FONT_HUGE     = "Hack Nerd Font Bold 22"
M.FONT_TINY     = "Hack Nerd Font 6"
M.FONT_CLEAR    = "Hack Nerd Font 11"
M.FONT_MENU     = "Hack Nerd Font Mono 13"
M.FONT_STAR     = "Hack Nerd Font 12"

return M
