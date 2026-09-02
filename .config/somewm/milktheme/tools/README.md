# Layout Icon Generator

This directory contains the build tool for generating consistent SVG layout icons for the milktheme.

## Usage

```bash
cd ~/.config/awesome/milktheme/tools/
lua generate_layout_icons.lua
```

## Features

- **Theme Integration**: Reads colors and dimensions from `../theme.lua`
- **Consistent Styling**: Generates unified visual style across all layout icons
- **Version Management**: Archives previous versions before generating new ones
- **SVG Output**: Creates scalable vector graphics for crisp display

## Configuration

Icon appearance is controlled by the `layout_icon_config` section in `theme.lua`:

```lua
theme.layout_icon_config = {
    -- Colors
    purple_margin_bg = "#623997",
    window_fill = "#CCCCCC",
    window_border = "#AAAAAA", 
    background = "#000000",
    
    -- Dimensions
    icon_size = 64,
    border_width = 2,
    corner_radius = 1,
    separator_width = 1,
    
    -- File naming
    current_suffix = "_alt",
    archive_suffix = "_alt_v2"
}
```

## Output

Generated icons are saved to `../icons/layouts/` with the current suffix.
Previous versions are archived to `../icons/layouts/archive/`.