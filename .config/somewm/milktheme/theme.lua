--------------------------------------------------
-- Default awesome theme, Milkii's custom theme --
--------------------------------------------------



-- // MARK: REQUIRES
-- core Beautiful and DPI helpers

-- ██████╗ ███████╗ ██████╗ ██╗   ██╗██╗██████╗ ███████╗███████╗
-- ██╔══██╗██╔════╝██╔═══██╗██║   ██║██║██╔══██╗██╔════╝██╔════╝
-- ██████╔╝█████╗  ██║   ██║██║   ██║██║██████╔╝█████╗  ███████╗
-- ██╔══██╗██╔══╝  ██║▄▄ ██║██║   ██║██║██╔══██╗██╔══╝  ╚════██║
-- ██║  ██║███████╗╚██████╔╝╚██████╔╝██║██║  ██║███████╗███████║
-- ╚═╝  ╚═╝╚══════╝ ╚══▀▀═╝  ╚═════╝ ╚═╝╚═╝  ╚═╝╚══════╝╚══════╝


local theme_assets = require("beautiful.theme_assets")
local xresources = require("beautiful.xresources")
local ui_scale = require("rc.ui_scale")
local font_utils = require("rc.font_utils")

-- UI scale factor: multiplies all dpi() values and font sizes
local scale = ui_scale.get_scale()

-- wrap dpi() to apply the scale factor
local _dpi = xresources.apply_dpi
local function dpi(size)
    return _dpi(size) * scale
end

-- scale the numeric size in a Pango font string like "Hack Nerd Font Mono 9".
-- delegated to rc.font_utils so theme and plugins share one scaler
local scale_font = font_utils.scale_font

local gfs = require("gears.filesystem")
local themes_path = gfs.get_themes_dir()


-- // MARK: TABLE & PATHS
local theme = {}

-- Base icon directories used by layout icon sections
local theme_dir = gfs.get_configuration_dir() .. "milktheme/"
theme.lain_icons         = "~/.config/awesome/lain/icons/layout/default/"
theme.bling_icons        = "~/.config/awesome/bling/icons/layouts/"
theme.layout_icons       = theme_dir .. "icons/layouts/"  -- renamed from extras_icons



-- // MARK: ICONS

-- set a concrete icon theme so xdg icon lookups succeed (used by desktop icons, menus, etc.)
-- choose from installed icon themes; Adwaita and hicolor are common
theme.icon_theme = "Adwaita"


-- // MARK: WALLPAPER

-- ██╗    ██╗ █████╗ ██╗     ██╗     ██████╗  █████╗ ██████╗ ███████╗██████╗ 
-- ██║    ██║██╔══██╗██║     ██║     ██╔══██╗██╔══██╗██╔══██╗██╔════╝██╔══██╗
-- ██║ █╗ ██║███████║██║     ██║     ██████╔╝███████║██████╔╝█████╗  ██████╔╝
-- ██║███╗██║██╔══██║██║     ██║     ██╔═══╝ ██╔══██║██╔═══╝ ██╔══╝  ██╔══██╗
-- ╚███╔███╔╝██║  ██║███████╗███████╗██║     ██║  ██║██║     ███████╗██║  ██║
--  ╚══╝╚══╝ ╚═╝  ╚═╝╚══════╝╚══════╝╚═╝     ╚═╝  ╚═╝╚═╝     ╚══════╝╚═╝  ╚═╝


-- old path pointed to the system themes dir; use local config theme if available
-- theme.wallpaper = themes_path.."milktheme/background.png"
local home = os.getenv("HOME")
local cfg_wall = home .. "/.wallpapers/danielle_at_sea_flickr_purple.png"
if gfs.file_readable(cfg_wall) then
    theme.wallpaper = cfg_wall
else
    -- fallback to default theme background to avoid errors
    theme.wallpaper = themes_path .. "default/background.png"
end

-- -- per-screen wallpapers
-- theme.wallpapers = {
--     "/path/to/screen1.png",
--     "/path/to/screen2.png",
--     "/path/to/screen3.png",
--   }


-- // MARK: FONTS
-- font config goes here

-- ███████╗ ██████╗ ███╗   ██╗████████╗███████╗
-- ██╔════╝██╔═══██╗████╗  ██║╚══██╔══╝██╔════╝
-- █████╗  ██║   ██║██╔██╗ ██║   ██║   ███████╗
-- ██╔══╝  ██║   ██║██║╚██╗██║   ██║   ╚════██║
-- ██║     ╚██████╔╝██║ ╚████║   ██║   ███████║
-- ╚═╝      ╚═════╝ ╚═╝  ╚═══╝   ╚═╝   ╚══════╝


