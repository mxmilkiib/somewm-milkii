#!/usr/bin/env lua

-- Unified Layout Icon Generator
-- Creates SVG variants of layout icons with consistent styling
-- Reads configuration from theme.lua for centralized style management

-- Load theme configuration (fallback to defaults if not available)
local function load_theme_config()
    local config = {
        -- Colors
        purple_margin_bg = "#623997",    -- Purple margin/background
        window_fill = "#CCCCCC",         -- Light grey fills
        window_border = "#AAAAAA",       -- Light grey borders and separators
        background = "#000000",          -- Black background
        
        -- Dimensions
        icon_size = 64,                  -- Icon dimensions
        border_width = 2,                -- Purple margin width
        corner_radius = 1,               -- Rounded corner radius
        separator_width = 1,             -- Separator width between windows
        min_purple_margin = 2,           -- Minimum purple space around representations
        
        -- File naming
        current_suffix = "_alt",         -- Current active icon suffix
        archive_suffix = "_alt_v2",      -- Archive suffix for previous versions
    }
    
    -- Try to load from theme.lua if available
    local theme_file = "../theme.lua"
    local file = io.open(theme_file, "r")
    if file then
        local content = file:read("*all")
        file:close()
        
        -- Extract color values from layout_icon_config section only
        local config_section = content:match("theme%.layout_icon_config%s*=%s*{([^}]+)}")
        if config_section then
            for color, pattern in pairs({
                purple_margin_bg = 'purple_margin_bg%s*=%s*"([^"]+)"',
                window_fill = 'window_fill%s*=%s*"([^"]+)"',
                window_border = 'window_border%s*=%s*"([^"]+)"',
                background = 'background%s*=%s*"([^"]+)"'
            }) do
                local value = config_section:match(pattern)
                if value then
                    config[color] = value
                    print("Loaded " .. color .. " = " .. value)
                end
            end
        end
        
        -- Extract numeric values from layout_icon_config section only
        local config_section = content:match("theme%.layout_icon_config%s*=%s*{([^}]+)}")
        if config_section then
            for num, pattern in pairs({
                icon_size = 'icon_size%s*=%s*(%d+)',
                border_width = 'border_width%s*=%s*(%d+)',
                corner_radius = 'corner_radius%s*=%s*(%d+)',
                separator_width = 'separator_width%s*=%s*(%d+)',
                min_purple_margin = 'min_purple_margin%s*=%s*(%d+)'
            }) do
                local value = config_section:match(pattern)
                if value then
                    config[num] = tonumber(value)
                    print("Loaded " .. num .. " = " .. value)
                end
            end
        end
        
        -- Extract suffix values from layout_icon_config section only
        local config_section = content:match("theme%.layout_icon_config%s*=%s*{([^}]+)}")
        if config_section then
            for suffix, pattern in pairs({
                current_suffix = 'current_suffix%s*=%s*"([^"]+)"',
                archive_suffix = 'archive_suffix%s*=%s*"([^"]+)"'
            }) do
                local value = config_section:match(pattern)
                if value then
                    config[suffix] = value
                    print("Loaded " .. suffix .. " = " .. value)
                end
            end
        end
    else
        print("Theme file not found, using default configuration")
    end
    
    return config
end

-- Load configuration
local config = load_theme_config()

-- Derived values
local CONTENT_SIZE = config.icon_size - (config.border_width * 2)

