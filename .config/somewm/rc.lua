--------------------------------------------------
-- Milkiis rc.lua                                --
-- https://github.com/mxmilkiib/dotfiles        --
--------------------------------------------------

-- 🧪 TESTING METHODS:
-- 
-- BASIC SYNTAX CHECK (no libraries):
--   lua -e "dofile('rc.lua')" 2>&1 | head -10
--   (Expected: "module 'gears' not found" - this is normal outside AwesomeWM)
-- DEBUG MODE:
--   awesome -c ~/.config/awesome/rc.lua --debug
--   (Runs with debug output for troubleshooting)
--
-- FULL ENVIRONMENT TEST (with AwesomeWM libraries):
--   awesome -c ~/.config/awesome/rc.lua --check
--   (Tests complete configuration with all libraries loaded)
--
-- NOTE: The "module 'gears' not found" error is expected when testing
-- outside the AwesomeWM environment.

-- XEPHYR TEST ENVIRONMENT:
--[[
Xephyr :1 -ac -br -noreset -screen 1152x720 & sleep 1 && DISPLAY=:1.0 awesome -c ~/.config/awesome/rc.lua || echo "Configuration error"
--]]
--   (Runs AwesomeWM in virtual display for safe testing)

-- LINTING WITH LUA CHECK:
--   luarocks install luacheck
--   luacheck rc.lua --no-max-line-length
--   (Static analysis for common Lua issues)

-- NON-CORE FEATURES OVERVIEW:
--   WINDOW MANAGEMENT ENHANCEMENTS
--     • Screen Rotation Utilities (rotate_screens helpers)
--     • Quake Dropdown Terminal (lain.util.quake per screen)
--     • Resize Without Warp (layout-aware resize_no_warp)
--     • Floating Window Center Preservation (window_manager helpers)
--   TAG AND TASKLIST AUGMENTATIONS
--     • Tasklist Mode Toggle (all-tag vs focused-tag views)
--     • Mode Glyphs Styling (plugins.mode_glyphs integration)
--     • Tag Indicators (plugins.tag_indicators highlights)
--     • Drag And Drop To Tag (plugins.dnd_to_tag handlers)
--   NOTIFICATION EXPERIENCE
--     • Notification Center (plugins.notification_center toggle)
--     • Clipboard Copy Of Last Alert (copy_last_notification helper)
--     • Hotkey Duplicate Detection (plugins.hotkey_dupe_detector audit)
--   APPLICATION TOGGLES AND MENUS
--     • Dedicated Toggles For KeePassXC, Pavucontrol, qBittorrent, Double Commander, Arandr
--     • Freedesktop Menu Integration (freedesktop.menu build)



-- // MARK: OVERVIEW
-- ################################################################################
-- ██████╗ ██╗██████╗ ███████╗ ██████╗████████╗ ██████╗ ██████╗ ██╗   ██╗
-- ██╔══██╗██║██╔══██╗██╔════╝██╔════╝╚══██╔══╝██╔═══██╗██╔══██╗╚██╗ ██╔╝
-- ██║  ██║██║██████╔╝█████╗  ██║        ██║   ██║   ██║██████╔╝ ╚████╔╝ 
-- ██║  ██║██║██╔══██╗██╔══╝  ██║        ██║   ██║   ██║██╔══██╗  ╚██╔╝  
-- ██████╔╝██║██║  ██║███████╗╚██████╗   ██║   ╚██████╔╝██║  ██║   ██║   
-- ╚═════╝ ╚═╝╚═╝  ╚═╝╚══════╝ ╚═════╝   ╚═╝    ╚═════╝ ╚═╝  ╚═╝   ╚═╝   
-- ################################################################################
-- CONFIGURATION DIRECTORY OVERVIEW
-- This awesome config contains the following components:
--
-- 📄 MAIN FILES:
--   • rc.lua (104KB, 2528 lines) - This comprehensive configuration file (cleaned & optimized)
--   • quake.lua (5.6KB, 169 lines) - Dropdown terminal (Quake-style)
--   • xrandr.lua (3.5KB, 136 lines) - Multi-monitor display management
--   • test_dialog_sizing.lua (1.5KB, 45 lines) - Dialog sizing test script
--
-- 📚 DOCUMENTATION:
--   • DIALOG_SIZING.md (5.0KB, 171 lines) - Auto-sizing for all dialog types
--   • CENTERWORK_ADAPTIVE_README.md (2.8KB, 67 lines) - Custom layout behavior
--   • LAYOUT_ICONS_README.md (4.5KB, 126 lines) - Complete icon reference
--
-- 🎨 THEMING:
--   • milktheme/ - Custom theme with backgrounds, icons, and styling
--
-- 🏗️ LAYOUT ENGINES:
--   • bling/ - Modern layouts (deck, horizontal, equalarea, vertical, mstab, centered)
--   • lain/ - Classic layouts (centerwork, cascade, termfair) + utilities
--   • treetile/ - Hierarchical window arrangement
--   • awesome-workspace-grid/ - Grid-based workspace management
--
-- 🎮 WINDOW MANAGEMENT:
--   • collision/ - Vim-like directional focus navigation
--   • awesome-switcher/ - Alt-Tab application switcher with previews
--   • cyclefocus/ - Advanced focus cycling mechanisms
--   • tyrannical/ - Rule-based dynamic tagging system
--   • revelation/ - OSX-style window exposé overview
--
-- 📱 WIDGETS & STATUS:
--   • battery-widget/ - Visual battery status and charging indicators
--   • media-player-widget/ - Media controls and track information
--   • awesome-wm-widgets/ - Widget collection framework
--
-- 🔌 SYSTEM INTEGRATION:
--   • freedesktop/ - XDG menu integration and .desktop file support
--   • gobo/ - Custom system integration utilities
--   • thrizen/ - Additional system tools
--   • plugins/ - Custom extensions (dnd_to_tag, shimmer, keystats, tag_indicators, etc.)
--
--
-- ⚠️  INTENTIONALLY DISABLED FEATURES (commented out by choice):
-- NAVIGATION ALTERNATIVES:
--   • gobo.awesome.alttab - Alternative Alt-Tab implementation 
--   • revelation - OSX-style window exposé overview
--   • awesomewm-vim-tmux-navigator - Cross-app (Vim/Tmux) navigation
--
-- LAYOUT EXTENSIONS:
--   • tyrannical + shortcuts - Dynamic desktop tagging system
--   • dovetail, thrizen, leaved - Alternative layout scripts
--   • fenetre - Titlebar customization framework
--   • awesome-workspace-grid - Grid-based tag navigation system
--
-- WIDGETS & UTILITIES:
--   • battery-widget - Visual battery status and charging indicators
--   • mpris_widget/media-player - Media controls and track information
--   • smart_borders - Automatic border width control
--
-- OPTIONAL BEHAVIORS:
--   • awful.hotkeys_popup.keys - Extended hotkey help system
--   • freedesktop desktop icons - Desktop icon integration
--   • Sloppy focus - Focus follows mouse behavior
--   • Alternative client rules, placement, and titlebar processing
--
-- NOTE: These features are available but intentionally disabled for current workflow.



-- // MARK: LIBS
-- ################################################################################
-- ██╗     ██╗██████╗ ███████╗
-- ██║     ██║██╔══██╗██╔════╝
-- ██║     ██║██████╔╝███████╗
-- ██║     ██║██╔══██╗╚════██║
-- ███████╗██║██████╔╝███████║
-- ╚══════╝╚═╝╚═════╝ ╚══════╝
-- ################################################################################
-- LIBRARIES - core library imports and external dependencies
-- If LuaRocks is installed, make sure that packages installed through it are found


pcall(require, "luarocks.loader")

-- Disable LuaJIT JIT compiler: somewm invokes Lua callbacks from C Wayland
-- signal handlers via lua_pcall. JIT-compiled traces can be invalidated by
-- GC or type changes, leaving dangling native code addresses. When the C
-- event loop then calls the callback, LuaJIT jumps to the stale trace
-- address (e.g. 0x300000000000) and segfaults. jit.off() prevents trace
-- compilation entirely; the interpreter performance impact is negligible
-- for a window manager config.
if jit and jit.off then
    jit.off()
end

-- Stop the garbage collector entirely as a diagnostic test. The crash
-- signature (0x300000000000 = LuaJIT lightuserdata tag with null pointer,
-- jumped to as a code address in lua_pcall from surface_commit_state)
-- indicates a Lua callback function reference is being collected while C
-- signal handlers still hold it. Removing explicit collectgarbage("collect")
-- calls was insufficient because LuaJIT's incremental GC still runs
-- automatically. If stopping GC prevents the crash, we know the root cause
-- is GC collecting live callback references and can tune accordingly. If
-- the crash persists, it is a C-level use-after-free in somewm itself.
-- RESULT: crash persisted with GC stopped. Root cause is NOT Lua GC — it is
-- a stale lua_ref in somewm's C signal dispatch code (surface_commit_state
-- handler fetches a registry ref that has been freed/overwritten, gets a
-- lightuserdata with null pointer (tag 3 = 0x300000000000), and tries to
-- call it as a function via lua_pcall). Reverting GC stop to avoid
-- unbounded memory growth.
-- collectgarbage("stop")

-- Standard awesome libraries
local gears = require("gears")
local awful = require("awful")
require("awful.autofocus")
local wibox = require("wibox")          -- Widget and layout library
local beautiful = require("beautiful")  -- Theme handling library
local naughty = require("naughty")      -- Notification library

-- Compatibility shim: somewm uses naughty.notification{} constructor, not naughty.notify()
-- Map naughty.notify(args) -> naughty.notification(args) so existing config code works
if not naughty.notify then
    naughty.notify = function(args)
        -- map "text" to "message" for the notification constructor
        if args and args.text and not args.message then
            args.message = args.text
            args.text = nil
        end
        return naughty.notification(args or {})
    end
end

local menubar = require("menubar")      -- Menu bar library
local hotkeys_popup = require("awful.hotkeys_popup")  -- Hotkey help system

local lgi = require("lgi")
local cairo = lgi.cairo

local keybindings = require("rc.keybindings")        -- Hotkey definitions
local ui_scale = require("rc.ui_scale")              -- UI zoom scale factor

-- startup profiler
-- local profiler = require("rc.startup_profiler")
-- usage:
--   1) enable: uncomment the line above to load the profiler
--   2) wrap expensive sections:
--        profiler.start("theme.init")
--        beautiful.init(...)
--        profiler.stop()
--      or use a one-shot wrapper:
--        profiler.measure("layouts_load", function()
--          -- code to measure
--        end)
--   3) reporting:
--      a summary report is printed automatically ~2s after startup
--      you can also call profiler.report() manually if needed


-- source external libraries (Lua modules)
local ruled = require("ruled")                                        -- modern rules API
local freedesktop = require("freedesktop")                            -- Create a menu from .desktop files