theme.font          = scale_font("Hack Nerd Font Mono 9")
-- theme.font          = "Hack regular 9"
-- theme.font          = "Hack regular 12"

-- Menu font (kept with typography for consistency)
theme.menu_font   = scale_font("Hack Nerd Font Mono 13")

-- Tooltip font: larger than the wibar's 9pt base so hover hints read clearly.
-- awful.tooltip falls back to beautiful.font when this is unset; setting it
-- here bumps every tooltip that doesn't pass an explicit font= at the call site
theme.tooltip_font = scale_font("Hack Nerd Font Mono 11")

-- Hotkeys popup styling
-- theme.hotkeys_font = "Hack Nerd Font 12"
theme.hotkeys_font = theme.font
theme.hotkeys_modifiers_fg = "#dddddd"


--------------------------------------------------------

-- // MARK: HOTKEYS POPUP
-- compact, readable styling closer to default awesome look
-- old:
-- theme.hotkeys_font = theme.font
-- theme.hotkeys_modifiers_fg = "#dddddd"
-- new:
--  - keep font but add a proportional description font for better readability
--  - add subtle border and spacing between groups
--  - use focused bg for key label chips with contrasting text
theme.hotkeys_description_font = scale_font("Sans 9")
theme.hotkeys_bg = "#000000"
theme.hotkeys_fg = "#ffffff"
theme.hotkeys_border_width = dpi(1)
theme.hotkeys_border_color = "#6c6c6c"
theme.hotkeys_group_margin = dpi(8)
theme.hotkeys_label_bg = "#623997"
theme.hotkeys_label_fg = "#000000"  -- black foreground for section titles


---- active window
-- theme.bg_focus      = "#623997"

-- theme.menu_font   = "JetBrains Mono 12" 



-- // MARK: PALETTE
-- General-purpose root color for the theme (used across tags, tasks, icons, etc.)

-- ██████╗  █████╗ ██╗     ███████╗████████╗████████╗███████╗
-- ██╔══██╗██╔══██╗██║     ██╔════╝╚══██╔══╝╚══██╔══╝██╔════╝
-- ██████╔╝███████║██║     █████╗     ██║      ██║   █████╗  
-- ██╔═══╝ ██╔══██║██║     ██╔══╝     ██║      ██║   ██╔══╝  
-- ██║     ██║  ██║███████╗███████╗   ██║      ██║   ███████╗
-- ╚═╝     ╚═╝  ╚═╝╚══════╝╚══════╝   ╚═╝      ╚═╝   ╚══════╝


-- create color table with variations
theme.main_purple = {
    base = "#623997",
    focusstart = "#62399788",
    focusend = "#62399722",
    normalstart = "#62399788", 
    normalend = "#62399722"
}

theme.main_gold = {
    base = "#FFD700",
    focus = "#FFD700CC",
    muted = "#FFD70088",
}
theme.bar_edge_width = dpi(3)

-- Calendar cells are approximately one 32px bar-icon square each.
theme.calendar_style = {
    padding = dpi(7),
    border_width = dpi(1),
    border_color = theme.main_purple.base,
}
theme.calendar_focus_bg_color = theme.main_gold.base
theme.calendar_focus_fg_color = "#000000"

-- theme.main_orange   = "#976239"  -- complementary orange: same saturation/lightness as purple
theme.main_orange   = "#f97316"
-- border_color = beautiful.main_orange  -- for orange accents


-- Keep bg_focus as an alias for compatibility with Awesome/Beautiful expectations
theme.bg_focus       = theme.main_purple.base
theme.fg_focus       = "#fff"


---- general window
theme.bg_normal     = "#000000"
-- theme.bg_normal      = "#020202"
theme.fg_normal      = "#fff"


-- theme.bg_minimize   = "#000"
theme.bg_minimize    = "#000"
-- theme.fg_minimize   = "#9543b8"
theme.fg_minimize    = "#999"


-- theme.bg_urgent     = "#ecbc34"
theme.fg_urgent      = "#f00"


-- unified icon sizing (px)
theme.icon_size = 16



theme.taglist_bg_normal = "#000"
theme.taglist_fg_normal = "#ffffff"
theme.taglist_fg_focus = theme.main_gold.base
theme.taglist_fg_occupied = "#cccccc"
theme.taglist_hover_bg = theme.main_gold.muted
theme.taglist_hover_fg = "#000000"