-- Layout definitions
local layouts = {
    -- Bling layouts
    deck = {
        name = "deck",
        description = "Deck-style stacking layout",
        windows = {
            {x = 8, y = 8, w = 48, h = 40},   -- Main window
            {x = 12, y = 12, w = 40, h = 32}, -- Stacked window
            {x = 16, y = 16, w = 32, h = 24}  -- Top window
        }
    },
    
    equalarea = {
        name = "equalarea", 
        description = "Equal area distribution",
        windows = {
            {x = 8, y = 8, w = 27, h = 48},   -- Left window
            {x = 37, y = 8, w = 19, h = 48}   -- Right window (1px gap)
        }
    },
    
    mstab = {
        name = "mstab",
        description = "Master-slave tabbing",
        windows = {
            {x = 8, y = 8, w = 48, h = 31},   -- Master area
            {x = 8, y = 41, w = 48, h = 15}   -- Slave area (1px gap)
        }
    },
    
    centered = {
        name = "centered",
        description = "Centered layout",
        windows = {
            {x = 16, y = 16, w = 32, h = 32}  -- Centered window
        }
    },
    
    -- Lain centerwork horizontal (main window centered, slaves top and bottom)
    centerworkh = {
        name = "centerworkh",
        description = "Centerwork horizontal layout",
        windows = {
            {x = 8, y = 8, w = 23, h = 11},   -- Top-left slave
            {x = 32, y = 8, w = 24, h = 11},  -- Top-right slave
            {x = 8, y = 20, w = 48, h = 24},  -- Center main window
            {x = 8, y = 45, w = 23, h = 11},  -- Bottom-left slave
            {x = 32, y = 45, w = 24, h = 11}  -- Bottom-right slave
        }
    },

    -- Lain termfair center (windows centered in a grid until nmaster columns,
    -- then master on left with slaves stacked in columns on the right)
    centerfair = {
        name = "centerfair",
        description = "Termfair center layout",
        windows = {
            {x = 8, y = 8, w = 15, h = 48},   -- Left centered window
            {x = 24, y = 8, w = 15, h = 48},  -- Center window (1px gap)
            {x = 40, y = 8, w = 16, h = 48}   -- Right window (1px gap, remainder)
        }
    },
    
    -- Adaptive layout: focused window takes 3/5 of the long axis
    threefifths = {
        name = "threefifths",
        description = "Adaptive 3/5 active window",
        windows = {
            {x = 8, y = 8, w = 29, h = 48},   -- Active window (3/5 width)
            {x = 38, y = 8, w = 18, h = 48}   -- Slave window (2/5 width, 1px gap)
        }
    },

    -- Custom layouts (already have icons, but creating unified versions)
    centerwork_adaptiveh = {
        name = "centerwork_adaptiveh",
        description = "Adaptive centerwork horizontal",
        windows = {
            {x = 8, y = 8, w = 48, h = 31},   -- Top window (2/3)
            {x = 8, y = 41, w = 48, h = 15}   -- Bottom window (1/3, 1px gap)
        }
    },
    
    centerwork_twothirdsh = {
        name = "centerwork_twothirdsh", 
        description = "Two-thirds centerwork horizontal",
        windows = {
            {x = 8, y = 8, w = 48, h = 19},   -- Top window (1/3)
            {x = 8, y = 29, w = 48, h = 27}   -- Bottom window (2/3, 1px gap)
        }
    },
    
    -- Additional layouts that need alternative icons
    tile = {
        name = "tile",
        description = "Default tile layout",
        windows = {
            {x = 8, y = 8, w = 40, h = 48},   -- Master window
            {x = 48, y = 8, w = 8, h = 48}    -- Stack window
        }
    },
    
    tiletop = {
        name = "tiletop",
        description = "Tile top layout",
        windows = {
            {x = 8, y = 8, w = 48, h = 32},   -- Top window
            {x = 8, y = 40, w = 48, h = 16}   -- Bottom window
        }
    },
    
    tilebottom = {
        name = "tilebottom",
        description = "Tile bottom layout",
        windows = {
            {x = 8, y = 8, w = 48, h = 16},   -- Top window
            {x = 8, y = 24, w = 48, h = 32}   -- Bottom window
        }
    },
    
    tileleft = {
        name = "tileleft",
        description = "Tile left layout",
        windows = {
            {x = 8, y = 8, w = 32, h = 48},   -- Left window
            {x = 40, y = 8, w = 16, h = 48}   -- Right window
        }
    },
    
    magnifier = {
        name = "magnifier",
        description = "Magnifier layout",
        windows = {
            {x = 16, y = 16, w = 32, h = 32}  -- Magnified window
        }
    },
    
    max = {
        name = "max",
        description = "Maximized layout",
        windows = {
            {x = 8, y = 8, w = 48, h = 48}    -- Full window
        }
    },
    
    floating = {
        name = "floating",
        description = "Floating layout",
        windows = {
            {x = 12, y = 12, w = 40, h = 40}  -- Floating window
        }
    },
    
    cascade = {
        name = "cascade",
        description = "Cascade layout",
        windows = {
            {x = 8, y = 8, w = 48, h = 40},   -- Main window
            {x = 12, y = 12, w = 40, h = 32}, -- Cascaded window
            {x = 16, y = 16, w = 32, h = 24}  -- Top window
        }
    },
    
    treetile = {
        name = "treetile",
        description = "Tree tile layout",
        windows = {
            {x = 8, y = 8, w = 48, h = 24},   -- Top window
            {x = 8, y = 32, w = 24, h = 24},  -- Bottom left
            {x = 32, y = 32, w = 24, h = 24}  -- Bottom right
        }
    },
    
    trizen = {
        name = "trizen",
        description = "Trizen layout",
        windows = {
            {x = 8, y = 8, w = 48, h = 32},   -- Main window
            {x = 8, y = 40, w = 24, h = 16},  -- Bottom left
            {x = 32, y = 40, w = 24, h = 16}  -- Bottom right
        }
    }
}