local lain = require("lain")                                          -- Layouts, widgets, utilities
local quake_lain = require("lain.util.quake")                         -- optional dropdown terminal (lain's quake)

local bling = require("bling")                                        -- Modern layouts and utilities
local treetile = require("treetile")                                  -- Hierarchical window arrangement
local vstack = require("vstack")                                      -- Single-column vertical layout

-- local shimmer = require("plugins.shimmer")                         -- Unified shimmer & border animation system
local noop = function() end;                                          -- no-op stub for temp disable
local shimmer = setmetatable({}, { __index = function() return noop end })

local mode_glyphs = require("plugins.mode_glyphs")                    -- stable tasklist mode glyphs
local hotkey_dupe_detector = require("plugins.hotkey_dupe_detector")  -- duplicate hotkey detection
local notification_center = require("plugins.notification_center")     -- notification history popup
local tag_pager = require("plugins.tag_pager")                          -- tag-aware expose pager
tag_pager.init()
local brightness = require("plugins.brightness")                        -- screen brightness with OSD


-- // MARK: -- shimmer configuration
-- configure unified shimmer system (text effects + border animation)
shimmer.configure({
    -- preset = "debug",  -- lighter, more visible preset    
    -- preset = "warm_light",  -- lighter, more visible preset
    -- preset = "bright_gold",  -- gold-only shine default
    -- preset = "candy",  -- candy-cane shine preset
    -- preset = "gold_contrast",  -- pastel candy-cane shine preset
    -- preset = "plasma_drift",  -- pastel candy-cane shine preset
    
    preset = "gold_crumble",  -- pastel candy-cane shine preset
    border = {
        -- smoothness = 2,  -- light border animation
        -- smoothness = 1,     -- 0.15s per frame
        smoothness = 1,     -- 0.15s per frame
        speed = 1,       -- animation timer interval
        follow_text_style = false,  -- if true, border uses same progression strategy as title text
        use_shimmer_palette = false,  -- if true, use shimmer colors; if false, use original default gradient
    },
    disable_shine = false,  -- disable shine aspectD
    disable_color = false,  -- keep color progression active
    -- max_animated_chars = 10  -- limit to 5 animated chars globally

})

-- minimal startup timer for shimmer - just enough for tasklist widgets to initialize
shimmer.post_startup_init()  -- defer small init to module (tasklist mapping + focused init)

-- configure reworked client mode task entry glyphs
mode_glyphs.configure({ style = "basic" })

-- optional: toggle mode glyphs styling between basic and shimmer
local function toggle_mode_glyphs_style()
    local new_style = (mode_glyphs.style == "basic") and "shimmer" or "basic"
    mode_glyphs.configure({ style = new_style })
    shimmer.refresh_all_tasklists()
    naughty.notify({ title = "mode glyphs", text = "style: " .. new_style, timeout = 2 })
end

-- bling extras: enable window swallowing and previews
-- keep defaults minimal; placement centered within workarea
-- bling.module.window_swallowing.start()
-- require("bling.widget.task_preview").enable({
--     placement_fn = function(d) awful.placement.centered(d, { honor_workarea = true }) end,
-- })
-- require("bling.widget.tag_preview").enable({
--     placement_fn = function(d) awful.placement.centered(d, { honor_workarea = true }) end,
--     show_client_content = true,
-- })




-- // MARK: ERRORS
-- ################################################################################
-- ███████╗██████╗ ██████╗  ██████╗ ██████╗ ███████╗
-- ██╔════╝██╔══██╗██╔══██╗██╔═══██╗██╔══██╗██╔════╝
-- █████╗  ██████╔╝██████╔╝██║   ██║██████╔╝███████╗
-- ██╔══╝  ██╔══██╗██╔══██╗██║   ██║██╔══██╗╚════██║
-- ███████╗██║  ██║██║  ██║╚██████╔╝██║  ██║███████║
-- ╚══════╝╚═╝  ╚═╝╚═╝  ╚═╝ ╚═════╝ ╚═╝  ╚═╝╚══════╝
-- ################################################################################
-- ERROR HANDLING - startup and runtime error management


-- Check if awesome encountered an error during startup and fell back to another config
-- (This code will only ever execute for the fallback config)
if awesome.startup_errors then
	naughty.notify({
		preset = naughty.config.presets.critical,
		title = "Oops, there were errors during startup!",
		text = awesome.startup_errors
	})
end


-- Handle runtime errors after startup
do
	local in_error = false
	awesome.connect_signal("debug::error", function(err)
		-- Make sure we don't go into an endless error loop
		if in_error then return end
		in_error = true

		naughty.notify({
			preset = naughty.config.presets.critical,
			title = "Oops, an error happened!",
			text = tostring(err)
		})
		in_error = false
	end)
end

-- Notification display handler (required by somewm 2.0 to render notifications)
naughty.connect_signal("request::display", function(n)
    naughty.layout.box { notification = n }
end)


-- Enable hotkeys help widget for VIM and other apps
-- when client with a matching name is opened:
require("awful.hotkeys_popup.keys")


-- // MARK: VARS
-- ################################################################################
-- ██╗   ██╗ █████╗ ██████╗ ███████╗
-- ██║   ██║██╔══██╗██╔══██╗██╔════╝
-- ██║   ██║███████║██████╔╝███████╗
-- ╚██╗ ██╔╝██╔══██║██╔══██╗╚════██║
--  ╚████╔╝ ██║  ██║██║  ██║███████║
--   ╚═══╝  ╚═╝  ╚═╝╚═╝  ╚═╝╚══════╝
-- ################################################################################
-- VARIABLES - global variables and configuration constants
-- ################################################################################
-- tasklist mode: false = focused tag only (default), true = all tags
local tasklist_show_all_tags = true


-- // MARK: UTILITY FUNCTIONS
-- ################################################################################


-- refresh_all_tasklists function moved earlier in file

-- Matcher generator for rules
local create_matcher = function(class_name)
    return function(c) return awful.rules.match(c, {class = class_name}) end
end

-- Unified tag hover styling function
local function blend_hex_colors(c1, c2, t)
    -- c1 and c2 are "#RRGGBB", t in [0,1]; returns blended hex
    local function hex_to_rgb(hex)
        return tonumber(hex:sub(2,3),16), tonumber(hex:sub(4,5),16), tonumber(hex:sub(6,7),16)
    end
    local r1,g1,b1 = hex_to_rgb(c1)
    local r2,g2,b2 = hex_to_rgb(c2)
    local r = math.floor(r1 + (r2 - r1) * t)
    local g = math.floor(g1 + (g2 - g1) * t)
    local b = math.floor(b1 + (b2 - b1) * t)
    return string.format("#%02x%02x%02x", r, g, b)
end


-- Confirmation menu for quitting awesome
confirmQuitmenu = awful.menu({
    items = {
        {"Cancel", function() do end end},
        {"Quit", function() awesome.quit() end}
    }
})

-- Variable definitions
modkey = "Mod4"  -- Super/Windows key
altkey = "Mod1"   -- Alt key
ctrlkey = "Control" -- Control key
shiftkey = "Shift"  -- Shift key
terminal = "alacritty" -- Wayland-native terminal (was foot, wezterm, urxvt)
-- terminal = "urxvt" -- X11 terminal (requires XWayland)
editor = os.getenv("EDITOR") or "nvim"
editor_cmd = terminal .. " -e " .. editor

-- // MARK: CONSTANTS
-- ################################################################################
-- Timing constants
local CLEANUP_INTERVAL = 30        -- Window cleanup timer (seconds)
local SHIMMER_INIT_DELAY = 0.05    -- Shimmer initialization delay (seconds)  
local DOUBLE_CLICK_INTERVAL = 0.20 -- Double-click detection timeout (seconds)

-- UI dimension constants
local QUAKE_HEIGHT_SMALL = 0.30    -- Small quake terminal height (ratio)
local QUAKE_HEIGHT_LARGE = 0.4     -- Large quake terminal height (ratio) 
local QUAKE_WIDTH_FULL = 1.0       -- Full-width quake terminal (ratio)

-- Icon and widget sizing
local DEFAULT_ICON_SIZE = 16       -- Fallback icon size (pixels)
local MIN_WINDOW_SIZE = 50         -- Minimum window dimensions (pixels)

-- Layout spacing and margins  
local TAGLIST_MARGIN_H = 8         -- Taglist horizontal margin (pixels)
local TAGLIST_MARGIN_V = 4         -- Taglist vertical margin (pixels)
local TASKLIST_MARGIN_LEFT = 4     -- Tasklist left margin (pixels)
local TASKLIST_MARGIN_RIGHT = 1    -- Tasklist right margin (pixels)
-- tasklist background colours by visibility state
local TASKLIST_BG_VISIBLE   = "#623997"  -- on a selected tag and not minimized
local TASKLIST_BG_OFFSCREEN = "#000000"  -- everything else (minimized, other tags)
local CLOCK_MARGIN = 7             -- Clock widget margin (pixels)

-- Resize and animation parameters
local RESIZE_BASE_DISTANCE = 50    -- Base distance for resize scaling
local RESIZE_SENSITIVITY = 200     -- Resize sensitivity factor
local MIN_SCALE_FACTOR = 0.1       -- Minimum window scale factor
local BITMAP_SIZE = 1024           -- Widget lock bitmap size

-- Notification settings (moved from shimmer)
local NOTIFICATION_WIDTH = beautiful.notification_width or 530     -- Notification width (pixels)

-- Tag navigation modifier keys
tag_nav_mod_keys = {modkey, altkey}

-- Default layout for milk theme
-- old: preferred default requires custom layout not yet loaded at this point
-- milkdefault = centerwork_twothirds.horizontal 
-- set safe temporary default; will be overridden after layout requires
milkdefault = lain.layout.termfair.center

-- Tyrannical tag configuration (commented out but kept for reference)
-- tyrannical.tags = {
--   {
--     name        = "1 Term",                 -- Call the tag "Term"
--     init        = true,                   -- Load the tag on startup
--     exclusive   = true,                   -- Refuse any other type of clients (by classes)
--     screen      = {1,2},                  -- Create this tag on screen 1 and screen 3
--     layout      = milkdefault,
--     instance    = {"dev", "ops"},         -- Accept the following instances. This takes precedence over 'class'
--     class       = { --Accept the following classes, refuse everything else (because of "exclusive=true")
--       "xterm" , "urxvt" , "aterm","URxvt","XTerm","konsole","terminator","gnome-terminal","alacritty"
--     }
--   } ,
--   {
--     name        = "2 Music",
--     init        = true,
--     exclusive   = true,
--     screen      = 1,
--     layout      = awful.layout.suit.max                          ,
--     single_instance_id = { "ncmpcpp" },
--     class = {
--     "*" },
--   } ,
--   {
--     name        = "3 Media",
--     init        = true,
--     exclusive   = true,
--     screen      = 1,
--     layout      = awful.layout.suit.max                          ,
--     class = {
--     "mpv" },
--   } ,
--   {
--     name        = "4 Share",
--     init        = true,
--     exclusive   = true,
--     screen      = 1,
--     layout      = awful.layout.suit.max                          ,
--     class ={
--     "qBittorrent", "Nicotine" }
--   } ,
--   {
--     name        = "5 Other",
--     init        = true,
--     exclusive   = true,
--     screen      = 1,
--     layout      = awful.layout.suit.max                          ,
--     class ={
--     "" }
--   } ,
--   {
--     name        = "6 Files",
--     init        = true,
--     exclusive   = true,
--     screen      = 1,
--     layout      = awful.layout.suit.tile,
--     -- exec_once   = {"doublecmd"}, --When the tag is accessed for the first time, execute this command
--     class  = {
--       "Thunar", "Konqueror", "Dolphin", "ark", "Nautilus","emelfm", "Doublecmd"
--     }
--   } ,
--   {
--     name        = "7 Stuff",
--     init        = true,
--     exclusive   = true,
--     screen      = 1,
--     layout      = awful.layout.suit.max                          ,
--     class ={
--     "" }
--   } ,
--           {
--     name        = "8 Pass",
--     init        = true,
--     exclusive   = true,
--     screen      = 1,
--     layout      = awful.layout.suit.max                          ,
--     class ={
--     "keepassxc" }
--   } ,
--   {
--     name        = "9 Vol",
--     init        = true,
--     exclusive   = true,
--     screen      = 1,
--     layout      = awful.layout.suit.max                          ,
--     class = {
--     "pavucontrol", "Jack_mixer" }
--   } ,
--   {
--     name        = "0 Sys",
--     init        = true,
--     exclusive   = true,
--     screen      = 1,
--     layout      = awful.layout.suit.max                          ,
--     class ={
--     "" }
--   } ,
--   {
--     name        = "- Chat",
--     init        = true,
--     exclusive   = true,
--     screen      = 1,
--     layout      = awful.layout.suit.max                          ,
--     class ={
--     "quassel" }
--   } ,
--   {
--     name        = "= Web",
--     init        = true,
--     exclusive   = true,
--     -- icon        = "~net.png",                 -- Use this icon for the tag (uncomment with a real path)
--     -- screen      = screen.count()>1 and 2 or 1,-- Setup on screen 2 if there is more than 1 screen, else on screen 1
--     screen      = 1,
--     layout      = awful.layout.suit.max,      -- Use the max layout
--     class = {
--       "Opera"         , "Firefox"        , "Rekonq"    , "Dillo"        , "Arora",
--     "Chromium"      , "nightly"        , "minefield" , "Firefox-esr"     }
--   } ,
--   }
--
--
--
-- -- Ignore the tag "exclusive" property for the following clients (matched by classes)
-- tyrannical.properties.intrusive = {
--   "ksnapshot"     , "pinentry"       , "gtksu"     , "kcalc"        , "xcalc"               ,
--   "feh"           , "Gradient editor", "About KDE" , "Paste Special", "Background color"    ,
--   "kcolorchooser" , "plasmoidviewer" , "Xephyr"    , "kruler"       , "plasmaengineexplorer",
-- }
--
-- -- Ignore the tiled layout for the matching clients
-- tyrannical.properties.floating = {
--   "MPlayer"      , "pinentry"        , "ksnapshot"  , "pinentry"     , "gtksu"          ,
--   "xine"         , "feh"             , "kmix"       , "kcalc"        , "xcalc"          ,
--   "yakuake"      , "Select Color$"   , "kruler"     , "kcolorchooser", "Paste Special"  ,
--   "New Form"     , "Insert Picture"  , "kcharselect", "mythfrontend" , "plasmoidviewer"
-- }
--
-- -- Make the matching clients (by classes) on top of the default layout
-- tyrannical.properties.ontop = {
--   "Xephyr"       , "ksnapshot"       , "kruler"
-- }
--
-- -- Force the matching clients (by classes) to be centered on the screen on init
-- tyrannical.properties.placement = {
--   kcalc = awful.placement.centered
-- }
--
-- tyrannical.settings.block_children_focus_stealing = true --Block popups ()
-- tyrannical.settings.group_children = true --Force popups/dialogs to have the same tags as the parent client




-- // MARK: WINDOW MANAGEMENT FUNCTIONS
-- ################################################################################

-- Window state tracking with cleanup - use weak keys to prevent memory leaks
-- MEMORY LEAK FIXES APPLIED:
-- • Changed to weak key tables for automatic garbage collection
-- • Reduced cleanup timer from 60s to 30s
-- • Added comprehensive client validation in all handlers
-- • Added immediate cleanup in unmanage signal
-- • Added explicit property cleanup in window_manager.cleanup()
-- • Added forced garbage collection to help clean weak references
local window_centers = setmetatable({}, { __mode = "k" })  -- weak keys for automatic GC
local dragging_clients = setmetatable({}, { __mode = "k" })  -- weak keys for automatic GC
local client_tiled_sizes = setmetatable({}, { __mode = "k" })  -- store tiled size for 10% reduction on float

-- periodic cleanup for memory management (reduced frequency since we have weak keys)
local cleanup_timer = gears.timer {
    timeout = CLEANUP_INTERVAL,  -- cleanup timer interval
    autostart = true,
    callback = function()
        -- clean up window_centers for invalid clients
        for c, _ in pairs(window_centers) do
            if not c.valid then
                window_centers[c] = nil
            end
        end
        -- clean up client_tiled_sizes for invalid clients
        for c, _ in pairs(client_tiled_sizes) do
            if not c.valid then
                client_tiled_sizes[c] = nil
            end
        end
        -- old: collectgarbage("collect") -- removed: forced full GC could
        -- collect Lua objects (e.g. old awful.wallpaper instances) that C
        -- signal handlers still reference, causing SEGV in lua_pcall
    end
}

-- Window management utilities
local window_manager = {
    -- Center floating window after resize
    maintain_center = function(c)
        if not c.floating or not window_centers[c] then return end
        
        local center = window_centers[c]
        local geo = c:geometry()
        local new_geo = {
            x = center.x - geo.width / 2,
            y = center.y - geo.height / 2,
            width = geo.width,
            height = geo.height
        }
        c:geometry(new_geo)
    end,
    
    -- Store window center position
    store_center = function(c)
        if not c.floating then return end
        local geo = c:geometry()
        window_centers[c] = {
            x = geo.x + geo.width / 2,
            y = geo.y + geo.height / 2
        }
    end,
    
    -- Clean up window tracking data
    cleanup = function(c)
        if not c then return end
        -- clear all client tracking data immediately
        window_centers[c] = nil
        dragging_clients[c] = nil
        client_tiled_sizes[c] = nil
        -- clear any client-specific properties that may cause leaks
        if c._intend_drag then c._intend_drag = nil end
        if c._was_maximized then c._was_maximized = nil end
    end,
    
    -- Check if window is being dragged
    is_dragging = function(c)
        return dragging_clients[c] ~= nil
    end,
    
    -- Mark window as being dragged
    set_dragging = function(c, dragging)
        local was_dragging = dragging_clients[c] ~= nil
        dragging_clients[c] = dragging and true or nil
        
        -- Emit signal when drag ends
        if was_dragging and not dragging then
            c:emit_signal("awesome::drag_end")
        end
    end
}


-- // MARK: SCREEN MANAGEMENT

-- screen rotation and management helpers
-- 
-- implements screen content rotation across multiple displays:
--   - rotates all tag contents (clients, layouts, properties) between screens
--   - preserves tag selection states and window assignments
--   - works bidirectionally (left/right rotation)
--   - provides visual feedback via notifications
-- 
-- keybindings:
--   - mod4 + ctrl + left/right arrows: keyboard rotation
--   - mod4 + scroll wheel (over layout widget): mouse rotation
-- 
-- rotation direction semantics:
--   - "left": content moves left (screen 1 gets screen 2's content)
--   - "right": content moves right (screen 1 gets last screen's content)

local function rotate_screens(direction)
    local all_screens = {}
    for s in screen do
        table.insert(all_screens, s)
    end
    
    -- need at least 2 screens to rotate content
    if #all_screens <= 1 then 
        naughty.notify({
            title = "Screen Rotation",
            text = "Only one screen, nothing to rotate",
            timeout = 2
        })
        return 
    end
    
    -- collect all tag configurations from all screens
    local screen_tags = {}
    for i, s in ipairs(all_screens) do
        screen_tags[i] = {}
        for j, tag in ipairs(s.tags) do
            -- store tag properties
            screen_tags[i][j] = {
                name = tag.name,
                selected = tag.selected,
                layout = tag.layout,
                clients = tag:clients(),
                -- store additional tag properties
                master_width_factor = tag.master_width_factor,
                master_count = tag.master_count,
                column_count = tag.column_count,
                gap = tag.gap,
                gap_single_client = tag.gap_single_client
            }
        end
    end
    
    -- calculate rotation: left = content moves left (screen indices go right)
    -- right = content moves right (screen indices go left)
    local target_mapping = {}
    for i = 1, #all_screens do
        if direction == "left" or direction == 1 then
            -- content moves left: screen 1 gets screen 2's content, etc.
            target_mapping[i] = (i % #all_screens) + 1
        else -- right or -1
            -- content moves right: screen 1 gets screen #'s content, etc.
            target_mapping[i] = ((i - 2 + #all_screens) % #all_screens) + 1
        end
    end
    
    -- apply the rotation
    for screen_idx, source_idx in pairs(target_mapping) do
        local target_screen = all_screens[screen_idx]
        local source_tags = screen_tags[source_idx]
        
        -- update each tag with properties from source
        for tag_idx, tag in ipairs(target_screen.tags) do
            local source_tag_data = source_tags[tag_idx]
            if source_tag_data then
                -- move all clients from source to target tag
                for _, client in ipairs(source_tag_data.clients) do
                    if client.valid then
                        client:move_to_tag(tag)
                    end
                end
                
                -- apply tag properties
                tag.layout = source_tag_data.layout
                tag.master_width_factor = source_tag_data.master_width_factor
                tag.master_count = source_tag_data.master_count
                tag.column_count = source_tag_data.column_count
                tag.gap = source_tag_data.gap
                tag.gap_single_client = source_tag_data.gap_single_client
                
                -- apply selection state last (after clients are moved)
                if source_tag_data.selected then
                    tag:view_only()
                end
            end
        end
    end
    
    -- show notification
    local direction_text = (direction == "left" or direction == 1) and "left" or "right"
    naughty.notify({
        title = "Screen Content Rotated",
        text = "All tags rotated " .. direction_text .. " across " .. #all_screens .. " screens",
        timeout = 2
    })
end


-- // MARK: -- tag navigation
-- tag navigation functions for moving clients between tags
local function move_to_previous_tag()
    local c = client.focus
    if not c then return end
    local current_tag = c:tags()[1]
    if current_tag then
        local prev_tag = current_tag.screen.tags[current_tag.index - 1]
        if prev_tag then c:move_to_tag(prev_tag) end
    end
end

local function move_to_next_tag()
    local c = client.focus
    if not c then return end
    local current_tag = c:tags()[1]
    if current_tag then
        local next_tag = current_tag.screen.tags[current_tag.index + 1]
        if next_tag then c:move_to_tag(next_tag) end
    end
end

local function move_to_previous_tag_and_follow()
    local c = client.focus
    if not c then return end
    local current_tag = c:tags()[1]
    if current_tag then
        local prev_tag = current_tag.screen.tags[current_tag.index - 1]
        if prev_tag then 
            c:move_to_tag(prev_tag)
            prev_tag:view_only()
        end
    end
end

local function move_to_next_tag_and_follow()
    local c = client.focus
    if not c then return end
    local current_tag = c:tags()[1]
    if current_tag then
        local next_tag = current_tag.screen.tags[current_tag.index + 1]
        if next_tag then 
            c:move_to_tag(next_tag)
            next_tag:view_only()
        end
    end
end

local function cycle_tags_with_clients(direction)
    local current_screen = awful.screen.focused()
    local all_tags = current_screen.tags
    local current_tag = current_screen.selected_tag
    local current_index = gears.table.hasitem(all_tags, current_tag)
    
    local count = #all_tags
    
    for i = 1, count - 1 do
        local idx
        if direction == "next" then
            idx = ((current_index + i - 1) % count) + 1
        else
            idx = ((current_index - i - 1 + count) % count) + 1
        end
        local tag = all_tags[idx]
        
        if #tag:clients() > 0 then
            tag:view_only()
            return
        end
    end
end

local function cycle_tags_with_visible_clients(direction)
    local current_screen = awful.screen.focused()
    local all_tags = current_screen.tags
    local current_tag = current_screen.selected_tag
    local current_index = gears.table.hasitem(all_tags, current_tag)

    for i = 1, #all_tags - 1 do
        local idx
        if direction == "next" then
            idx = ((current_index - 1 + i) % #all_tags) + 1
        else
            idx = ((current_index - 1 - i + #all_tags) % #all_tags) + 1
        end
        local tag = all_tags[idx]
        local has_visible_clients = false
        for _, c in ipairs(tag:clients()) do
            if not c.minimized then
                has_visible_clients = true
                break
            end
        end
        if has_visible_clients then
            tag:view_only()
            return
        end
    end
end


-- // MARK: -- tasklist mode toggle
local function toggle_tasklist_mode()
    tasklist_show_all_tags = not tasklist_show_all_tags
    
    -- refresh all tasklists on all screens - force filter re-evaluation
    for s in screen do
        if s.mytasklist then
            -- force complete tasklist rebuild by emitting multiple signals
            s.mytasklist:emit_signal("widget::layout_changed")
            s.mytasklist:emit_signal("widget::redraw_needed")
            -- trigger client property changes to force filter re-evaluation
            for _, c in ipairs(client.get()) do
                if c.screen == s then
                    c:emit_signal("property::urgent")
                end
            end
        end
    end
    
    -- show notification about current mode
    local mode_text = tasklist_show_all_tags and "all tags" or "focused tag only"
    naughty.notify({
        title = "tasklist mode",
        text = "showing tasks from: " .. mode_text,
        timeout = 2
    })
end


-- // MARK: -- generic app tag toggle
-- generic function to toggle app visibility on a specific tag
-- @param match_fn: function(c) that returns true if client matches app
-- @param tag_number: tag index (1-based)
-- @param spawn_cmd: command to launch app if not running
local function toggle_app_tag(match_fn, tag_number, spawn_cmd)
    local current_screen = awful.screen.focused()
    
    -- find the app client
    local app_client = nil
    for _, c in ipairs(client.get()) do
        if match_fn(c) then
            app_client = c
            break
        end
    end
    
    if app_client then
        -- app exists - work with the screen it's actually on
        local app_screen = app_client.screen
        local app_tag = app_screen.tags[tag_number]
        
        if not app_tag then
            return
        end
        
        -- if app is on a different screen, move it to current screen
        if app_screen ~= current_screen then
            app_client:move_to_screen(current_screen)
            -- now get the tag on the current screen
            local current_tag = current_screen.tags[tag_number]
            if current_tag then
                app_client:move_to_tag(current_tag)
                app_tag = current_tag
            end
        end
        
        -- toggle tag visibility
        if app_tag.selected then
            -- tag is visible, hide it and minimize window
            app_client.minimized = true
            awful.tag.viewtoggle(app_tag)
        else
            -- tag is not visible, show it and unminimize window
            app_client.minimized = false
            awful.tag.viewtoggle(app_tag)
            -- focus the window
            app_client:emit_signal("request::activate", "toggle_app_tag", {raise = true})
        end
    else
        -- app doesn't exist, launch it on current screen
        local current_tag = current_screen.tags[tag_number]
        if not current_tag then
            return
        end
        
        -- make tag visible if not already
        if not current_tag.selected then
            awful.tag.viewtoggle(current_tag)
        end
        
        awful.spawn.with_shell(spawn_cmd)
    end
end


-- // MARK: -- pavucontrol toggle
local function toggle_pavucontrol()
    toggle_app_tag(
        function(c) return c.class == "Pavucontrol" end,
        8,
        "GDK_SCALE=0.9 pavucontrol"
    )
end


-- // MARK: -- keepassxc toggle
local function toggle_keepassxc()
    toggle_app_tag(
        function(c) return c.class == "KeePassXC" end,
        8,
        "keepassxc ~/state/nextcloud/sync/keepassxc-mb.kdbx"
    )
end


-- // MARK: -- qbittorrent toggle
local function toggle_qbittorrent()
    toggle_app_tag(
        function(c) return c.instance == "qbittorrent" or c.class == "qBittorrent" end,
        3,
        "qbittorrent"
    )
end


-- // MARK: -- doublecmd toggle
local function toggle_doublecmd()
    toggle_app_tag(
        function(c) return c.instance == "doublecmd" or c.instance == "Double Commander" end,
        9,
        "doublecmd"
    )
end


-- // MARK: -- arandr toggle
local function toggle_arandr()
    toggle_app_tag(
        function(c) return c.class == "Arandr" end,
        9,
        "arandr"
    )
end


-- // MARK: -- firefox toggle
local function toggle_firefox()
    toggle_app_tag(
        function(c)
            local class = c.class
            local instance = c.instance
            return class == "firefox" or class == "Firefox" or class == "Navigator"
                or instance == "firefox" or instance == "Navigator"
        end,
        12,
        "firefox"
    )
end


-- // MARK: -- resize-no-warp
-- anti-warp resize function that prevents cursor from jumping to another monitor
local function resize_no_warp(c)
    c:emit_signal("request::activate", "mouse_click", {raise = true})

    -- check if client is floating or if current layout has mouse_resize_handler
    local layout = awful.layout.get(c.screen)
    
    -- if client is not floating and layout has mouse_resize_handler, use it
    if not c.floating and layout.mouse_resize_handler then
        
        local initial_coords = mouse.coords()
        local geo = c:geometry()
        
        -- determine corner based on mouse position relative to client center  
        local corner
        if initial_coords.y < geo.y + geo.height/2 then
            if initial_coords.x < geo.x + geo.width/2 then
                corner = "top_left"
            else
                corner = "top_right"
            end
        else
            if initial_coords.x < geo.x + geo.width/2 then
                corner = "bottom_left"
            else
                corner = "bottom_right"
            end
        end
        
        -- call the layout's mouse resize handler
        layout.mouse_resize_handler(c, corner, initial_coords.x, initial_coords.y)
        return
    end

    -- fallback to floating window resize for floating clients or layouts without mouse handler
    -- store initial cursor position
    local initial_coords = mouse.coords()

    -- store initial client geometry
    local geo = c:geometry()
    local initial_geo = {x = geo.x, y = geo.y, width = geo.width, height = geo.height}

    -- detect which corner/edge was grabbed based on mouse position
    -- this determines which corner stays fixed (anchor) during resize
    local corner = ""
    local edge_threshold = 20  -- pixels from edge to consider it an edge grab
    
    local rel_x = initial_coords.x - geo.x
    local rel_y = initial_coords.y - geo.y
    
    -- determine vertical anchor (top or bottom)
    if rel_y < edge_threshold then
        corner = "top"
    elseif rel_y > geo.height - edge_threshold then
        corner = "bottom"
    else
        -- middle vertical, will resize both top and bottom equally
        corner = "middle"
    end
    
    -- determine horizontal anchor (left or right)
    if rel_x < edge_threshold then
        corner = corner .. "_left"
    elseif rel_x > geo.width - edge_threshold then
        corner = corner .. "_right"
    else
        -- middle horizontal, will resize both left and right equally
        corner = corner .. "_center"
    end

    -- define anchor point based on grabbed corner (opposite corner stays fixed)
    local anchor_x, anchor_y
    if corner:match("left") then
        anchor_x = geo.x + geo.width  -- right edge is anchor
    elseif corner:match("right") then
        anchor_x = geo.x  -- left edge is anchor
    else
        anchor_x = geo.x + geo.width / 2  -- center is anchor
    end
    
    if corner:match("top") then
        anchor_y = geo.y + geo.height  -- bottom edge is anchor
    elseif corner:match("bottom") then
        anchor_y = geo.y  -- top edge is anchor
    else
        anchor_y = geo.y + geo.height / 2  -- center is anchor
    end

    -- get the current screen's geometry for boundary checking
    local screen_geo = screen[c.screen].geometry

    -- start the mouse grabber without warping the cursor
    mousegrabber.run(function(m)
        if not c.valid then return false end

        -- calculate new dimensions based on mouse movement from anchor point
        local new_x, new_y, new_width, new_height
        
        if corner:match("left") then
            -- dragging left edge: anchor is right edge
            new_x = math.min(m.x, anchor_x - MIN_WINDOW_SIZE)
            new_width = anchor_x - new_x
        elseif corner:match("right") then
            -- dragging right edge: anchor is left edge
            new_x = anchor_x
            new_width = math.max(m.x - anchor_x, MIN_WINDOW_SIZE)
        else
            -- dragging center horizontally: expand/contract symmetrically
            local dx = m.x - initial_coords.x
            new_width = math.max(initial_geo.width + dx * 2, MIN_WINDOW_SIZE)
            new_x = anchor_x - new_width / 2
        end
        
        if corner:match("top") then
            -- dragging top edge: anchor is bottom edge
            new_y = math.min(m.y, anchor_y - MIN_WINDOW_SIZE)
            new_height = anchor_y - new_y
        elseif corner:match("bottom") then
            -- dragging bottom edge: anchor is top edge
            new_y = anchor_y
            new_height = math.max(m.y - anchor_y, MIN_WINDOW_SIZE)
        else
            -- dragging center vertically: expand/contract symmetrically
            local dy = m.y - initial_coords.y
            new_height = math.max(initial_geo.height + dy * 2, MIN_WINDOW_SIZE)
            new_y = anchor_y - new_height / 2
        end

        -- constrain to screen boundaries
        if new_x < screen_geo.x then
            new_width = new_width - (screen_geo.x - new_x)
            new_x = screen_geo.x
        end
        if new_y < screen_geo.y then
            new_height = new_height - (screen_geo.y - new_y)
            new_y = screen_geo.y
        end
        if new_x + new_width > screen_geo.x + screen_geo.width then
            new_width = screen_geo.x + screen_geo.width - new_x
        end
        if new_y + new_height > screen_geo.y + screen_geo.height then
            new_height = screen_geo.y + screen_geo.height - new_y
        end

        -- ensure minimum size after boundary constraints
        new_width = math.max(new_width, MIN_WINDOW_SIZE)
        new_height = math.max(new_height, MIN_WINDOW_SIZE)

        -- apply the new geometry
        c:geometry({
            x = math.floor(new_x),
            y = math.floor(new_y),
            width = math.floor(new_width),
            height = math.floor(new_height)
        })

        return m.buttons[3] or m.buttons[2]  -- continue as long as right or middle button is pressed
    end, "fleur")

    -- update center position for our center-locked resizing
    -- once resize is complete
    if c.floating and window_centers then
        local new_geo = c:geometry()
        window_centers[c] = {
            x = new_geo.x + new_geo.width / 2,
            y = new_geo.y + new_geo.height / 2
        }
    end
end




-- // MARK: VISUALS
-- ################################################################################
-- ██████╗ ███████╗███████╗███████╗
-- ██╔══██╗██╔════╝██╔════╝██╔════╝
-- ██║  ██║█████╗  █████╗  ███████╗
-- ██║  ██║██╔══╝  ██╔══╝  ╚════██║
-- ██████╔╝███████╗██║     ███████║
-- ╚═════╝ ╚══════╝╚═╝     ╚══════╝
-- ################################################################################
-- DEFINITIONS - theme configuration and visual foundations


-- theme init
beautiful.init(gears.filesystem.get_configuration_dir() .. "milktheme/theme.lua")

-- shimmer safety: ensure any plain tasklist focused text is not stark white
-- this prevents visible white flashes if a plain frame sneaks in during redraw
beautiful.tasklist_fg_focus = beautiful.tasklist_fg_focus or "#d2b48c"  -- warm tan
-- optionally tune normal/unfocused to a neutral; leave commented if not desired
-- beautiful.tasklist_fg_normal = beautiful.tasklist_fg_normal or "#c0c0c0"

-- title change logger - logs all client title changes (no duplicates)
local __title_log = setmetatable({}, { __mode = 'k' }) -- weak keys to avoid leaks
local function __log_title(c, reason)
    if not c or not c.valid then return end
    local name = c.name or ""
    if name == "" then return end
    if __title_log[c] == name then return end -- skip duplicates
    __title_log[c] = name
    local class = c.class or c.instance or "?"
    local prefix = reason and ("(" .. tostring(reason) .. ") ") or ""
    if gears and gears.debug and gears.debug.print_warning then
        gears.debug.print_warning("[title] " .. prefix .. class .. ": " .. name)
    else
        print("[title] " .. prefix .. class .. ": " .. name)
    end
end

client.connect_signal("property::name", function(c) __log_title(c, "name") end)
-- somewm 2.0 renamed manage/unmanage to request::manage/request::unmanage
client.connect_signal("request::manage", function(c) __log_title(c, "init") end)
client.connect_signal("request::unmanage", function(c) __title_log[c] = nil end)


-- // MARK: ICONS
-- ################################################################################
-- ██╗ ██████╗ ██████╗ ███╗   ██╗███████╗
-- ██║██╔════╝██╔═══██╗████╗  ██║██╔════╝
-- ██║██║     ██║   ██║██╔██╗ ██║███████╗
-- ██║██║     ██║   ██║██║╚██╗██║╚════██║
-- ██║╚██████╗╚██████╔╝██║ ╚████║███████║
-- ╚═╝ ╚═════╝ ╚═════╝ ╚═╝  ╚═══╝╚══════╝
-- ################################################################################
-- icon management system - fallback icons and color sampling

-- helper: resolve fallback icon using theme (menubar) or known paths
-- uses awesome.load_image (returns light userdata) instead of
-- gears.surface.load_uncached (returns lgi cairo.Surface object) because
-- luaA_client_set_icon expects a raw cairo_surface_t* pointer; passing an
-- lgi full userdata causes draw_dup_image_surface to dereference a wrong
-- pointer and segfault (trip-zip/somewm#727)
local function get_fallback_icon(c)
    local utils = menubar and menubar.utils
    local function load_icon_by_name(name)
        if not utils or not utils.lookup_icon then return nil end
        local p = utils.lookup_icon(name)
        if p and gears.filesystem.file_readable(p) then
            local surf = awesome.load_image(p)
            if surf then return surf end
        end
        return nil
    end

    -- prefer terminal icon if class suggests a terminal
    local is_term = false
    if c and c.class then
        local cls = tostring(c.class)
        local l = cls:lower()
        is_term = l:find("term") ~= nil or cls == "URxvt" or cls == "urxvt" or cls == "XTerm" or cls == "xterm" or cls == "Alacritty"
    end

    -- try terminal icons first if this is a terminal
    if is_term then
        local names_term = {
            "utilities-terminal",
            "org.gnome.Terminal",
            "terminal",
            "xterm",
            "utilities-terminal-symbolic",
        }
        for _, n in ipairs(names_term) do
            local surf = load_icon_by_name(n)
            if surf then return surf end
        end
    end
    local names_generic = {
        -- "application-x-executable-symbolic",
        -- "application-x-executable",
        -- "application-default-icon",
        -- "applications-system",
        -- "system-run",
    }
    for _, n in ipairs(names_generic) do
        local surf = load_icon_by_name(n)
        if surf then return surf end
    end

    -- last resort hardcoded paths (prefer small PNGs over SVG symbolics for reliability)
    local candidates = {
        -- generic symbolic svg (small vector; works on most systems)
        -- adwaita
        "/usr/share/icons/Adwaita/16x16/mimetypes/application-x-executable.png",
    }
    for _, path in ipairs(candidates) do
        if path and gears.filesystem.file_readable(path) then
            local surf = awesome.load_image(path)
            if surf then return surf end
        end
    end

    return nil
end


-- // MARK: -- average-color-from-icon
-- sample dominant color from client icon
local function average_color_from_icon(icon)
    if not icon then return "#aaaaaa" end
    
    local ok, surf = pcall(gears.surface, icon)
    if not ok or not surf then return "#aaaaaa" end
    
    -- Get icon dimensions
    local w, h = 32, 32
    local okw, valw = pcall(function() return surf:get_width() end)
    if okw and type(valw) == 'number' and valw > 0 then w = valw end
    local okh, valh = pcall(function() return surf:get_height() end)
    if okh and type(valh) == 'number' and valh > 0 then h = valh end
    if w <= 0 or h <= 0 then return "#aaaaaa" end
    
    -- Create image surface with specific format for pixel access
    local img = cairo.ImageSurface(cairo.Format.RGB24, w, h)
    local cr = cairo.Context(img)
    
    -- Draw the icon onto our surface
    cr:set_source_surface(surf, 0, 0)
    cr:paint()
    
    -- Extract pixel data
    local data = nil
    local okd, val = pcall(function() return img:get_data() end)
    if okd then data = val end
    if not data or #data < 4 then return "#aaaaaa" end
    
    -- Average the RGB values
    local r, g, b, count = 0, 0, 0, 0
    for i = 1, #data, 4 do  -- BGRA format
        b = b + string.byte(data, i)
        g = g + string.byte(data, i + 1)
        r = r + string.byte(data, i + 2)
        count = count + 1
    end
    
    if count > 0 then
        r, g, b = math.floor(r / count), math.floor(g / count), math.floor(b / count)
        return string.format("#%02x%02x%02x", r, g, b)
    end
    
    return "#aaaaaa"
end


-- // MARK: -- create-terminal-icon-surface
-- create a simple generic terminal icon surface (fallback when no file icon is available)
local function create_terminal_icon_surface(size)
    size = size or 16
    local img = cairo.ImageSurface(cairo.Format.ARGB32, size, size)
    local cr = cairo.Context(img)
    
    -- Fill background with dark gray
    cr:set_source_rgba(0.2, 0.2, 0.2, 1.0)
    cr:rectangle(0, 0, size, size)
    cr:fill()
    
    -- Draw simple terminal representation
    local margin = size * 0.15
    local inner_size = size - (margin * 2)
    
    -- Draw terminal window border
    cr:set_source_rgba(0.7, 0.7, 0.7, 1.0)
    cr:set_line_width(1)
    cr:rectangle(margin, margin, inner_size, inner_size)
    cr:stroke()
    
    -- Draw cursor or prompt representation
    local cursor_x = margin + (inner_size * 0.1)
    local cursor_y = margin + (inner_size * 0.3)
    local cursor_w = inner_size * 0.05
    local cursor_h = inner_size * 0.15
    
    cr:set_source_rgba(0.9, 0.9, 0.9, 1.0)
    cr:rectangle(cursor_x, cursor_y, cursor_w, cursor_h)
    cr:fill()
    
    -- Add some text-like lines
    cr:set_line_width(0.5)
    for i = 1, 3 do
        local line_y = cursor_y + (cursor_h * 1.5 * i)
        if line_y < (margin + inner_size - margin) then
            cr:move_to(cursor_x, line_y)
            cr:line_to(cursor_x + (inner_size * 0.6), line_y)
            cr:stroke()
        end
    end
    
    return img
end


-- Get dominant color for a tag based on visible client icons
local function get_tag_dominant_color(tag)
    if not tag or not tag.valid then return "#aaaaaa" end
    
    local rs, gs, bs, n = 0, 0, 0, 0
    local clients = tag:clients()
    
    for _, c in ipairs(clients) do
        if c.valid and not c.minimized and not c.hidden then
            local icon = c.icon or c.class
            local color_str = average_color_from_icon(icon)
            
            -- Parse hex color
            local r = tonumber(color_str:sub(2, 3), 16) or 170
            local g = tonumber(color_str:sub(4, 5), 16) or 170
            local b = tonumber(color_str:sub(6, 7), 16) or 170
            
            rs, gs, bs, n = rs + r, gs + g, bs + b, n + 1
        end
    end
    
    -- If no visible clients, try minimized ones
    if n == 0 then
        for _, c in ipairs(clients) do
            if c.valid and c.minimized then
                local icon = c.icon or c.class
                local color_str = average_color_from_icon(icon)
                
                local r = tonumber(color_str:sub(2, 3), 16) or 170
                local g = tonumber(color_str:sub(4, 5), 16) or 170
                local b = tonumber(color_str:sub(6, 7), 16) or 170
                
                rs, gs, bs, n = rs + r, gs + g, bs + b, n + 1
            end
        end
    end
    
    if n > 0 then
        local r, g, b = math.floor(rs / n), math.floor(gs / n), math.floor(bs / n)
        return string.format("#%02x%02x%02x", r, g, b)
    end
    
    return "#aaaaaa"
end






-- // MARK: NOTIFICATIONS
-- ################################################################################
-- ███╗   ██╗ ██████╗ ████████╗██╗███████╗██╗ ██████╗ █████╗ ████████╗██╗ ██████╗ ███╗   ██╗███████╗
-- ████╗  ██║██╔═══██╗╚══██╔══╝██║██╔════╝██║██╔════╝██╔══██╗╚══██╔══╝██║██╔═══██╗████╗  ██║██╔════╝
-- ██╔██╗ ██║██║   ██║   ██║   ██║█████╗  ██║██║     ███████║   ██║   ██║██║   ██║██╔██╗ ██║███████╗
-- ██║╚██╗██║██║   ██║   ██║   ██║██╔══╝  ██║██║     ██╔══██║   ██║   ██║██║   ██║██║╚██╗██║╚════██║
-- ██║ ╚████║╚██████╔╝   ██║   ██║██║     ██║╚██████╗██║  ██║   ██║   ██║╚██████╔╝██║ ╚████║███████║
-- ╚═╝  ╚═══╝ ╚═════╝    ╚═╝   ╚═╝╚═╝     ╚═╝ ╚═════╝╚═╝  ╚═╝   ╚═╝   ╚═╝ ╚═════╝ ╚═╝  ╚═══╝╚══════╝
-- ################################################################################
-- notification system - configuration and interaction handlers



-- force enable ruled notifications
ruled.notification.connect_signal("request::rules", function()
    ruled.notification.append_rule {
        rule = {},
        properties = {
            screen = awful.screen.preferred,
            implicit_timeout = 50,
        }
    }
end)

-- explicitly require and configure naughty display - this was the key fix for Xephyr

naughty.config.defaults.ontop = true
naughty.config.defaults.timeout = 50
-- naughty.config.defaults.margin = dpi("16")  
-- naughty.config.defaults.border_width = 0
naughty.config.defaults.width = 400  -- Width in pixels instead of percentage string
-- naughty.config.defaults.position = 'top_right'  -- changed from bottom_middle for testing
naughty.config.defaults.position = 'bottom_middle'  -- changed from bottom_middle for testing
-- naughty.config.defaults.screen = awful.screen.preferred  -- ensure screen is set

-- use theme colors for regular notifications
naughty.config.defaults.bg = beautiful.notification_bg or (beautiful.main_purple and beautiful.main_purple.base) or "#FFD700"
naughty.config.defaults.fg = beautiful.notification_fg or "#000000"
naughty.config.defaults.border_color = (beautiful.main_purple and beautiful.main_purple.base) or "#623997"
naughty.config.defaults.border_width = 2

-- optional: test notification on startup (comment out when not needed)
-- gears.timer.start_new(2, function()
--     naughty.notify({
--         title = "AwesomeWM",
--         text = "Configuration loaded successfully!",
--         timeout = 3,
--         position = "top_right"
--     })
--     return false
-- end)

-- notification icon settings
-- attempt to constrain the size of large icons in their apps notifications
naughty.config.defaults['icon_size'] = 64




-- // MARK: -- notification-interactions
-- track last notification for keyboard copying
local last_notification_text = ""

-- enable default naughty notification system 
require("naughty.dbus")

-- store notification text and add click handling to existing notifications
naughty.connect_signal("added", function(n)
    -- store text for keyboard shortcut
    local text_to_copy = ""
    if n.title and n.text then
        text_to_copy = n.title .. "\n" .. n.text
        last_notification_text = text_to_copy
    elseif n.title then
        text_to_copy = n.title
        last_notification_text = text_to_copy
    elseif n.text then
        text_to_copy = n.text
        last_notification_text = text_to_copy
    else
        last_notification_text = ""
    end
    
    -- add right-click handler to the notification (after it's displayed)
    gears.timer.delayed_call(function()
        if n.box and n.box.widget then
            n.box.widget:connect_signal("button::press", function(_, _, _, button)
                if button == 1 then
                    -- left click: dismiss (default behavior)
                    n:destroy()
                elseif button == 3 then
                    -- right click: copy to clipboard
                    if text_to_copy ~= "" then
                        -- awful.spawn.with_shell("echo '" .. text_to_copy:gsub("'", "'\"'\"'") .. "' | xclip -selection clipboard")
                        awful.spawn.with_shell("echo '" .. text_to_copy:gsub("'", "'\"'\"'") .. "' | wl-copy")
                        naughty.notify({
                            title = "copied",
                            text = "notification copied to clipboard",
                            timeout = 2,
                        })
                    else
                        naughty.notify({
                            title = "nothing to copy",
                            text = "notification has no text",
                            timeout = 2,
                        })
                    end
                    n:destroy()
                end
            end)
        end
    end)
end)

-- function to copy last notification via keyboard shortcut
local function copy_last_notification()
    if last_notification_text ~= "" then
        awful.spawn.with_shell("echo '" .. last_notification_text:gsub("'", "'\"'\"'") .. "' | wl-copy")
        naughty.notify({
            title = "copied",
            text = "last notification copied to clipboard",
            timeout = 2,
        })
    else
        naughty.notify({
            title = "no notification",
            text = "no recent notification to copy",
            timeout = 2,
        })
    end
end




-- // MARK: NOTIFICATION CENTER
-- ################################################################################
-- ███╗   ██╗ ██████╗ ████████╗██╗  ██╗██╗ ██████╗ ███████╗████████╗██╗ ██████╗ ████████╗██╗ ██████╗ ███╗   ██╗
-- ████╗  ██║██╔═══██╗╚══██╔══╝██║  ██║██║██╔════╝ ██╔════╝╚══██╔══╝██║██╔═══██╗╚══██╔══╝██║██╔═══██╗████╗  ██║
-- ██╔██╗ ██║██║   ██║   ██║   ███████║██║██║  ███╗█████╗     ██║   ██║██║   ██║   ██║   ██║██║   ██║██╔██╗ ██║
-- ██║╚██╗██║██║   ██║   ██║   ██╔══██║██║██║   ██║██╔══╝     ██║   ██║██║   ██║   ██║   ██║██║   ██║██║╚██╗██║
-- ██║ ╚████║╚██████╔╝   ██║   ██║  ██║██║╚██████╔╝███████╗   ██║   ██║╚██████╔╝   ██║   ██║╚██████╔╝██║ ╚████║
-- ╚═╝  ╚═══╝ ╚═════╝    ╚═╝   ╚═╝  ╚═╝╚═╝ ╚═════╝ ╚══════╝   ╚═╝   ╚═╝ ╚═════╝    ╚═╝   ╚═╝ ╚═════╝ ╚═╝  ╚═══╝
-- ################################################################################
-- notification center popup and history management

-- previous implementation: none

local function toggle_notification_center()
    notification_center.toggle()
end

local function toggle_tag_pager()
    tag_pager.toggle()
end

local function clear_notification_history()
    notification_center.clear_history()
end

local function notification_center_delete_oldest()
    notification_center.keybindings.delete_oldest()
end



-- // MARK: hotkeys
-- ################################################################################
-- ██╗  ██╗ ██████╗ ████████╗██╗  ██╗███████╗██╗   ██╗███████╗
-- ██║  ██║██╔═══██╗╚══██╔══╝██║ ██╔╝██╔════╝╚██╗ ██╔╝██╔════╝
-- ███████║██║   ██║   ██║   █████╔╝ █████╗   ╚████╔╝ ███████╗
-- ██╔══██║██║   ██║   ██║   ██╔═██╗ ██╔══╝    ╚██╔╝  ╚════██║
-- ██║  ██║╚██████╔╝   ██║   ██║  ██╗███████╗   ██║   ███████║
-- ╚═╝  ╚═╝ ╚═════╝    ╚═╝   ╚═╝  ╚═╝╚══════╝   ╚═╝   ╚══════╝
-- ################################################################################
-- hotkeys - global and client key bindings
-- 
-- modular keybinding system with external keybindings module:
--   - imports keybindings from separate module for maintainability
--   - passes rc.lua-defined functions to keybindings builder
--   - provides global keys (window management, launchers, system controls)
--   - provides client keys (per-window actions, movement, resizing)
--   - provides client mouse buttons (titlebar and window interactions)
-- 
-- key function categories passed to module:
--   - screen management: rotate_screens (keyboard + mouse via layout widget)
--   - tag navigation: move_to_previous/next_tag with optional follow
--   - ui toggles: tasklist mode, mode glyphs style, pavucontrol, arandr
--   - window actions: resize_no_warp (prevents cursor jumping)
--   - special clients: quake terminal dropdown
--   - tag cycling: cycle_tags_with_clients (maintains single source of truth)
--   - notifications: copy_last_notification to clipboard
-- 
-- registration:
--   - globalkeys: system-wide hotkeys
--   - clientkeys: per-client hotkeys (registered via modern API)
--   - clientbuttons: mouse button bindings for client windows


-- import keybindings from module
local keys = keybindings.build({
    modkey = modkey,
    terminal = terminal,
    rotate_screens = rotate_screens,
    move_to_previous_tag = move_to_previous_tag,
    move_to_next_tag = move_to_next_tag,
    move_to_previous_tag_and_follow = move_to_previous_tag_and_follow,
    move_to_next_tag_and_follow = move_to_next_tag_and_follow,
    toggle_tasklist_mode = toggle_tasklist_mode,
    -- mode glyphs toggle hotkey
    toggle_mode_glyphs_style = toggle_mode_glyphs_style,
    -- old: cycle_tags_with_clients used locally in module
    -- new: pass global implementation so there's a single source of truth
    cycle_tags_with_clients = cycle_tags_with_clients,
    copy_last_notification = copy_last_notification,
    toggle_notification_center = toggle_notification_center,
    toggle_tag_pager = toggle_tag_pager,
    clear_notification_history = clear_notification_history,
    notification_center_delete_oldest = notification_center_delete_oldest,
    -- pavucontrol toggle function
    toggle_pavucontrol = toggle_pavucontrol,
    -- keepassxc toggle function
    toggle_keepassxc = toggle_keepassxc,
    -- qbittorrent toggle function
    toggle_qbittorrent = toggle_qbittorrent,
    -- doublecmd toggle function
    toggle_doublecmd = toggle_doublecmd,
    -- arandr toggle function
    toggle_arandr = toggle_arandr,
    -- firefox toggle function
    toggle_firefox = toggle_firefox,
    -- custom resize function that prevents cursor warping
    resize_no_warp = resize_no_warp,
    -- quake terminal: expose toggle function for hotkey
    quake_toggle_lain = (function()
        -- instantiate lain quake dropdown
        local q = quake_lain({
            app = terminal,
            name = "QuakeLain",
            height = QUAKE_HEIGHT_SMALL,
            width = QUAKE_WIDTH_FULL,
            followtag = true,
        })
        return function() q:toggle() end
    end)(),
    -- dynamic UI zoom
    ui_scale_zoom_in = ui_scale.zoom_in,
    ui_scale_zoom_out = ui_scale.zoom_out,
    ui_scale_reset = ui_scale.reset,
    ui_scale_debounced_restart = ui_scale.debounced_restart,
    -- debounced restart for any reload trigger to prevent back-to-back hot-reload races
    debounced_restart = ui_scale.debounced_restart,
    -- screen brightness control (brightnessctl + OSD)
    brightness_increase = brightness.increase,
    brightness_decrease = brightness.decrease,
})


-- use the keybindings from the module
globalkeys = keys.globalkeys
clientkeys = keys.clientkeys
clientbuttons = keys.clientbuttons

-- register client keybindings properly for modern AwesomeWM
client.connect_signal("request::default_keybindings", function()
    awful.keyboard.append_client_keybindings(clientkeys)
end)




-- // MARK: dupe key check

-- check for duplicate hotkeys on startup and show orange notification
hotkey_dupe_detector.notify_duplicates(globalkeys, clientkeys)



-- compound terminal command for system monitoring
-- terminal_cmd = terminal .. " -e btop;" ..
--                terminal .. " -e journalctl -xeb;" ..
--                terminal .. " -e dmesg"




-- // MARK: wallpaper
-- ################################################################################
-- ██╗   ██╗██╗███████╗██╗   ██╗ █████╗ ██╗     
-- ██║   ██║██║██╔════╝██║   ██║██╔══██╗██║     
-- ██║   ██║██║███████╗██║   ██║███████║██║     
-- ╚██╗ ██╔╝██║╚════██║██║   ██║██╔══██║██║     
--  ╚████╔╝ ██║███████║╚██████╔╝██║  ██║███████╗
--   ╚═══╝  ╚═╝╚══════╝ ╚═════╝ ╚═╝  ╚═╝╚══════╝
-- ################################################################################
-- wallpaper management and configuration
-- define wallpaper function
-- old (X11): gears.wallpaper.maximized() — not available in somewm
-- new (Wayland): awful.wallpaper{} widget-based API with request::wallpaper signal
local function set_wallpaper(s)
    -- per-screen wallpaper: prefer beautiful.wallpapers[s.index] if provided
    if beautiful.wallpapers and beautiful.wallpapers[s.index] then
        awful.wallpaper {
            screen = s,
            widget = {
                image     = beautiful.wallpapers[s.index],
                upscale   = true,
                downscale = true,
                widget    = wibox.widget.imagebox,
            },
            valign = "center",
            halign = "center",
        }
        return
    end
    -- fallback to single wallpaper or function
    if beautiful.wallpaper then
        local wallpaper = beautiful.wallpaper
        -- if wallpaper is a function, call it with the screen
        if type(wallpaper) == "function" then
            wallpaper = wallpaper(s)
        end
        -- fill (cover) mode: crop image to screen aspect ratio, then stretch
        local sw, sh = s.geometry.width, s.geometry.height
        local surf = gears.surface.load(wallpaper)
        local cropped = gears.surface.crop_surface {
            surface = surf,
            ratio   = sw / sh,
        }
        awful.wallpaper {
            screen = s,
            widget = {
                image     = cropped,
                upscale   = true,
                downscale = true,
                widget    = wibox.widget.imagebox,
            },
        }
    end
end

-- Set wallpaper on startup and when screens change
screen.connect_signal("request::wallpaper", set_wallpaper)
-- NOTE: property::geometry is handled by awful.wallpaper module internally
-- (backgrounds[s]:repaint()). Connecting set_wallpaper here created duplicate
-- wallpaper objects on every kanshi profile switch, causing use-after-free
-- crashes when GC collected the old objects while C code still referenced them.



-- // MARK: LAYOUTS
-- ################################################################################
-- ██╗      █████╗ ██╗   ██╗ ██████╗ ██╗   ██╗████████╗
-- ██║     ██╔══██╗╚██╗ ██╔╝██╔═══██╗██║   ██║╚══██╔══╝
-- ██║     ███████║ ╚████╔╝ ██║   ██║██║   ██║   ██║   
-- ██║     ██╔══██║  ╚██╔╝  ██║   ██║╚██╗ ██╔╝   ██║   
-- ███████╗██║  ██║   ██║   ╚██████╔╝ ╚███╔╝    ██║   
-- ╚══════╝╚═╝  ╚═╝   ╚═╝    ╚═════╝   ╚══╝     ╚═╝   
-- ################################################################################
-- LAYOUT - layout management and navigation systems


-- NAVIGATION - Movement and collision detection
-- Navigation system using collision detection
require("collision") {
    -- Vim-style movement keys
    up    = { "k" },
    down  = { "j" },
    left  = { "h" },
    right = { "l" },

    -- Other configurations (commented out)
    -- Normal arrow keys
    -- up    = { "Up"    },
    -- down  = { "Down"  },
    -- left  = { "Left"  },
    -- right = { "Right" },

    -- Multiple key options
    -- up    = { "Up", "&", "k", "F15" },
    -- down  = { "Down", "KP_Enter", "j", "F14" },
    -- left  = { "Left", "#", "h", "F13" },
    -- right = { "Right", "\"", "l", "F17" },
}



-- Alt-Tab alternatives (disabled)
-- local switcher = require("awesome-switcher")
-- awful.key({ "Mod1" }, "Tab", function() switcher.switch(1, "Alt_L", "Tab", "ISO_Left_Tab") end)
-- awful.key({ "Mod1", "Shift" }, "Tab", function() switcher.switch(-1, "Alt_L", "Tab", "ISO_Left_Tab") end)


-- Alternative Alt-Tab implementation (disabled)
-- local alttab = require("gobo.awesome.alttab")
-- awful.key({ "Mod1" }, "Tab", function() alttab.switch(1, "Alt_L", "Tab", "ISO_Left_Tab") end,
--    { description = "Switch between windows", group = "awesome" })



-- MODULES - Additional layout and utility modules, layouts, widgets and utilities
-- local tyrannical = require("tyrannical")     -- Dynamic desktop tagging
-- require("tyrannical.shortcut")               -- Optional tyrannical shortcuts
-- local revelation = require("revelation")     -- App/desktop switching script
-- revelation.init()



-- LAYOUTS - Layout definitions and configuration
-- Active layout scripts

-- Custom adaptive layout
-- local centerwork_adaptive = require("lain.layout.centerwork_adaptive")
-- Custom two-thirds layout that gives new window 2/3 screen
-- local centerwork_twothirds = require("lain.layout.centerwork_twothirds")
-- Custom tile.bottom layout with enhanced mouse resize functionality
-- removed: tile_bottom_mouse require (unused)


-- LAYOUT DEFINITIONS
-- Table of layouts to cover with awful.layout.inc, order matters.
-- https://awesomewm.org/doc/api/libraries/awful.layout.html
-- https://github.com/lcpz/lain/wiki/Layouts


-- awful.layout.layouts = {}



-- // MARK: -- layout-definitions
-- new: handle default layouts by assigning the exact curated subset
-- somewm emits request::default_layouts on the tag object (capi.tag), not on
-- awesome, so connect there or the handler never fires and the fallback list is used
tag.connect_signal("request::default_layouts", function()
    -- assert only these layouts are available (not a superset)
    -- using append_default_layouts because direct assignment to
    -- awful.layout.layouts triggers a double-disconnect bug in somewm's
    -- awful/layout/init.lua __newindex metamethod; default_layouts is
    -- empty at this point so appending yields exactly this curated subset
    awful.layout.append_default_layouts({
        -- active layouts in preferred order
        vstack,                              -- single-column vertical (master on top, slaves below)
        lain.layout.threefifths,                       -- primary: adaptive 3/5 for focused window
        -- centerwork_twothirds.horizontal,            -- custom: two-thirds for new window
        -- centerwork_adaptive.horizontal,             -- custom: adaptive centerwork horizontal
        awful.layout.suit.magnifier,
        lain.layout.centerwork.horizontal,
        lain.layout.termfair.center,
        awful.layout.suit.fair.horizontal,
        awful.layout.suit.max,
        awful.layout.suit.carousel,
        awful.layout.suit.spiral,                -- recommended: fibonacci spiral layout
        awful.layout.suit.tile.top,
        awful.layout.suit.tile.bottom,
        awful.layout.suit.tile,
        -- awful.layout.suit.tile.left,
        -- tile_bottom_mouse,                          -- custom: enhanced tile.bottom with mouse resize
        -- bling.layout.horizontal,          -- optional: horizontal master layout  
        -- awful.layout.suit.corner.ne,
        -- awful.layout.suit.corner.nw,
        treetile,
        bling.layout.equalarea,              -- recommended: equal area distribution
        bling.layout.mstab,                  -- highly recommended: master-slave tabbing
        -- bling.layout.vertical,            -- optional: vertical master layout
        -- lain.layout.centerwork,
        -- lain.layout.termfair,
        bling.layout.deck,                   -- optional: deck-style stacking layout
        lain.layout.cascade                 -- recommended: beautiful cascading windows
        -- awful.layout.suit.floating,
        -- bling.layout.centered,
        -- awful.layout.suit.corner.nw,
        -- awful.layout.suit.corner.ne,
        -- awful.layout.suit.spiral.dwindle,
        -- awful.layout.suit.max.fullscreen,
        -- leaved.layout.suit.tile.right,
        -- leaved.layout.suit.tile.left,
        -- leaved.layout.suit.tile.top,
        -- trizen,
        -- dovetail.layout.right,
        -- dynamite.layout.conditional,
        -- dynamite.layout.ratio,
        -- dynamite.layout.stack,
        -- dynamite.layout.tabbed
    })
end)


-- now that custom layouts are loaded, set preferred default
-- overrides the temporary safe default set earlier
-- milkdefault = lain.layout.threefifths
milkdefault = vstack



-- // MARK: WIDGETS
-- ################################################################################
-- ██╗    ██╗██╗██████╗  ██████╗ ███████╗████████╗███████╗
-- ██║    ██║██║██╔══██╗██╔════╝ ██╔════╝╚══██╔══╝██╔════╝
-- ██║ █╗ ██║██║██║  ██║██║  ███╗█████╗     ██║   ███████╗
-- ██║███╗██║██║██║  ██║██║   ██║██╔══╝     ██║   ╚════██║
-- ╚███╔███╔╝██║██████╔╝╚██████╔╝███████╗   ██║   ███████║
--  ╚══╝╚══╝ ╚═╝╚═════╝  ╚═════╝ ╚══════╝   ╚═╝   ╚══════╝
-- ################################################################################
-- WIDGETS - menus, widgets, and interface elements


-- Restore previous clock style: Hack font, white on purple, with right margin
local mytextclock = wibox.widget.textclock()
mytextclock.format = "%a %b %d %H:%M"
mytextclock.font = "Hack Nerd Font 11"

local textclock_clr = wibox.container.background()
-- add at least 4px of purple padding on both sides
textclock_clr:set_widget(wibox.container.margin(mytextclock, CLOCK_MARGIN, CLOCK_MARGIN, 0, 0))
textclock_clr:set_fg("#ffffff")
textclock_clr:set_bg("#623997")
textclock_clr:set_border_width(0)



-- // MARK: --menu


-- Create the awesome submenu contents
awesomesubmenu = {
    -- {"Hotkeys", function() hotkeys_popup.show_help(nil, awful.screen.focused()) end},
    {"Hotkeys", function() hotkeys_popup.show_help(nil, mouse.screen) end},
    {"Manual", terminal .. " -e man awesome"},
    {"Edit config", editor_cmd .. " " .. awesome.conffile},
    {"Restart", function() (ui_scale.debounced_restart or awesome.restart)() end},
    {"Quit", function() awesome.quit() end}
}


-- Build the main menu with the submenu, app launcher, and terminal entry
mymainmenu = freedesktop.menu.build({
    before = {
        {"Awesome", awesomesubmenu, beautiful.awesome_icon}
        -- other triads can be put here
    },
    after = {
        {"Terminal", terminal}
        -- other triads can be put here
    }
})

-- -- Pre-populate the menu once at startup to avoid a pause on first open
-- gears.timer.delayed_call(function()
--     if mymainmenu then
--         mymainmenu:show({ coords = { x = -10000, y = -10000 } })
--         mymainmenu:hide()
--     end
-- end)


-- Create a launcher widget and a main menu
mylauncher = awful.widget.launcher({
    image = "/home/milkii/.config/somewm/milktheme/icons/awesome-logo.svg",
    menu = mymainmenu
})


-- local media_player = require("media-player")




-- ========================================================================
-- PLUGIN INTEGRATION
-- ========================================================================
-- load self-contained plugins (logical order: dependencies first)


local tag_indicators = require("plugins.tag_indicators")
local dnd_to_tag = require("plugins.dnd_to_tag")
-- border animation now integrated into shimmer system

-- removed: unused shimmering text launcher





-- // MARK: --taglist
-- taglist button mouse bindings
local taglist_buttons = gears.table.join(
    awful.button({ }, 1, function(t) t:view_only() end),
    awful.button({ modkey }, 1, function(t)
        if client.focus then
            client.focus:move_to_tag(t)
        end
    end),
    awful.button({ }, 3, awful.tag.viewtoggle),
    awful.button({ modkey }, 3, function(t)
        if client.focus then
            client.focus:toggle_tag(t)
        end
    end), 
    -- mousewheel up: cycle to previous tag with clients
    awful.button({ }, 4, function(t)
        cycle_tags_with_clients("prev")
    end),
    -- mousewheel down: cycle to next tag with clients  
    awful.button({ }, 5, function(t)
        cycle_tags_with_clients("next")
    end),
    -- shift + mousewheel up: cycle to previous tag with visible clients only
    awful.button({ "Shift" }, 4, function(t) 
        cycle_tags_with_visible_clients("prev")
    end),
    -- shift + mousewheel down: cycle to next tag with visible clients only
    awful.button({ "Shift" }, 5, function(t) 
        cycle_tags_with_visible_clients("next")
    end)
)


-- // MARK: --tasklist
-- tasklist button mouse bindings


-- // MARK: --mousewheel-client-cycling-functions
-- cycle through clients on the current tag only (normal mousewheel)
local function cycle_clients_on_tag(direction)
    local current_tag = awful.screen.focused().selected_tag
    if not current_tag then return end
    
    local clients = current_tag:clients()
    if #clients <= 1 then return end
    
    local current_client = client.focus
    if not current_client then
        clients[1]:emit_signal("request::activate", "tasklist", {raise = true})
        return
    end
    
    -- find current client index
    local current_index = nil
    for i, c in ipairs(clients) do
        if c == current_client then
            current_index = i
            break
        end
    end
    
    if not current_index then
        clients[1]:emit_signal("request::activate", "tasklist", {raise = true})
        return
    end
    
    -- calculate next client index
    local next_index
    if direction == 1 then -- forward
        next_index = current_index % #clients + 1
    else -- backward
        next_index = (current_index - 2) % #clients + 1
    end
    
    -- activate next client
    clients[next_index]:emit_signal("request::activate", "tasklist", {raise = true})
end

-- cycle through clients with only one visible (mod4 + mousewheel)
local function cycle_clients_exclusive(direction)
    local current_tag = awful.screen.focused().selected_tag
    if not current_tag then return end
    
    local clients = current_tag:clients()
    if #clients <= 1 then return end
    
    local current_client = client.focus
    if not current_client then
        -- minimize all except first
        for i, c in ipairs(clients) do
            if i == 1 then
                c.minimized = false
                c:emit_signal("request::activate", "tasklist", {raise = true})
            else
                c.minimized = true
            end
        end
        return
    end
    
    -- find current client index
    local current_index = nil
    for i, c in ipairs(clients) do
        if c == current_client then
            current_index = i
            break
        end
    end
    
    if not current_index then
        return
    end
    
    -- calculate next client index
    local next_index
    if direction == 1 then -- forward
        next_index = current_index % #clients + 1
    else -- backward
        next_index = (current_index - 2) % #clients + 1
    end
    
    -- minimize all clients except the next one
    for i, c in ipairs(clients) do
        if i == next_index then
            c.minimized = false
            c:emit_signal("request::activate", "tasklist", {raise = true})
        else
            c.minimized = true
        end
    end
end

local tasklist_buttons = gears.table.join(
    awful.button({ }, 1, function (c)
        -- if client is on a tag that isn't currently viewed, switch to it first
        local s = c.screen
        local selected_tags = s and s.selected_tags or {}
        local on_selected = false
        for _, ct in ipairs(c:tags()) do
            for _, st in ipairs(selected_tags) do
                if ct == st then on_selected = true; break end
            end
            if on_selected then break end
        end
        if not on_selected then
            -- view the client's first tag
            local ctags = c:tags()
            if ctags and #ctags > 0 then
                ctags[1]:view_only()
            end
        end
        -- toggle minimize/restore
        if c.minimized then
            c.minimized = false
            c:emit_signal(
                "request::activate",
                "tasklist",
                {raise = true}
            )
        else
            c.minimized = true
        end
    end),
    awful.button({ }, 2, function (c)
        c.minimized = true
    end),
    awful.button({ }, 3, function(c)
        -- KDE-style per-client context menu
        local name = c.name or c.class or "client"
        if #name > 40 then name = name:sub(1, 37) .. "..." end

        local function toggle_label(prop, on_lbl, off_lbl)
            return (c[prop] and off_lbl or on_lbl)
        end

        -- build move-to-tag submenu
        local tag_items = {}
        local s = c.screen or awful.screen.focused()
        if s then
            for _, t in ipairs(s.tags) do
                local is_on = false
                for _, ct in ipairs(c:tags()) do
                    if ct == t then is_on = true; break end
                end
                tag_items[#tag_items + 1] = {
                    (is_on and "[x] " or "[  ] ") .. (t.name or tostring(t.index)),
                    function()
                        if is_on then c:tags_remove({ t })
                        else c:tags_add({ t }) end
                    end
                }
            end
        end

        local menu_items = {
            { "Close", function() c:kill() end },
            { "Minimize", function() c.minimized = not c.minimized end },
            { toggle_label("maximized", "Maximize", "Unmaximize"), function() c.maximized = not c.maximized end },
            { toggle_label("fullscreen", "Fullscreen", "Unfullscreen"), function() c.fullscreen = not c.fullscreen end },
            { toggle_label("floating", "Float", "Tile"), function() c.floating = not c.floating end },
            { toggle_label("ontop", "Set On Top", "Unset On Top"), function() c.ontop = not c.ontop end },
            { toggle_label("sticky", "Set Sticky", "Unset Sticky"), function() c.sticky = not c.sticky end },
            { "Move to Tag", tag_items },
        }

        local ctx_menu = awful.menu({
            items = menu_items,
            theme = { width = 200 },
        })
        ctx_menu:show({ coords = { x = mouse.coords().x, y = mouse.coords().y } })

        -- dismiss on outside click: use a mousegrabber that hides the menu
        -- on any button press, then stops itself
        mousegrabber.run(function(m)
            if m.buttons[1] or m.buttons[3] then
                ctx_menu:hide()
                return false
            end
            return true
        end, "arrow")
    end),
    -- mousewheel up: cycle forward through clients on current tag
    awful.button({ }, 4, function ()
        cycle_clients_on_tag(1)
    end),
    -- mousewheel down: cycle backward through clients on current tag
    awful.button({ }, 5, function ()
        cycle_clients_on_tag(-1)
    end),
    -- mod4 + mousewheel up: cycle forward with exclusive visibility
    awful.button({ modkey }, 4, function ()
        cycle_clients_exclusive(1)
    end),
    -- mod4 + mousewheel down: cycle backward with exclusive visibility
    awful.button({ modkey }, 5, function ()
        cycle_clients_exclusive(-1)
    end)
)




-- // MARK: --screen


-- apply wallpaper and create widgets for each screen
awful.screen.connect_for_each_screen(function(s)
    -- wallpaper
    set_wallpaper(s)

    -- {{{ Quake Terminal (Dropdown Console)
    -- A Quake-style dropdown terminal that can be toggled with a hotkey
    -- Hotkey: Mod4 + ` (backtick) - Toggle the terminal
    -- Features:
    -- - Slides down from the top of the screen
    -- - Follows the current tag when switching workspaces
    -- - Auto-hides when losing focus
    -- - Can be configured with different terminals via the 'app' parameter
    s.quake = lain.util.quake(
        -- Terminal configuration
        {
            app = terminal,  -- alacritty runs directly
            argname = "--class %s",  -- alacritty uses --class for window identity
            name = "QuakeTerminal",  -- Window name for matching in window rules
            height = QUAKE_HEIGHT_LARGE,     -- Height as percentage of screen (0.0 to 1.0)
            width = QUAKE_WIDTH_FULL,      -- Width as percentage of screen (0.0 to 1.0)
            horiz = "center", -- Horizontal position ("left", "center", "right")
            vert = "top",     -- Vertical position ("top", "center", "bottom")
            border = 2,       -- Border width in pixels
            followtag = true, -- Follow the current tag
            overlap = false,  -- Whether to overlap the wibox
            visible = false,  -- Start hidden
            screen = s        -- Screen to display on
        },
        -- Additional settings
        {
            settings = function(c)
                c.followtag = true  -- Make terminal follow tag changes
                c.sticky = true     -- Keep terminal on all tags
                c.ontop = true      -- Keep terminal above other windows
                c.above = true      -- Keep terminal above normal windows
                c.skip_taskbar = true  -- Don't show in taskbar
                c.urgent = false    -- Don't set urgent flag
            end
        }
    )

    -- each screen has its own tag table
    -- old: used first layout in global list (order can vary if modules append)
    -- awful.tag({ "1", "2", "3", "4", "5", "6", "7", "8", "9", "0", "-", "="}, s, awful.layout.layouts[1])
    awful.tag({ "1", "2", "3", "4", "5", "6", "7", "8", "9", "0", "-", "="}, s, milkdefault)

    -- create a promptbox for each screen
    s.mypromptbox = awful.widget.prompt()

    -- create an imagebox widget which will contain an icon indicating which layout we're using
    s.mylayoutbox = awful.widget.layoutbox(s)
    s.mylayoutbox:buttons(gears.table.join(
                           awful.button({ }, 1, function () awful.layout.inc(-1) end),
                           awful.button({ }, 3, function () awful.layout.inc( 1) end),
                           awful.button({ }, 2, function ()
                               local t = s.selected_tag
                               if not t then return end
                               local cur = awful.layout.get(s)
                               local items = {}
                               for _, l in ipairs(awful.layout.layouts) do
                                   local name = l.name or "?"
                                   local label = (l == cur) and ("[" .. name .. "]") or name
                                   local icon = beautiful["layout_" .. name]
                                   table.insert(items, { label, function() awful.layout.set(l, t) end, icon })
                               end
                               local m = awful.menu({
                                   items = items,
                                   theme = {
                                       height = 28,
                                       width = 200,
                                       font = "Hack Nerd Font 11",
                                   },
                               })
                               m:show({ coords = mouse.coords() })
                               -- outside-click detection (same pattern as tag_pager popup)
                               local m_ref = m
                               local client_handler = function()
                                   if m_ref.wibox and m_ref.wibox.visible then m_ref:hide() end
                               end
                               client.connect_signal("button::press", client_handler)
                               local wibar_handlers = {}
                               for sc in screen do
                                   if sc.mywibox then
                                       local wh = function()
                                           if m_ref.wibox and m_ref.wibox.visible then m_ref:hide() end
                                       end
                                       sc.mywibox:connect_signal("button::press", wh)
                                       table.insert(wibar_handlers, { wibox = sc.mywibox, handler = wh })
                                   end
                               end
                               -- clean up handlers when menu hides
                               local orig_hide = m_ref.hide
                               m_ref.hide = function(self)
                                   client.disconnect_signal("button::press", client_handler)
                                   for _, entry in ipairs(wibar_handlers) do
                                       entry.wibox:disconnect_signal("button::press", entry.handler)
                                   end
                                   orig_hide(self)
                               end
                           end),
                           awful.button({ }, 4, function () awful.layout.inc( 1) end),
                           awful.button({ }, 5, function () awful.layout.inc(-1) end),
                           awful.button({ modkey }, 4, function () rotate_screens("right") end),
                           awful.button({ modkey }, 5, function () rotate_screens("left") end)))
    
    -- // MARK: --taglist
    -- create a taglist widget
    s.mytaglist = awful.widget.taglist {
        screen  = s,
        filter  = awful.widget.taglist.filter.all,
        buttons = taglist_buttons,
        style = {
            -- enable built-in squares; plugin remaps them to unminimised-client state
            bg_focus = beautiful.taglist_bg_focus,
            bg_occupied = nil,
            -- keep squares defined so they render
            squares_sel = beautiful.taglist_squares_sel,
            squares_unsel = beautiful.taglist_squares_unsel,
        },
        widget_template = {
            {
                {
                    {
                        id = 'text_role',
                        widget = wibox.widget.textbox,
                    },
                    left = TAGLIST_MARGIN_H,
                    right = TAGLIST_MARGIN_H,
                    top = TAGLIST_MARGIN_V,
                    bottom = TAGLIST_MARGIN_V,
                    widget = wibox.container.margin,
                },
                layout = wibox.layout.fixed.horizontal,
            },
            id = 'background_role',
            widget = wibox.container.background,
            create_callback = function(self, t, index, objects)
                local text_widget = self:get_children_by_id('text_role')[1]
                if text_widget and t then
                    -- shimmer: register + wire hover via module helper
                    shimmer.register_taglist(self, s.index, t)
                    shimmer.attach_tag_hover(self, t)
                end
            end
            ,
            update_callback = function(self, t, index, objects)
                local text_widget = self:get_children_by_id('text_role')[1]
                if text_widget and t then
                    -- taglist update handled automatically by shimmer
                end
            end
        }
    }



    -- // MARK: --tasklist
    -- completely standard tasklist - no custom templates or overrides
    -- let the standard system handle all functionality properly:
    -- • terminal icons with proper fallbacks
    -- • underscore handling for minimized clients  
    -- • status indicators and client state management
    --
    -- separate enhancement modules (like shimmer) will integrate via signals
    -- rather than trying to modify the core widget structure
    s.mytasklist = awful.widget.tasklist {
        screen  = s,
        disable_icon = false,
        -- removed: tasklist_disable_icon (unknown property)
        source = function()
            local clients = {}
            for _, c in ipairs(client.get()) do
                table.insert(clients, c)
            end
            -- reverse the order so newest clients appear on the right
            local reversed = {}
            for i = #clients, 1, -1 do
                table.insert(reversed, clients[i])
            end
            return reversed
        end,
        filter  = function(c, screen)
            if not c or not c.valid or c.screen ~= screen then
                return false
            end
            
            -- if showing all tags, return true for all valid clients on this screen
            if tasklist_show_all_tags then
                return true
            end
            
            -- default behavior: show clients from all selected tags (not just the first one)
            local selected_tags = screen.selected_tags
            if not selected_tags or #selected_tags == 0 then 
                return false 
            end
            
            -- check if client is on any of the selected tags
            for _, client_tag in ipairs(c:tags()) do
                for _, selected_tag in ipairs(selected_tags) do
                    if client_tag == selected_tag then
                        return true
                    end
                end
            end
            
            return false
        end,
        buttons = tasklist_buttons,
        style = {
            disable_icon = false,
            font = "Hack Nerd Font 11",
            bg_normal   = TASKLIST_BG_OFFSCREEN,  -- default black; callback overrides for visible
            bg_focus    = TASKLIST_BG_VISIBLE,    -- focused
            bg_minimize = TASKLIST_BG_OFFSCREEN,  -- minimized
            bg_urgent   = TASKLIST_BG_VISIBLE,
        },
        layout   = {
            spacing = 1,
            layout = wibox.layout.flex.horizontal
        },
        -- robust template: always provide an icon widget + split prefix/title
        widget_template = {
            {
                {
                    widget = wibox.container.place,
                    halign = 'left',
                    valign = 'center',
                    {
                        layout = wibox.layout.fixed.horizontal,
                        spacing = 1,
                        { id = 'icon_role', widget = wibox.widget.imagebox, resize = true },
                        {
                            layout = wibox.layout.fixed.horizontal,
                            spacing = 1,
                            {
                                id = 'status_prefix_margin',
                                widget = wibox.container.margin,
                                left = 2, right = 1, top = 0, bottom = 0,
                                {
                                    id = 'status_prefix',
                                    widget = wibox.widget.textbox,
                                }
                            },
                            { id = 'text_role', widget = wibox.widget.textbox },
                        },
                    },
                },
                left  = TASKLIST_MARGIN_LEFT,
                right = TASKLIST_MARGIN_RIGHT,
                widget  = wibox.container.margin,
            },
            id     = 'background_role',
            widget = wibox.container.background,
            create_callback = function(self, c, index, objects)
                local ib = self:get_children_by_id('icon_role')[1]
                if ib then
                    local sz = (beautiful and (beautiful.tasklist_icon_size or beautiful.icon_size)) or DEFAULT_ICON_SIZE
                    ib.forced_height = sz
                    ib.forced_width = sz
                    if FORCE_GENERIC_ICONS and GENERIC_ICON_PATH and gears.filesystem.file_readable(GENERIC_ICON_PATH) then
                        ib.image = gears.surface.load_uncached(GENERIC_ICON_PATH)
                    elseif not c.icon then
                        local surf = get_fallback_icon and get_fallback_icon(c)
                        if surf then ib.image = surf end
                    end
                end
                -- dim clients not on any selected tag
                local s = c.screen
                local on_selected = false
                if s then
                    local sel_tags = s.selected_tags or {}
                    for _, ct in ipairs(c:tags()) do
                        for _, st in ipairs(sel_tags) do
                            if ct == st then on_selected = true; break end
                        end
                        if on_selected then break end
                    end
                end
                -- purple only when the app is actually visible on screen
                -- delayed_call: re-apply after common.list_update overwrites self.bg
                local visible = on_selected and not c.minimized
                gears.timer.delayed_call(function()
                    self.bg = visible and TASKLIST_BG_VISIBLE or TASKLIST_BG_OFFSCREEN
                end)
                mode_glyphs.apply(self, c)
                -- shimmer: centralize safety colorization
                shimmer.apply_tasklist_safety(self, c)
                -- ensure shimmer protection and initial application happen at creation
                if shimmer and shimmer.tasklist_update_callback then
                    shimmer.tasklist_update_callback(self, c, index, objects)
                end
            end,
            update_callback = function(self, c, index, objects)
                local ib = self:get_children_by_id('icon_role')[1]
                if ib then
                    local sz = (beautiful and (beautiful.tasklist_icon_size or beautiful.icon_size)) or DEFAULT_ICON_SIZE
                    ib.forced_height = sz
                    ib.forced_width = sz
                    if not c.icon or ib.image == nil then
                        local surf = get_fallback_icon and get_fallback_icon(c)
                        if surf then ib.image = surf end
                    end
                end
                -- dim clients not on any selected tag
                local s = c.screen
                local on_selected = false
                if s then
                    local sel_tags = s.selected_tags or {}
                    for _, ct in ipairs(c:tags()) do
                        for _, st in ipairs(sel_tags) do
                            if ct == st then on_selected = true; break end
                        end
                        if on_selected then break end
                    end
                end
                -- purple only when the app is actually visible on screen
                -- delayed_call: re-apply after common.list_update overwrites self.bg
                local visible = on_selected and not c.minimized
                gears.timer.delayed_call(function()
                    self.bg = visible and TASKLIST_BG_VISIBLE or TASKLIST_BG_OFFSCREEN
                end)
                mode_glyphs.update(self, c)
                -- shimmer: centralize safety colorization
                shimmer.apply_tasklist_safety(self, c)
                shimmer.tasklist_update_callback(self, c, index, objects)
            end,
        }
    }
    
    -- register tasklist with shimmer
    shimmer.register_tasklist(s.mytasklist)


    -- // MARK: --wibox
    -- create the wibox
    s.mywibox = awful.wibar({ position = "top", screen = s, height = 32 })

    -- add widgets to the wibox
    -- create systray with base size from theme
    local mysystray = wibox.widget.systray()
    if mysystray.set_base_size then
        local tray_size = (beautiful and (beautiful.systray_icon_size or beautiful.icon_size)) or 16
        mysystray:set_base_size(tray_size)
    end
    if mysystray.set_spacing then
        mysystray:set_spacing(6)
    end
    local notification_toggle_widget = notification_center.create_toggle_widget()
    local tag_pager_widget = tag_pager.create_pager_widget(s, 32)

    -- brightness widget: icon + percentage, scroll to adjust
    local brightness_icon = wibox.widget {
        image = "/usr/share/icons/Adwaita/symbolic/status/display-brightness-symbolic.svg",
        forced_width = 14,
        forced_height = 14,
        resize = true,
        widget = wibox.widget.imagebox,
    }
    local brightness_text = wibox.widget {
        text = "100%",
        align = "center",
        valign = "center",
        widget = wibox.widget.textbox,
    }
    local brightness_widget = wibox.widget {
        {
            brightness_icon,
            {
                brightness_text,
                left = 2,
                widget = wibox.container.margin,
            },
            layout = wibox.layout.fixed.horizontal,
            spacing = 2,
        },
        left = 2, right = 2,
        widget = wibox.container.margin,
    }
    brightness_widget:buttons(gears.table.join(
        awful.button({}, 4, function() brightness.increase() end),
        awful.button({}, 5, function() brightness.decrease() end)
    ))
    -- poll brightness every 2 seconds for external changes
    local function update_brightness_widget()
        awful.spawn.easy_async("brightnessctl -m info", function(out)
            local pct = out and out:match(",(%d+)%%")
            if pct then brightness_text.text = pct .. "%" end
        end)
    end
    gears.timer.start_new(2, function()
        update_brightness_widget()
        return true
    end)
    update_brightness_widget()

    -- battery widget: icon + percentage, reads /sys/class/power_supply/BAT0
    -- (cbatticon and xfce4-power-manager both use GtkStatusIcon/XEmbed which
    --  has no host on somewm's SNI-only systray, so a native widget is used)
    local bat_icon_dir = "/usr/share/icons/Adwaita/symbolic/status/"
    local bat_icon = wibox.widget {
        image = bat_icon_dir .. "battery-level-100-symbolic.svg",
        forced_width = 14,
        forced_height = 14,
        resize = true,
        widget = wibox.widget.imagebox,
    }
    local bat_text = wibox.widget {
        text = "100%",
        align = "center",
        valign = "center",
        widget = wibox.widget.textbox,
    }
    local battery_widget = wibox.widget {
        {
            bat_icon,
            {
                bat_text,
                left = 2,
                widget = wibox.container.margin,
            },
            layout = wibox.layout.fixed.horizontal,
            spacing = 2,
        },
        left = 2, right = 2,
        widget = wibox.container.margin,
    }
    local function update_battery_widget()
        local cap_f = io.open("/sys/class/power_supply/BAT0/capacity", "r")
        local sts_f = io.open("/sys/class/power_supply/BAT0/status", "r")
        if not cap_f or not sts_f then
            if cap_f then cap_f:close() end
            if sts_f then sts_f:close() end
            return
        end
        local pct = tonumber(cap_f:read("*l")) or 0
        local status = sts_f:read("*l") or "Unknown"
        cap_f:close()
        sts_f:close()
        local level = math.floor(pct / 10) * 10
        if level > 100 then level = 100 end
        local suffix
        if status == "Charging" then
            suffix = level .. "-charging"
        elseif status == "Full" then
            suffix = "100-charged"
        elseif status == "Not charging" then
            suffix = level .. "-plugged-in"
        else
            suffix = level
        end
        bat_icon:set_image(bat_icon_dir .. "battery-level-" .. suffix .. "-symbolic.svg")
        bat_text.text = pct .. "%"
    end
    gears.timer.start_new(5, function()
        update_battery_widget()
        return true
    end)
    update_battery_widget()

    -- media launcher button (bluetooth/wifi/battery/clipboard handled by SNI tray applets)
    local media_btn = wibox.widget {
        image = "/usr/share/icons/Adwaita/symbolic/devices/audio-card-symbolic.svg",
        forced_width = 16,
        forced_height = 16,
        resize = true,
        widget = wibox.widget.imagebox,
    }
    media_btn:connect_signal("button::press", function(_, _, _, button)
        if button == 1 then
            awful.spawn.with_shell("playerctl play-pause 2>/dev/null || true")
        end
    end)

    -- previous notification center widget creation: none

    s.mywibox:setup {
        layout = wibox.layout.align.horizontal,
        { -- left widgets
            layout = wibox.layout.fixed.horizontal,
            mylauncher,
            wibox.container.background(
                wibox.container.margin(tag_pager_widget, 1, 1, 0, 0),
                "#000000"
            ),
            s.mypromptbox,
        },
        { -- middle widgets (tasklist expands to fill space)
            layout = wibox.layout.align.horizontal,
            wibox.container.background(
                wibox.container.margin(s.mylayoutbox, 0, 1, 0, 0),
                "#000000"
            ), -- should be to the left of tasklist
            s.mytasklist, -- this will expand to fill available space
        },
        { -- right widgets
            layout = wibox.layout.fixed.horizontal,
            -- brightness indicator (scroll to adjust)
            wibox.container.margin(brightness_widget, 2, 2, 0, 0),
            -- battery indicator (native widget; no SNI battery tray applet available)
            wibox.container.margin(battery_widget, 2, 2, 0, 0),
            -- add 3px horizontal + 1px top padding to systray and center vertically (only on primary screen)
            -- SNI tray applets (nm-applet, blueman-applet) appear here
            s == screen.primary and wibox.container.margin({ mysystray, valign = "center", widget = wibox.container.place }, 4, 0, 0, 0) or wibox.container.margin({ mysystray, valign = "center", widget = wibox.container.place }, 1, 0, 0, 0),
            -- launcher buttons for CLI-only tools
            wibox.container.margin(media_btn, 2, 0, 0, 0),
            -- previous notification center widgets: none
            wibox.container.margin(notification_toggle_widget, 1, 0, 0, 0),
            wibox.container.margin(textclock_clr, 0, 0, 0, 0)
        },
    }



    -- // MARK: altwibox
    -- the alt wibox
    s.myaltwibox = awful.wibar({
        position = "top",
        screen = s,
        height = 32,
        visible = false
    })

    -- Add widgets to the wibox
    s.myaltwibox:setup{
        layout = wibox.layout.align.horizontal,
        expand = "none",
        {
            -- Left widgets
            layout = wibox.layout.fixed.horizontal
        },
        -- Middle widget
        -- media_player2,
        {
            -- Right widgets
            layout = wibox.layout.fixed.horizontal
        }
    }

    -- desktop icons (freedesktop) per screen
    -- local desktop = require("freedesktop.desktop")
    -- desktop.add_icons({ screen = s, dir = os.getenv("HOME") .. "/Desktop", showlabel = true, open_with = "xdg-open" })
end)




-- // MARK: clients
-- ################################################################################
--  ██████╗██╗     ██╗███████╗███╗   ██╗████████╗
-- ██╔════╝██║     ██║██╔════╝████╗  ██║╚══██╔══╝
-- ██║     ██║     ██║█████╗  ██╔██╗ ██║   ██║   
-- ██║     ██║     ██║██╔══╝  ██║╚██╗██║   ██║   
-- ╚██████╗███████╗██║███████╗██║ ╚████║   ██║   
--  ╚═════╝╚══════╝╚═╝╚══════╝╚═╝  ╚═══╝   ╚═╝   
-- ################################################################################
-- client management - creation, properties, signals, and behaviors


-- // MARK: --client-creation




-- Client creation and setup
-- somewm 2.0: "manage" renamed to "request::manage"
client.connect_signal("request::manage", function(c)
    -- Set client window shapes
    c.shape = function(cr, w, h)
        -- guard missing theme var
        gears.shape.rounded_rect(cr, w, h, beautiful.border_radius or 0)
    end

    -- old: only set fallback when the client had no icon
    -- if not c.icon then
    --     local fallback_icon = "/usr/share/icons/Adwaita/symbolic/legacy/utilities-terminal-symbolic.svg"
    --     if gears.filesystem.file_readable(fallback_icon) then
    --         c.icon = gears.surface.load_uncached(fallback_icon)
    --     end
    -- end

    -- set fallback icon when client has no icon
    if not c.icon then
        local surf = get_fallback_icon(c)
        if surf then c.icon = surf end
    end
    
    -- Set the windows at the slave,
    -- i.e. put it at the end of others instead of setting it master.
    -- if not awesome.startup then awful.client.setslave(c) end
    
    if awesome.startup
      and not c.size_hints.user_position
      and not c.size_hints.program_position then
        -- Prevent clients from being unreachable after screen count changes.
        awful.placement.no_offscreen(c)
    end
    
    -- store initial size for auto-resize when becoming floating
    -- this captures the tiled size when client is first managed
    if not c.floating then
        local geo = c:geometry()
        if geo.width > 0 and geo.height > 0 then
            client_tiled_sizes[c] = {
                width = geo.width,
                height = geo.height
            }
        end
    end
end)

-- // MARK: --titlebar-management
-- double-click handler for titlebar (per-client, weak-keyed)
local double_click_timers = setmetatable({}, { __mode = "k" })  -- weak keys prevent memory leaks
local function titlebar_handle_click(c, single_cb, double_cb, interval)
    interval = interval or DOUBLE_CLICK_INTERVAL
    local t = double_click_timers[c]
    if t then
        if t.started then t:stop() end
        double_click_timers[c] = nil
        if double_cb then double_cb() end
    else
        t = gears.timer {
            timeout = interval,
            autostart = true,
            single_shot = true,
            callback = function()
                double_click_timers[c] = nil
                if single_cb then single_cb() end
            end
        }
        double_click_timers[c] = t
    end
end

-- titlebars disabled for now; the request::titlebars handler is preserved
-- below commented out so it can be re-enabled easily.
--[[
client.connect_signal("request::titlebars", function(c)
    -- unified icon size from theme
    local icon_size = (beautiful and beautiful.icon_size) or DEFAULT_ICON_SIZE

    -- buttons for the titlebar
    -- MARK: --titlebar-buttons
    local buttons = gears.table.join(
        -- left click: single = move, double = toggle floating
        awful.button({ }, 1, function()
            titlebar_handle_click(c,
                function()
                    -- old (commented): immediate activate+move without guarding intention
                    -- c:emit_signal("request::activate", "titlebar", {raise = true})
                    -- awful.mouse.client.move(c)

                    -- prepare drag intention and temporarily unmaximize if needed
                    c._intend_drag = true
                    if c.maximized then
                        c._was_maximized = true
                        c.maximized = false
                    end
                    c:emit_signal("request::activate", "titlebar", {raise = true})
                    awful.mouse.client.move(c)
                end,
                function()
                    c.floating = not c.floating
                    c:raise()
                end
            )
        end),
        -- middle click minimises client
        awful.button({ }, 2, function()
            c.minimized = true
        end),
        -- right click resizes client
        awful.button({ }, 3, function()
            c:emit_signal("request::activate", "titlebar", {raise = true})
            awful.mouse.client.resize(c)
        end)
    )

    -- MARK: --titlebar-text
    local titlebar_text_widget = wibox.widget.textbox()
    titlebar_text_widget.font = "Hack Nerd Font 6"
    
    -- create a right-side gradient that fades from transparent to purple (reverse of middle)
    local titlebar_right_gradient = {
        type = "linear",
        from = { 0, 0 },
        to = { 200, 0 },  -- approximate width for button area
        stops = {
            { 0, beautiful.main_purple.focusend },    -- purple, transparent (start)
            { 0.3, beautiful.main_purple.focusend },  -- purple, transparent
            { 1, beautiful.main_purple.base },        -- purple, full opacity (end)
        }
    }
    
    awful.titlebar(c, { size = (beautiful and beautiful.titlebar_height) or ((beautiful and beautiful.icon_size) or 16) + 2 }) : setup {
        { -- Left
            -- window icon with fallback, constrained to theme icon size, vertically centered, with padding (left=5, top=1)
            wibox.container.background(
                wibox.container.margin({
                    {
                        {
                            id = 'titlebar_icon',
                            image = c.icon or (beautiful and beautiful.awesome_icon) or nil,
                            forced_height = icon_size,
                            forced_width = icon_size,
                            resize = true,
                            widget = wibox.widget.imagebox,
                        },
                        valign = "center",
                        widget = wibox.container.place,
                    },
                }, 5, 0, 1, 0),
                beautiful.main_purple.base
            ),
            buttons = buttons,
            layout  = wibox.layout.fixed.horizontal
        },
        { -- Middle
            -- tiny title text with a subtle gradient background
            -- only the title area gets the gradient, not the main bar
            wibox.container.background(
                wibox.container.margin({
                    titlebar_text_widget,
                    valign = "center",
                    halign = "left",
                    widget = wibox.container.place,
                }, 5, 0, 1, 0),
                beautiful.titlebar_bg_focus
            ),
            buttons = buttons,
            layout  = wibox.layout.flex.horizontal
        },
        -- Right (wrap the whole group to give right=5, top=1 padding)
        wibox.container.background(
            wibox.container.margin({
                -- constrain all titlebar control buttons to theme icon size and center vertically
                { wibox.container.constraint(awful.titlebar.widget.floatingbutton (c), "exact", icon_size, icon_size), valign = "center", widget = wibox.container.place },
                { wibox.container.constraint(awful.titlebar.widget.maximizedbutton(c), "exact", icon_size, icon_size), valign = "center", widget = wibox.container.place },
                { wibox.container.constraint(awful.titlebar.widget.minimizebutton (c), "exact", icon_size, icon_size), valign = "center", widget = wibox.container.place },
                { wibox.container.constraint(awful.titlebar.widget.stickybutton   (c), "exact", icon_size, icon_size), valign = "center", widget = wibox.container.place },
                { wibox.container.constraint(awful.titlebar.widget.ontopbutton    (c), "exact", icon_size, icon_size), valign = "center", widget = wibox.container.place },
                { wibox.container.constraint(awful.titlebar.widget.closebutton    (c), "exact", icon_size, icon_size), valign = "center", widget = wibox.container.place },
                layout = wibox.layout.fixed.horizontal()
            }, 0, 5, 0, 0),
            titlebar_right_gradient
        ),
        layout = wibox.layout.align.horizontal
    }
    
    -- // MARK: --dynamic-titlebar-text-colour
    -- Set up dynamic titlebar text color based on focus state
    local function update_titlebar_text_color()
        if titlebar_text_widget then
            local color = client.focus == c and "#ffffff" or "#999999" -- bright when focused, dimmer when unfocused
            local raw = c.name or c.class or ""
            -- escape Pango markup characters so titles with &, <, > don't break parsing
            raw = raw:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;")
            titlebar_text_widget.markup = '<span color="' .. color .. '">' .. raw .. '</span>'
        end
    end
    
    -- Set initial color
    update_titlebar_text_color()
    
    -- Update color on focus changes
    c:connect_signal("focus", update_titlebar_text_color)
    c:connect_signal("unfocus", update_titlebar_text_color)
    c:connect_signal("property::name", update_titlebar_text_color)
end)
--]]


-- // MARK: --dragging-max-windows
-- Client property changes
client.connect_signal("property::maximized", function(c)
    -- Prevent firefox from maximizing (personal preference)
    if c.maximized and (c.class == "Navigator" or c.class == "firefox" or c.class == "Firefox") then
        c.maximized = false
    end
end)

-- Handle maximized state for dragging windows between screens
client.connect_signal("request::activate", function(c, context, hints)
    -- unmaximize only when a move was intended (from titlebar or modkey+drag)
    if (context == "mouse_click" or context == "titlebar") and c._intend_drag and c.maximized then
        -- store the maximized state to restore later
        c._was_maximized = true
        c.maximized = false
    end
end)

-- Create a new signal for drag completion
client.connect_signal("awesome::drag_end", function(c)
    if c and c._was_maximized then
        c.maximized = true
        c._was_maximized = nil
    end
end)

-- Use mouse::leave as a fallback
client.connect_signal("mouse::leave", function(c)
    if c and c._was_maximized and not window_manager.is_dragging(c) then
        c.maximized = true
        c._was_maximized = nil
    end
end)

client.connect_signal("property::struts", function(c)
    -- Make firefox picture-in-picture sticky when it meets screen edges
    local struts = c:struts()
    if struts.left ~= 0 or struts.right ~= 0 or
       struts.top ~= 0 or struts.bottom ~= 0 then
        c.sticky = true
    end
end)


-- disable focus-follows-mouse (sloppy focus): do not focus clients on cursor hover
-- keep old code commented for quick restore if desired
-- client.connect_signal("mouse::enter", function(c)
--     c:emit_signal("request::activate", "mouse_enter", {raise = false})
-- end)

-- Client cleanup - comprehensive cleanup on client destruction
-- somewm 2.0: "unmanage" renamed to "request::unmanage"
client.connect_signal("request::unmanage", function(c)
    -- immediate cleanup of all client tracking
    window_manager.cleanup(c)
    
    -- cleanup double-click timers
    local timer = double_click_timers[c]
    if timer then
        if timer.started then timer:stop() end
        double_click_timers[c] = nil
    end
    
    -- explicit cleanup of title log (though weak keys should handle this)
    __title_log[c] = nil
    
    -- old: forced full GC via delayed_call -- removed: same SEGV risk as
    -- the cleanup timer GC (line 612). A full GC here can collect Lua
    -- callback closures that C signal handlers still reference, causing
    -- SEGV in lua_pcall on the next surface_commit_state signal
    -- gears.timer.delayed_call(function()
    --     collectgarbage("collect")
    -- end)
end)


-- when a client is minimized/restored or hidden/unhidden, refresh tasklists to update bg color
client.connect_signal("property::minimized", function(c)
    shimmer.refresh_all_tasklists()
end)

client.connect_signal("property::hidden", function(c)
    shimmer.refresh_all_tasklists()
end)


-- keep track of which clients are being dragged
client.connect_signal("request::activate", function(c, context, hints)
    -- validate client first
    if not c or not c.valid then return end
    
    -- only track dragging for explicit move intention to avoid false positives on simple clicks
    local buttons = mouse.coords().buttons
    if not c._intend_drag then
        return
    end
    if not buttons or not buttons[1] then
        -- mouse button released, no longer dragging
        window_manager.set_dragging(c, false)
        window_manager.store_center(c)
        c._intend_drag = nil
    else
    end
end)

-- explicit lifecycle tracking for intended drags in case activate events are sparse
client.connect_signal("button::press", function(c)
    -- validate client before accessing properties
    if not c or not c.valid then return end
    if c._intend_drag then
        window_manager.set_dragging(c, true)
    end
end)

client.connect_signal("button::release", function(c)
    -- validate client before accessing properties
    if not c or not c.valid then return end
    if c._intend_drag then
        window_manager.set_dragging(c, false)
        window_manager.store_center(c)
        -- restore maximized if it was set prior to drag
        if c._was_maximized then
            c.maximized = true
            c._was_maximized = nil
        end
        c._intend_drag = nil
    end
end)


client.connect_signal("property::size", function(c)
    -- validate client first
    if not c or not c.valid then return end
    
    -- Skip if not floating
    if not c.floating then return end

    -- Skip if being dragged
    if window_manager.is_dragging(c) then return end

    -- Skip when client is maximized/fullscreen (or partially maximized)
    -- otherwise our center maintenance would offset the geometry away from workarea
    if c.maximized or c.fullscreen or c.maximized_horizontal or c.maximized_vertical then
        return
    end

    -- Record center point on first detection or maintain center during resize
    if not window_centers[c] then
        window_manager.store_center(c)
    else
        window_manager.maintain_center(c)
        window_manager.store_center(c)  -- Update stored center after repositioning
    end
end)


-- // MARK: -- auto-resize floated clients 
-- Handle floating property changes to auto-resize tiled-to-floating clients
client.connect_signal("property::floating", function(c)
    -- validate client first
    if not c or not c.valid then return end
    
    -- only act when client becomes floating (not when becoming tiled)
    if not c.floating then 
        -- store current size when becoming tiled (for potential future floating)
        local geo = c:geometry()
        if geo.width > 0 and geo.height > 0 then
            client_tiled_sizes[c] = {
                width = geo.width,
                height = geo.height
            }
        end
        return 
    end
    
    -- skip size reduction for fullscreen or maximized windows
    if c.fullscreen or c.maximized or c.maximized_horizontal or c.maximized_vertical then
        return
    end
    
    -- skip size reduction for dialog and modal windows (they start floating)
    if c.type == "dialog" or c.modal then
        return
    end
    
    -- skip size reduction for windows that are always floating by nature
    local always_floating_classes = {
        "Pavucontrol", "pwvucontrol", "Arandr", "KeePassXC", "Blueman-manager",
        "Gpick", "Kruler", "Sxiv", "qView", "Cadence", "qjackctl", "QjackCtl"
    }
    for _, class in ipairs(always_floating_classes) do
        if c.class == class then
            return
        end
    end
    
    -- client just became floating - check if we have a stored tiled size
    local tiled_size = client_tiled_sizes[c]
    if not tiled_size then return end
    
    -- reduce size by 10% for easier management
    local reduction_factor = 0.9  -- 10% reduction
    local new_width = math.floor(tiled_size.width * reduction_factor)
    local new_height = math.floor(tiled_size.height * reduction_factor)
    
    -- ensure minimum size constraints
    new_width = math.max(new_width, MIN_WINDOW_SIZE or 50)
    new_height = math.max(new_height, MIN_WINDOW_SIZE or 50)
    
    -- get current position to maintain relative placement
    local current_geo = c:geometry()
    local center_x = current_geo.x + current_geo.width / 2
    local center_y = current_geo.y + current_geo.height / 2
    
    -- calculate new position to center the resized window
    local new_x = center_x - new_width / 2
    local new_y = center_y - new_height / 2
    
    -- apply the new geometry
    c:geometry({
        x = new_x,
        y = new_y, 
        width = new_width,
        height = new_height
    })
    
    -- clear the stored size since we've used it
    client_tiled_sizes[c] = nil
end)

-- Client cleanup handled above in consolidated signal section


-- Middle mouse button for minimise
-- awful.button({}, 3, function(c)
--     if c == client.focus then
--         c.minimized = true
--     else
--         client.focus = c
--         c:raise()
--     end
-- end)


-- Set keys
-- old: shadowed local and redundant join/unpack
-- local globalkeys = keys.globalkeys or {}
-- root.keys(gears.table.join(table.unpack(globalkeys)))
-- new: set once, use keys from module directly
root.keys(keys.globalkeys)

-- Set global mouse bindings
-- mod4 + mousewheel: cycle through tags with clients
root.buttons(gears.table.join(
    awful.button({ }, 1, function()
        if mymainmenu and mymainmenu.wibox and mymainmenu.wibox.visible then
            mymainmenu:hide()
        end
    end),
    awful.button({ }, 3, function()
        if mymainmenu then
            mymainmenu:toggle()
        end
    end),
    awful.button({ modkey }, 4, function()
        cycle_tags_with_clients("prev")
    end),
    awful.button({ modkey }, 5, function()
        cycle_tags_with_clients("next")
    end)
))

-- removed: unused tag_keybindings definition


-- // MARK: RULES
-- ################################################################################
-- ██████╗ ██╗   ██╗██╗     ███████╗
-- ██╔══██╗██║   ██║██║     ██╔════╝
-- ██████╔╝██║   ██║██║     ███████╗s
-- ██╔══██╗██║   ██║██║     ██║
-- ██║  ██║╚██████╔╝███████╗███████║
-- ╚═╝  ╚═╝ ╚═════╝ ╚══════╝╚══════╝
-- ################################################################################
-- RULES - client rules and window behavior


-- rules to apply to new clients (through the "manage" signal)
--[[
awful.rules.rules = {
    -- all clients will match this rule (global defaults)
    {
        rule = {},
        properties = {
            border_width = beautiful.border_width,
            border_color = beautiful.border_normal,
            focus = awful.client.focus.filter,
            raise = true,
            keys = clientkeys,
            buttons = clientbuttons,
            screen = awful.screen.preferred,
            placement = awful.placement.no_overlap+awful.placement.no_offscreen
        }
    },


    -- add titlebars to normal clients and dialogs
    { rule_any = {type = { "normal", "dialog" }}, properties = { titlebars_enabled = true } },

    -- bypass size hints for arandr
    { rule = { class = "Arandr" }, properties = { size_hints_honor = false } },


    -- floating clients
    { rule_any = {
            instance = {
          "DTA",  -- Firefox addon DownThemAll.
          "copyq",  -- Includes session name in class.
          "pinentry",
        },
            class = {
          "Arandr",
          "Blueman-manager",
          "Gpick",
          "Kruler",
          "MessageWin",  -- kalarm.
          "Sxiv",
          "Tor Browser", -- Needs a fixed window size to avoid fingerprinting by screen size.
          "Wpa_gui",
          "veromix",
          "xtightvncviewer"},

        -- Note that the name property shown in xprop might be set slightly after creation of the client
        -- and the name shown there might not match defined rules here.
            name = {
          "Event Tester",  -- xev.
        },
            role = {
          "AlarmWindow",  -- Thunderbird's calendar.
          "ConfigManager",  -- Thunderbird's about:config.
          "pop-up",       -- e.g. Google Chrome's (detached) Developer Tools.
        }
      }, properties = { floating = true }},



    -- // MARK: --old-floating-rules
    -- {{{ Floating client rules
    -- Applications that should always be floating windows
    -- Search marker: floatingggggggggg
    {
        rule_any = {
            -- Match by instance name
            instance = {
                "DTA",         -- Firefox addon DownThemAll
                "copyq",       -- Clipboard manager (includes session name in class)
                "pinentry",    -- Password entry dialog
                "ncmpcpp",     -- Music player
                "firefox"      -- Firefox dialogs
            },

            -- Match by class name (organized by category)
            class = {
                -- System utilities
                "Arandr", "Blueman-manager", "Lxappearance", "Gsmartcontrol",
                "hp-toolbox", "Protonvpn-gui", "Syncthing GTK", "netctl-gui",
                "Solaar", "Font-manager", "Font Manager", "Deskflow",
		-- "qt5ct", 

                -- Audio/Video tools
                "Cadence", "qjackctl", "Studio-controls", "QjackCtl",
                "kmix", "Pavucontrol", "pwvucontrol", "Goodvibes",
                "Drumstick MIDI Monitor", "Audio/MIDI Setup", "Mixer",
                "seq64", "qseq66", "patroneo", "Agordejo", "radium_compessor",
                "Vlc", "vokoscreenNG", "SimpleScreenRecorder", "Indicator-sound-switcher5",

                -- Image & Graphics
                "Gpick", "Kruler", "emulsion", "Sxiv", "qimgv", "qView",
                "Image Lounge", "Image Menu", "spectacle"
		--, "flameshot",

                -- Security & Privacy
                "KeePassXC", "Tor Browser", -- Tor needs fixed window size to avoid fingerprinting

                -- Misc applications
                "MessageWin",  -- kalarm
                "copyq", "* Copying", "krunner", "xtightvncviewer",
                "scrcpy", "Gnaural", "kdeconnect.sms", "Mattermost",
                "Onboard", "gammy", "Flirc", "isoimagewriter", "Xdotoolgui.py",
                "mpd218 editor.exe", "Indicator-sound-switcher", "easyeffects"
            },

            -- Match by window name (when class/instance isn't reliable)
            -- Note: The name property might be set slightly after client creation
            name = {
                "Event Tester",        -- xev
                "Choose an application", -- DoubleCMD dialog
                "File operations",      -- DoubleCMD dialog
                "Blender Preferences",
                "Options",
                "Tree View Menu",
                "menu"                  -- Rekordbox
            },

            -- Match by window role
            role = {
                "AlarmWindow",   -- Thunderbird calendar
                "ConfigManager", -- Thunderbird about:config
                "pop-up",       -- e.g., Chrome's Developer Tools
                "page-info",    -- Firefox page info dialog
                "TfrmFileOp",    -- DoubleCMD file transfer
                "TfrmViewer"     -- DoubleCMD text viewer
            }
        },
        properties = {
            floating = true,  -- Make these windows floating
            placement = awful.placement.centered +       -- Center on screen
                        awful.placement.no_overlap +     -- Prevent overlap
                        awful.placement.no_offscreen     -- Keep on screen
        }
    },

    -- removed: duplicate focus filter rule (covered by global defaults)

    -- // MARK: --tag-assignments
    -- {{{ Application-specific tag assignments
    -- Custom callback to set class
    -- old: { rule = { class = "URxvt", instance = "ncmpcpp" }, callback = function(c) c.overwrite_class = "urxvt:dev" end },
    {
        rule = {class = "ncmpcpp"},
        callback = function(c) c.overwrite_class = "alacritty:ncmpcpp" end
    },

    -- Tag 2: Audio production
    { rule = {instance = "Agordejo"}, properties = {tag = "2"} },
    { rule = {instance = "raysession"}, properties = {tag = "2"} },

    -- Tag 3: File sharing & media management
    { rule = {instance = "Nicotine"}, properties = {tag = "3"} },
    { rule = {instance = "qbittorrent"}, properties = {tag = "3"} },
    { rule = {class = "Picard"}, properties = {tag = "3"} },

    -- Tag 4: DJ software
    { rule = {class = "Mixxx"}, properties = {tag = "4"} },

    -- Tag 8: Music & video playback
    { rule = {instance = "ncmpcpp"}, properties = {tag = "8"} },
    { rule = {instance = "spotify"}, properties = {tag = "8"} },
    { rule = {instance = "Spotify"}, properties = {tag = "8"} },
    { rule = {class = "mpv"}, properties = {screen = 1, tag = "8", switch_to_tags = true} },

    -- Tag 9: File managers
    { rule = {instance = "Double Commander"}, properties = {tag = "9"} },
    { rule = {instance = "doublecmd"}, properties = {tag = "9"} },

    -- Tag "-": Chat applications
    { rule = {instance = "quassel"}, properties = {tag = "-", switch_to_tags = true} },

    -- Tag "=": Web browsers
    { rule = {instance = "firefox"}, properties = {tag = "=", switch_to_tags = true} },
    { rule = {class = "firefox"}, properties = {tag = "=", switch_to_tags = true} },
    { rule = {class = "Firefox"}, properties = {tag = "=", switch_to_tags = true} },
    { rule = {class = "Chromium"}, properties = {tag = "=", switch_to_tags = true} },
    { rule = {class = "Navigator"}, properties = {tag = "=", switch_to_tags = true} },
    
    -- More Tag assignments
    { rule = {instance = "jack_mixer"}, properties = {tag = "3"} },
    { rule = {instance = "radium_compressor"}, properties = {tag = "2"} },
    { rule = {instance = "qseq64"}, properties = {tag = "3"} },
    { rule = {instance = "qseq66"}, properties = {tag = "3"} },

-- }}} -- End of application-specific tag assignments

    -- // MARK: --window-sizing
    -- {{{ Window size management rules
    -- Dialogs and windows that should open at larger sizes than default
--     -- Screenshot and image-related dialogs
--     {
--         rule_any = {
--             name = {
--                 "Save screenshot", "Save Screenshot", "Screenshot", "Save Image",
--                 "Save As", "Save File", "Export Image", "Export Screenshot",
--                 "Image Properties", "Image Info", "Screenshot Options"
--             }
--         },
--         properties = {
--             floating = true,
--             width = 800,
--             height = 600,
--             placement = awful.placement.centered + awful.placement.no_overlap + awful.placement.no_offscreen
--         }
--     },

--     -- File operation dialogs
--     {
--         rule_any = {
--             name = {
--                 "Save As", "Open File", "Choose File", "File Operations",
--                 "Copy Files", "Move Files", "Delete Files", "File Properties",
--                 "Folder Properties", "Create Folder", "Rename"
--             }
--         },
--         properties = {
--             floating = true,
--             width = 900,
--             height = 700,
--             placement = awful.placement.centered + awful.placement.no_overlap + awful.placement.no_offscreen
--         }
--     },

--     -- Application preferences and settings dialogs
--     {
--         rule_any = {
--             name = {
--                 "Preferences", "Settings", "Options", "Configuration",
--                 "Properties", "Advanced Settings", "User Preferences",
--                 "Application Settings", "System Preferences"
--             }
--         },
--         properties = {
--             floating = true,
--             width = 850,
--             height = 650,
--             placement = awful.placement.centered + awful.placement.no_overlap + awful.placement.no_offscreen
--         }
--     },

--     -- Print and export dialogs
--     {
--         rule_any = {
--             name = {
--                 "Print", "Print Setup", "Print Options", "Print Preview",
--                 "Export", "Export As", "Export Options", "Save for Web",
--                 "Print to File", "Print Settings"
--             }
--         },
--         properties = {
--             floating = true,
--             width = 750,
--             height = 550,
--             placement = awful.placement.centered + awful.placement.no_overlap + awful.placement.no_offscreen
--         }
--     },

--     -- Error and confirmation dialogs
--     {
--         rule_any = {
--             name = {
--                 "Error", "Warning", "Confirmation", "Confirm Action",
--                 "Delete Confirmation", "Overwrite Confirmation", "Exit Confirmation",
--                 "Unsaved Changes", "Save Changes", "Discard Changes"
--             }
--         },
--         properties = {
--             floating = true,
--             width = 500,
--             height = 300,
--             placement = awful.placement.centered + awful.placement.no_overlap + awful.placement.no_offscreen
--         }
--     },

--     -- Browser dialogs (Firefox, Chrome, etc.)
--     {
--         rule_any = {
--             name = {
--                 "Downloads", "Download Manager", "Bookmarks", "History",
--                 "Add Bookmark", "Edit Bookmark", "Page Info", "Security Info",
--                 "Developer Tools", "Inspect Element", "Console"
--             }
--         },
--         properties = {
--             floating = true,
--             width = 800,
--             height = 600,
--             placement = awful.placement.centered + awful.placement.no_overlap + awful.placement.no_offscreen
--         }
--     },

--     -- Media player dialogs
--     {
--         rule_any = {
--             name = {
--                 "Media Info", "Track Info", "Album Info", "Playlist",
--                 "Add to Playlist", "Create Playlist", "Media Properties",
--                 "Audio Settings", "Video Settings", "Subtitle Settings"
--             }
--         },
--         properties = {
--             floating = true,
--             width = 700,
--             height = 500,
--             placement = awful.placement.centered + awful.placement.no_overlap + awful.placement.no_offscreen
--         }
--     },

--     -- Development and coding dialogs
--     {
--         rule_any = {
--             name = {
--                 "Debug", "Debug Console", "Output", "Terminal",
--                 "Build Output", "Compile Output", "Error List",
--                 "Find in Files", "Replace in Files", "Search Results"
--             }
--         },
--         properties = {
--             floating = true,
--             width = 900,
--             height = 700,
--             placement = awful.placement.centered + awful.placement.no_overlap + awful.placement.no_offscreen
--         }
--     },

--     -- Generic large dialogs (catch-all for other dialogs)
--     {
--         rule_any = {
--             type = { "dialog" }
--         },
--         properties = {
--             floating = true,
--             width = 600,
--             height = 400,
--             placement = awful.placement.centered + awful.placement.no_overlap + awful.placement.no_offscreen
--         }
--     }
    
-- }}} -- End of window size management rules
}
--]]

-- removed: duplicate global defaults rule (already defined above)


-- // MARK: --ruled-rules
-- modern rules system (ruled)
-- keep the old awful.rules.rules commented above for reference
ruled.client.connect_signal("request::rules", function()
    -- global defaults
    ruled.client.append_rule {
        id = "global",
        rule = { },
        properties = {
            border_width = beautiful.border_width,
            border_color = beautiful.border_normal,
            focus = awful.client.focus.filter,
            raise = true,
            keys = clientkeys,
            buttons = clientbuttons,
            screen = awful.screen.preferred,
            -- center all floating windows by default
            placement = awful.placement.centered + awful.placement.no_overlap + awful.placement.no_offscreen,
        }
    }

    -- titlebars
    ruled.client.append_rule {
        id = "titlebars",
        rule_any = { type = { "normal", "dialog" } },
        properties = { titlebars_enabled = true }
    }

    -- dialog windows: ensure floating and set reasonable size for file choosers
    ruled.client.append_rule {
        id = "dialogs",
        rule = { type = "dialog" },
        properties = {
            floating = true,
            -- placement inherited from global defaults (centered)
        },
        callback = function(c)
            -- set minimum size for file chooser dialogs
            if c.role == "GtkFileChooserDialog" or 
               (c.name and (c.name:match("Open File") or c.name:match("Save") or c.name:match("Choose"))) then
                local geo = c:geometry()
                local min_width = 800
                local min_height = 600
                if geo.width < min_width or geo.height < min_height then
                    c:geometry({
                        width = math.max(geo.width, min_width),
                        height = math.max(geo.height, min_height)
                    })
                    -- recenter after resizing
                    awful.placement.centered(c, { honor_workarea = true })
                end
            end
        end
    }

    -- terminal: borderless for a cleaner look
    ruled.client.append_rule {
        id = "terminal_borderless",
        rule_any = { class = { "foot", "Foot", "wezterm", "WezTerm", "Alacritty", "URxvt", "XTerm" } },
        properties = {
            border_width = 0,
        }
    }

    -- arandr size hints
    ruled.client.append_rule {
        id = "arandr_size_hints",
        rule = { class = "Arandr" },
        properties = {
            size_hints_honor = false,
            ontop = true,
            tag = "9",
            width = 600
        },
        callback = function(c)
            -- ensure it opens on the focused screen
            local focused_screen = awful.screen.focused()
            if c.screen ~= focused_screen then
                c:move_to_screen(focused_screen)
            end
            
            -- move to tag 9 on the correct screen
            local tag9 = focused_screen.tags[9]
            if tag9 then
                c:move_to_tag(tag9)
                -- make tag 9 visible alongside current tags
                if not tag9.selected then
                    awful.tag.viewtoggle(tag9)
                    arandr_tag_visible = true
                end
            end
            
            -- ensure minimum width
            local geo = c:geometry()
            if geo.width < 600 then
                c:geometry({ width = 600 })
            end
        end
    }

    -- // MARK: --floating-rules
    -- generic floating helpers (instances/classes/roles)
    ruled.client.append_rule {
        id = "floating_generic",
        rule_any = {
            instance = { "DTA", "copyq", "pinentry" },
            class = { "Arandr", "Blueman-manager", "Gpick", "Kruler", "MessageWin", "Sxiv", "Tor Browser",
                "Wpa_gui", "veromix", "xtightvncviewer", "KeePassXC" },
            name = { "Event Tester" },
            role = { "AlarmWindow", "ConfigManager", "pop-up" },
        },
        properties = { floating = true }
    }

    -- extended floating rules (consolidated from original)
    ruled.client.append_rule {
        id = "floating_extended",
        rule_any = {
            instance = { "DTA", "copyq", "pinentry", "ncmpcpp", "firefox" },
            class = {
                -- system
                "Arandr", "Blueman-manager", "Lxappearance", "Gsmartcontrol", "hp-toolbox",
                "Protonvpn-gui", "Syncthing GTK", "netctl-gui", "Solaar", "Font-manager",
                "Font Manager", "qt5ct", "Deskflow",
                -- audio/video
                "Cadence", "qjackctl", "Studio-controls", "QjackCtl", "kmix", "Pavucontrol",
                "pwvucontrol", "Goodvibes", "Drumstick MIDI Monitor", "Audio/MIDI Setup", "Mixer",
                "seq64", "qseq66", "patroneo", "Agordejo", "radium_compessor", "Vlc",
                "vokoscreenNG", "SimpleScreenRecorder", "Indicator-sound-switcher5",
                -- graphics
                "Gpick", "Kruler", "emulsion", "Sxiv", "qimgv", "qView", "Image Lounge",
                "Image Menu", "spectacle", "flameshot",
                -- privacy
                 "Tor Browser",
                -- misc
                "MessageWin", "copyq", "* Copying", "krunner", "xtightvncviewer", "scrcpy",
                "Gnaural", "kdeconnect.sms", "Mattermost", "Onboard", "gammy", "Flirc",
                "isoimagewriter", "Xdotoolgui.py", "mpd218 editor.exe", "Indicator-sound-switcher", "easyeffects"
            },
            name = { "Event Tester", "Choose an application", "File operations", "Blender Preferences",
                "Options", "Tree View Menu", "menu" },
            role = { "AlarmWindow", "ConfigManager", "pop-up", "page-info", "TfrmFileOp",
                "TfrmViewer" },
        },
        properties = {
            floating = true,
            placement = awful.placement.centered + awful.placement.no_overlap + awful.placement.no_offscreen,
        }
    }

    -- tag assignments (grouped and appended via loop)
    local tag_rules = {
        -- old: { rule = { class = "URxvt", instance = "ncmpcpp" }, callback = function(c) c.overwrite_class = "urxvt:dev" end },
        { rule = { class = "ncmpcpp" }, callback = function(c) c.overwrite_class = "alacritty:ncmpcpp" end },

        { rule = { instance = "ncmpcpp"           }, properties = { tag = "2" } },
        { rule = { instance = "spotify"           }, properties = { tag = "2" } },
        { rule = { instance = "Spotify"           }, properties = { tag = "2" } },

        { rule = { instance = "Agordejo"          }, properties = { tag = "2" } },
        { rule = { instance = "raysession"        }, properties = { tag = "2" } },
        { rule = { instance = "radium_compressor" }, properties = { tag = "2" } },


        { rule = { instance = "qseq64"            }, properties = { tag = "3" } },
        { rule = { instance = "qseq66"            }, properties = { tag = "3" } },
        { rule = { instance = "jack_mixer"        }, properties = { tag = "3" } },

        { rule = { instance = "Nicotine"          }, properties = { tag = "3" } },
        { rule = { instance = "qbittorrent"       }, properties = { tag = "3" } },
        { rule = { class = "Picard"               }, properties = { tag = "3" } },


        { rule = { class = "Mixxx"                }, properties = { tag = "4" } },

        
        { rule = { class = "mpv"                  }, properties = { tag = "7", ontop = true, floating = true, switch_to_tags = true } },


        { rule = { instance = "keepassxc"         }, properties = { tag = "8" } },

        { rule = { class = "Pavucontrol"          }, properties = { tag = "8", ontop = true }, callback = function(c)
            -- when pavucontrol opens, make tag 9 visible alongside current tags
            local screen = c.screen or awful.screen.focused()
            local tag8 = screen.tags[8]
            if tag8 and not tag8.selected then
                awful.tag.viewtoggle(tag8)
                pavucontrol_tag_visible = true
            end
        end },


        { rule = { instance = "Double Commander"  }, properties = { tag = "9" } },
        { rule = { instance = "doublecmd"         }, properties = { tag = "9" } },


        { rule = { instance = "quassel"           }, properties = { tag = "-", switch_to_tags = true } },


        { rule = { class = "firefox"              }, properties = { tag = "=", switch_to_tags = true } },
        { rule = { class = "Firefox"              }, properties = { tag = "=", switch_to_tags = true } },
        { rule = { class = "Chromium"             }, properties = { tag = "=", switch_to_tags = true } },
        { rule = { class = "Navigator"            }, properties = { tag = "=", switch_to_tags = true } },
        { rule = { instance = "firefox"           }, properties = { tag = "=", switch_to_tags = true } },

    }
    for _, r in ipairs(tag_rules) do
        ruled.client.append_rule(r)
    end
end)



-- // MARK: SESSION
-- ################################################################################
-- ███████╗███████╗███████╗███████╗██╗ ██████╗ ███╗   ██╗
-- ██╔════╝██╔════╝██╔════╝██╔════╝██║██╔═══██╗████╗  ██║
-- ███████╗█████╗  ███████╗███████╗██║██║   ██║██╔██╗ ██║
-- ╚════██║██╔══╝  ╚════██║╚════██║██║██║   ██║██║╚██╗██║
-- ███████║███████╗███████║███████║██║╚██████╔╝██║ ╚████║
-- ╚══════╝╚══════╝╚══════╝╚══════╝╚═╝ ╚═════╝ ╚═╝  ╚═══╝
-- ################################################################################
-- session management - preserve state across restarts

-- reactivate tabs that were active before a restart of awesomewm
-- for Firefox, might have to disable widget.disable-workspace-management in about:config
-- https://www.reddit.com/r/awesomewm/comments/syjolb/preserve_previously_used_tag_between_restarts

awesome.connect_signal('exit', function(reason_restart)
	if not reason_restart then return end
	local file = io.open('/tmp/awesomewm-last-selected-tags', 'w+')
	for s in screen do
		file:write(s.selected_tag.index, '\n')
	end
	file:close()
end)

awesome.connect_signal('startup', function()
	local file = io.open('/tmp/awesomewm-last-selected-tags', 'r')
	if not file then return end
	local selected_tags = {}
	for line in file:lines() do
		table.insert(selected_tags, tonumber(line))
	end
	for s in screen do
		local i = selected_tags[s.index]
		if i and s.tags[i] then
			local t = s.tags[i]
			t:view_only()
		end
	end
	file:close()
end)




-- // MARK: START
-- ################################################################################
-- ███████╗████████╗ █████╗ ██████╗ ████████╗
-- ██╔════╝╚══██╔══╝██╔══██╗██╔══██╗╚══██╔══╝
-- ███████╗   ██║   ███████║██████╔╝   ██║   
-- ╚════██║   ██║   ██╔══██╗██╔══██╗   ██║   
-- ███████╗   ██║   ██║  ██║██║  ██║   ██║   
-- ╚══════╝   ╚═╝   ╚═╝  ╚═╝╚═╝  ╚═╝   ╚═╝   
-- ################################################################################
-- START - Autostart applications

-- Run programs on startup
-- somewm is its own compositor; no picom needed on Wayland
-- awful.spawn.with_shell("pgrep -u $USER -x picom > /dev/null || picom --config ~/.config/picom.conf") -- don't double-background

-- PolicyKit authentication agent (polkit-kde-agent works standalone outside Plasma)
awful.spawn.with_shell("pgrep -u $USER -f polkit-kde-authentication-agent-1 > /dev/null || /usr/lib/polkit-kde-authentication-agent-1")

-- Idle and lock management (swayidle: lock after 300s, dpms off after 600s)
-- awful.spawn.with_shell("pgrep -u $USER -x swayidle > /dev/null || swayidle -w before-sleep 'swaylock -f' timeout 300 'swaylock -f' timeout 600 'wlopm -j | jq -r .[].name | xargs -I{} wlopm --off {}' resume 'wlopm -j | jq -r .[].name | xargs -I{} wlopm --on {}'")
awful.spawn.with_shell("pgrep -u $USER -x swayidle > /dev/null || swayidle -w before-sleep 'swaylock -f' timeout 600 'wlopm -j | jq -r .[].name | xargs -I{} wlopm --off {}' resume 'wlopm -j | jq -r .[].name | xargs -I{} wlopm --on {}'")

-- Night light (wlsunset: 3500K at night)
awful.spawn.with_shell("pgrep -u $USER -x wlsunset > /dev/null || wlsunset -T 6500 -t 3500")

-- Screenshot tray icon (replaces flameshot; spectacle works natively on Wayland)
-- spectacle-trayicon is a Python script so pgrep -x fails (comm=python3, name>15chars)
awful.spawn.with_shell("pgrep -u $USER -f spectacle-trayicon > /dev/null || spectacle-trayicon")

-- Output management (kanshi auto-applies profiles on hotplug; use Mod4+Alt+R for manual switching)
awful.spawn.with_shell("pgrep -u $USER -x kanshi > /dev/null || kanshi")

-- Screen layouts
-- awful.spawn.with_shell("~/.screenlayout/new/31-laptop-tv-side.sh")

-- Network manager applet
awful.spawn.with_shell("pgrep -u $USER -x nm-applet > /dev/null || nm-applet --indicator")

-- Bluetooth applet
awful.spawn.with_shell("pgrep -u $USER -x blueman-applet > /dev/null || blueman-applet")

-- Battery icon (native wibar widget; cbatticon/xfce4-power-manager are XEmbed-only with no SNI host on somewm)

-- Volume control
-- awful.spawn.with_shell("volumeicon")

-- Clipboard manager
awful.spawn.with_shell("pgrep -u $USER -x clipcat > /dev/null || clipcat")

-- Notifications daemon
-- awful.spawn.with_shell("dunst")

-- Uncomment any of the above or add your own autostart application                                                                                                                                                                                                                                             x x