-- systray icon size (override or inherit)
theme.systray_icon_size = theme.icon_size
theme.systray_icon_spacing = 4
theme.bg_systray     = theme.bg_normal



-- Collision focus colors
theme.collision_focus_bg_center = "#00ff00"
-- theme.collision_focus_bg = "#ffff00"


-- beautiful.hotkeys_modifiers_fg = "#ffffff"




-- // MARK: EDGES
-- spacing & borders

-- ███████╗██████╗  ██████╗ ███████╗███████╗
-- ██╔════╝██╔══██╗██╔════╝ ██╔════╝██╔════╝
-- █████╗  ██║  ██║██║  ███╗█████╗  ███████╗
-- ██╔══╝  ██║  ██║██║   ██║██╔══╝  ╚════██║
-- ███████╗██████╔╝╚██████╔╝███████╗███████║
-- ╚══════╝╚═════╝  ╚═════╝ ╚══════╝╚══════╝


theme.border_normal = "#535d6c"
-- theme.border_normal = "#ffffff"
theme.border_focus  = theme.main_gold.focus
theme.border_marked = "#91231c"

theme.border_width  = 1
-- theme.border_width  = dpi(1)
-- theme.border_width  = 2

theme.useless_gap   = 2
-- theme.useless_gap = dpi(1)
-- theme.useless_gap   = dpi(3)

-- theme.border_radius = 2
theme.border_radius = dpi(2)







-- // MARK: COLORS
-- There are other variable sets
-- overriding the default one when
-- defined, the sets are:
-- taglist_[bg|fg]_[focus|urgent|occupied|empty|volatile]
-- tasklist_[bg|fg]_[focus|urgent]
-- titlebar_[bg|fg]_[normal|focus]
-- tooltip_[font|opacity|fg_color|bg_color|border_width|border_color]
-- mouse_finder_[color|timeout|animate_timeout|radius|factor]
-- prompt_[fg|bg|fg_cursor|bg_cursor|font]
-- hotkeys_[bg|fg|border_width|border_color|shape|opacity|modifiers_fg|label_bg|label_fg|group_margin|font|description_font]

-- IMPORTANT: Set these to nil to let shimmer handle text coloring
-- This ensures the shimmer effect isn't overridden by theme settings




-- // MARK: TASKLIST
-- Align with official theme variables for focus colors
-- Previous overrides (moved from rc.lua for clarity):
-- theme.tasklist_bg_focus = "#663399" -- example if a distinct tasklist purple was desired
-- theme.tasklist_bg_focus = theme.main_purple
theme.tasklist_fg_focus = nil
theme.tasklist_fg_normal = nil

-- icon sizes
theme.tasklist_icon_size = 20

-- disable status symbols and underscores for minimized clients in tasklist
theme.tasklist_plain_task_name = true




-- // MARK: TAGLIST
-- Exported size for custom tag occupancy squares used in rc.lua
theme.tag_square_size = dpi(7)


-- Generate taglist squares:
local taglist_square_size = dpi(6.5)
theme.taglist_squares_sel = theme_assets.taglist_squares_sel(
    taglist_square_size, theme.fg_normal
)
theme.taglist_squares_unsel = theme_assets.taglist_squares_unsel(
    taglist_square_size, theme.fg_normal
)

-- theme.taglist_bg_focus = "#663399" -- prior hardcoded purple in rc.lua
-- theme.taglist_bg_focus = theme.main_purple





-- // MARK: TITLEBAR


-- compact titlebar height (roughly 1/4 of typical defaults): icon size + minimal padding
theme.titlebar_height = theme.icon_size

theme.titlebar_bg_normal = theme.main_purple.base


-- theme.titlebar_fg_focus = "#ffd700"
-- theme.titlebar_fg_normal = "#fff"

-- Create a purple-to-transparent gradient for focused titlebar (horizontal left to right)
-- try right-to-left gradient (buttons area to title area)
-- theme.titlebar_bg_focus = "linear:1,0:0,0:0,#66339900:0.3,#66339950:1.0,#663399ff"
-- theme.titlebar_bg_focus = "linear:1,0:0,0:0,#66339900:1.0,#663399ff"

-- Match the rc.lua gradient for consistency: solid purple start, then fade to transparent
-- This ensures uniform titlebar appearance across all clients

-- color variations now defined in main_purple table above