-- Function to create SVG icon
local function create_svg_icon(layout, output_path)
    local svg_content = string.format([[
<?xml version="1.0" encoding="UTF-8"?>
<svg width="%d" height="%d" xmlns="http://www.w3.org/2000/svg">
  <!-- Purple margin/background -->
  <rect x="0" y="0" width="%d" height="%d" fill="%s"/>
  
  <!-- Black background -->
  <rect x="%d" y="%d" width="%d" height="%d" fill="%s"/>
]], 
        config.icon_size, config.icon_size,
        config.icon_size, config.icon_size, config.purple_margin_bg,
        config.border_width, config.border_width, CONTENT_SIZE, CONTENT_SIZE, config.background
    )
    
    -- Add window representations
    for _, window in ipairs(layout.windows) do
        svg_content = svg_content .. string.format([[
  <!-- Window fill -->
  <rect x="%d" y="%d" width="%d" height="%d" rx="%d" ry="%d" fill="%s"/>
  <!-- Window border -->
  <rect x="%d" y="%d" width="%d" height="%d" rx="%d" ry="%d" fill="none" stroke="%s" stroke-width="%d"/>
]], 
            window.x, window.y, window.w, window.h, config.corner_radius, config.corner_radius, config.window_fill,
            window.x, window.y, window.w, window.h, config.corner_radius, config.corner_radius, config.window_border, config.separator_width
        )
    end
    
    svg_content = svg_content .. "</svg>"
    
    local file = io.open(output_path, "w")
    if file then
        file:write(svg_content)
        file:close()
        print("Created SVG: " .. output_path)
    else
        print("Error creating SVG: " .. output_path)
    end
end

-- Main execution
print("Creating unified layout icons...")

local icons_dir = "../icons/layouts/"
os.execute("mkdir -p " .. icons_dir)

-- Archive previous version if it exists
local archive_dir = "../icons/layouts/archive/"
os.execute("mkdir -p " .. archive_dir)

-- Move existing current icons to archive
for name, layout in pairs(layouts) do
    local current_path = icons_dir .. name .. config.current_suffix .. ".svg"
    local archive_path = archive_dir .. name .. config.current_suffix .. config.archive_suffix .. ".svg"
    
    -- Check if current icon exists and move to archive
    local file = io.open(current_path, "r")
    if file then
        file:close()
        os.execute("mv " .. current_path .. " " .. archive_path)
        print("Archived: " .. archive_path)
    end
end

-- Create new current version icons
for name, layout in pairs(layouts) do
    local svg_path = icons_dir .. name .. config.current_suffix .. ".svg"
    create_svg_icon(layout, svg_path)
end

print("SVG icon generation complete!")
print("To convert to PNG, run: convert icon.svg icon.png")