theme.titlebar_bg_focus = {
    type = "linear",
    from = { 0, 0 },
    to = { 700, 0 },  -- fallback width
    stops = {
        { 0, theme.main_purple.base },    -- purple, full opacity
        { 0.5, theme.main_purple.base }, -- purple, full opacity
        { 1, theme.main_purple.focusend },    -- purple, transparent
    }
}

theme.titlebar_bg_normal = {
    type = "linear",
    from = { 0, 0 },
    to = { 700, 0 },  -- fallback width
    stops = {
        { 0, theme.main_purple.normalstart },    -- purple, reduced opacity
        { 0.5, theme.main_purple.normalstart }, -- purple, reduced opacity
        { 1, theme.main_purple.normalend },    -- purple, transparent
    }
}




-- // MARK: NOTIFICATIONS

-- Variables set for theming notifications:
-- notification_font
-- notification_[bg|fg]
-- notification_[width|height|margin]
-- notification_[border_color|border_width|shape|opacity]

-- System tray and notification colors
theme.notification_bg = theme.main_gold.base    -- gold background
theme.notification_fg = "#000000"    -- black text
theme.notification_icon_size = 64
theme.notification_font = scale_font("Hack Nerd Font Mono 12")




-- // MARK: MENU
-- Variables set for theming the menu:

-- ███╗   ███╗███████╗███╗   ██╗██╗   ██╗
-- ████╗ ████║██╔════╝████╗  ██║██║   ██║
-- ██╔████╔██║█████╗  ██╔██╗ ██║██║   ██║
-- ██║╚██╔╝██║██╔══╝  ██║╚██╗██║██║   ██║
-- ██║ ╚═╝ ██║███████╗██║ ╚████║╚██████╔╝
-- ╚═╝     ╚═╝╚══════╝╚═╝  ╚═══╝ ╚═════╝ 


-- Font overrides


-- Menu dimensions

-- Keep theme as the single source of truth
-- theme.menu_height = 24
-- old: dpi(20) — cramped rows, hard click targets
theme.menu_height = dpi(32)
-- theme.menu_width = 300
theme.menu_width  = dpi(340)
theme.menu_border_width = theme.bar_edge_width
theme.menu_border_color = theme.main_purple.base


-- menu_[bg|fg]_[normal|focus]
-- menu_[border_color|border_width]
theme.menu_submenu_icon = themes_path.."default/submenu.png"




-- // MARK: ICONS
-- Define the image to load for bar layout widget

-- ██╗ ██████╗ ██████╗ ███╗   ██╗███████╗
-- ██║██╔════╝██╔═══██╗████╗  ██║██╔════╝
-- ██║██║     ██║   ██║██╔██╗ ██║███████╗
-- ██║██║     ██║   ██║██║╚██╗██║╚════██║
-- ██║╚██████╗╚██████╔╝██║ ╚████║███████║
-- ╚═╝ ╚═════╝ ╚═════╝ ╚═╝  ╚═══╝╚══════╝


theme.awesome_icon = theme_dir .. "icons/somewm-logo.svg"


-- Define the icon theme for application icons. If not set then the icons
-- from /usr/share/icons and /usr/share/icons/hicolor will be used.
theme.icon_theme = "Adwaita"



-- layout icon system, svg vs png
-- // MARK: png
theme.titlebar_close_button_normal = themes_path.."default/titlebar/close_normal.png"
theme.titlebar_close_button_focus  = themes_path.."default/titlebar/close_focus.png"

theme.titlebar_minimize_button_normal = themes_path.."default/titlebar/minimize_normal.png"
theme.titlebar_minimize_button_focus  = themes_path.."default/titlebar/minimize_focus.png"

theme.titlebar_ontop_button_normal_inactive = themes_path.."default/titlebar/ontop_normal_inactive.png"
theme.titlebar_ontop_button_focus_inactive  = themes_path.."default/titlebar/ontop_focus_inactive.png"
theme.titlebar_ontop_button_normal_active = themes_path.."default/titlebar/ontop_normal_active.png"
theme.titlebar_ontop_button_focus_active  = themes_path.."default/titlebar/ontop_focus_active.png"

theme.titlebar_sticky_button_normal_inactive = themes_path.."default/titlebar/sticky_normal_inactive.png"
theme.titlebar_sticky_button_focus_inactive  = themes_path.."default/titlebar/sticky_focus_inactive.png"
theme.titlebar_sticky_button_normal_active = themes_path.."default/titlebar/sticky_normal_active.png"
theme.titlebar_sticky_button_focus_active  = themes_path.."default/titlebar/sticky_focus_active.png"

theme.titlebar_floating_button_normal_inactive = themes_path.."default/titlebar/floating_normal_inactive.png"
theme.titlebar_floating_button_focus_inactive  = themes_path.."default/titlebar/floating_focus_inactive.png"
theme.titlebar_floating_button_normal_active = themes_path.."default/titlebar/floating_normal_active.png"
theme.titlebar_floating_button_focus_active  = themes_path.."default/titlebar/floating_focus_active.png"

theme.titlebar_maximized_button_normal_inactive = themes_path.."default/titlebar/maximized_normal_inactive.png"
theme.titlebar_maximized_button_focus_inactive  = themes_path.."default/titlebar/maximized_focus_inactive.png"
theme.titlebar_maximized_button_normal_active = themes_path.."default/titlebar/maximized_normal_active.png"
theme.titlebar_maximized_button_focus_active  = themes_path.."default/titlebar/maximized_focus_active.png"



theme.layout_icon_config = {
    -- Colors
    purple_margin_bg = theme.main_purple.base,    -- Purple margin/background
    window_fill = "#CCCCCC",         -- Light grey fills
    window_border = "#AAAAAA",       -- Light grey borders and separators
    background = "#222222",          -- Black background
    
    -- Dimensions
    icon_size = 64,                  -- Icon dimensions
    border_width = 1,                -- Purple margin width
    corner_radius = 1,               -- Rounded corner radius
    separator_width = 1,             -- Separator width between windows
    min_purple_margin = 2,           -- Minimum purple space around representations
    
    -- File naming
    current_suffix = "_alt",         -- Current active icon suffix
    archive_suffix = "_alt_v2",      -- Archive suffix for previous versions
}



-- // MARK: svg

-- All layout icons use unified SVG format (purple margin, black bg, grey windows)
local function li(name) return theme.layout_icons .. name .. theme.layout_icon_config.current_suffix .. ".svg" end

-- Custom layouts
theme.layout_threefifths = li("threefifths")       -- lain.layout.threefifths
theme.layout_centerwork_adaptiveh = li("centerwork_adaptiveh")
theme.layout_centerwork_twothirdsh = li("centerwork_twothirdsh")
theme.layout_vstack = li("vstack")                 -- vstack layout
theme.layout_bsp = li("bsp")                       -- layouts.bsp
theme.layout_tabbed = li("tabbed")                 -- layouts.tabbed
theme.layout_grid = li("grid")                     -- layouts.grid
theme.layout_threecol = li("threecol")             -- layouts.threecol
theme.layout_scroller = li("scroller")             -- layouts.scroller
theme.layout_quarter = li("quarter")               -- layouts.quarter
theme.layout_tatami = li("tatami")                 -- layouts.tatami
theme.layout_slice = li("slice")                   -- layouts.slice

-- Exotic layouts
theme.layout_msv = li("msv")                       -- layouts.msv
theme.layout_fibh = li("fibh")                     -- layouts.fibh
theme.layout_panes = li("panes")                   -- layouts.panes
theme.layout_widetile = li("widetile")             -- layouts.widetile
theme.layout_expose = li("expose")                 -- layouts.expose

-- Lain layouts
theme.layout_centerworkh = li("centerworkh")       -- lain.layout.centerwork.horizontal
theme.layout_centerwork = li("centerwork")         -- lain.layout.centerwork (vertical)
theme.layout_centerfair = li("centerfair")         -- lain.layout.termfair.center
theme.layout_termfair = li("termfair")             -- lain.layout.termfair
theme.layout_cascade = li("cascade")               -- lain.layout.cascade
theme.layout_cascadetile = li("cascadetile")       -- lain.layout.cascade.tile

-- Bling layouts
theme.layout_centered = li("centered")             -- bling.layout.centered
theme.layout_deck = li("deck")                     -- bling.layout.deck
theme.layout_equalarea = li("equalarea")           -- bling.layout.equalarea
theme.layout_mstab = li("mstab")                   -- bling.layout.mstab
theme.layout_horizontal = li("horizontal")         -- bling.layout.horizontal
theme.layout_vertical = li("vertical")             -- bling.layout.vertical

-- Awful layouts
theme.layout_tile = li("tile")                     -- awful.layout.suit.tile
theme.layout_tiletop = li("tiletop")               -- awful.layout.suit.tile.top
theme.layout_tilebottom = li("tilebottom")         -- awful.layout.suit.tile.bottom
theme.layout_tileleft = li("tileleft")             -- awful.layout.suit.tile.left
theme.layout_magnifier = li("magnifier")           -- awful.layout.suit.magnifier
theme.layout_max = li("max")                       -- awful.layout.suit.max
theme.layout_fullscreen = li("fullscreen")         -- awful.layout.suit.max.fullscreen
theme.layout_floating = li("floating")             -- awful.layout.suit.floating
theme.layout_carousel = li("carousel")            -- awful.layout.suit.carousel
theme.layout_spiral = li("spiral")                 -- awful.layout.suit.spiral
theme.layout_dwindle = li("dwindle")               -- awful.layout.suit.spiral.dwindle
theme.layout_fairh = li("fairh")                   -- awful.layout.suit.fair.horizontal
theme.layout_fairv = li("fairv")                   -- awful.layout.suit.fair
theme.layout_cornernw = li("cornernw")             -- awful.layout.suit.corner.nw
theme.layout_cornerne = li("cornerne")             -- awful.layout.suit.corner.ne
theme.layout_cornersw = li("cornersw")             -- awful.layout.suit.corner.sw
theme.layout_cornerse = li("cornerse")             -- awful.layout.suit.corner.se

-- Other layouts
theme.layout_treetile = li("treetile")             -- treetile layout
theme.layout_thrizen = li("trizen")                -- thrizen layout

theme.layout_leavedright  = "~/.config/awesome/awesome-leaved/icons/leavedright.png"
theme.layout_leavedleft   = "~/.config/awesome/awesome-leaved/icons/leavedleft.png"
theme.layout_leavedbottom = "~/.config/awesome/awesome-leaved/icons/leavedbottom.png"
theme.layout_leavedtop    = "~/.config/awesome/awesome-leaved/icons/leavedtop.png"

-- // MARK: WINDOW SWALLOWING

-- ██╗    ██╗██╗███╗   ██╗██████╗  ██████╗ ██╗    ██╗    ███████╗██╗    ██╗ █████╗ ██╗     ██╗      ██████╗ ██╗    ██╗██╗███╗   ██╗ ██████╗ 
-- ██║    ██║██║████╗  ██║██╔══██╗██╔═══██╗██║    ██║    ██╔════╝██║    ██║██╔══██╗██║     ██║     ██╔═══██╗██║    ██║██║████╗  ██║██╔════╝ 
-- ██║ █╗ ██║██║██╔██╗ ██║██║  ██║██║   ██║██║ █╗ ██║    ███████╗██║ █╗ ██║███████║██║     ██║     ██║   ██║██║ █╗ ██║██║██╔██╗ ██║██║  ███╗
-- ██║███╗██║██║██║╚██╗██║██║  ██║██║   ██║██║███╗██║    ╚════██║██║███╗██║██╔══██║██║     ██║     ██║   ██║██║███╗██║██║██║╚██╗██║██║   ██║
-- ╚███╔███╔╝██║██║ ╚████║██████╔╝╚██████╔╝╚███╔███╔╝    ███████║╚███╔███╔╝██║  ██║███████╗███████╗╚██████╔╝╚███╔███╔╝██║██║ ╚████║╚██████╔╝
--  ╚══╝╚══╝ ╚═╝╚═╝  ╚═══╝╚═════╝  ╚═════╝  ╚══╝╚══╝     ╚══════╝ ╚══╝╚══╝ ╚═╝  ╚═╝╚══════╝╚══════╝ ╚═════╝  ╚══╝╚══╝ ╚═╝╚═╝  ╚═══╝ ╚═════╝ 

-- applications that should not be swallowed as parent windows
-- these apps typically spawn child processes that should remain separate
theme.parent_filter_list = { 
    "firefox", 
    "Gimp", 
    "Google-chrome",
    "Mixxx"  -- mixxx dj software should not swallow child windows
}

-- applications that should not be swallowed as child windows  
-- (empty by default - add here if specific apps should never be swallowed)
theme.child_filter_list = {}


-- // MARK: PLUGIN LAYOUT ICONS
-- All layout icons now use unified SVG format defined above via li() helper.
-- Old lain/default PNG assignments superseded.


-- NOTE: PNG fallback intentionally disabled to avoid overriding unified SVG icon above
-- theme.layout_treetile     = "~/.config/awesome/treetile/layout_icon.png"


return theme