--[[
    threefifths layout

    Adaptive layout where the focused (active) window occupies 3/5 of the
    screen's long axis and the full length of the short axis, so the active
    rectangle always covers 3/5 of the screen regardless of its size or
    orientation.

    - One window: the active rectangle is centred on the long axis.
    - Two or more: the active window is pushed to the start side (left on
      landscape, top on portrait) and the remaining slaves share the 2/5
      region, tiled equally along the short axis. A newly opened second
      window therefore pushes the main window aside and itself takes 2/5.

    Licensed under GNU General Public License v2
--]]

local ipairs, math = ipairs, math

local capi = {
    client = client,
    screen = screen,
}

local threefifths = {}
threefifths.name = "threefifths"

-- Do not re-arrange on focus change: the master (3/5) window is determined
-- by tag order (first client), not by which window is focused.
threefifths.need_focus_update = false

-- Active window covers 3/5 of the long axis.
local RATIO = 3 / 5

local function get_screen(s)
    return s and capi.screen[s]
end

function threefifths.arrange(p)
    local wa  = p.workarea
    local cls = p.clients
    if #cls == 0 then return end

    -- Master is the first client in tag order, not the focused window.
    local focus = cls[1]
    if not focus then return end
    if focus.floating then
        -- skip floating clients to find the first tiled one
        focus = nil
        for _, c in ipairs(cls) do
            if not c.floating then focus = c; break end
        end
    end
    if not focus then return end

    -- Long axis: landscape splits along width, portrait along height.
    local horizontal = wa.width >= wa.height
    local main_dim   = horizontal and wa.width or wa.height
    local main_size  = math.floor(main_dim * RATIO)
    local slave_size = main_dim - main_size

    local g = {}
    if #cls == 1 then
        -- Centred 3/5 of the long axis, full short axis.
        if horizontal then
            g.x      = wa.x + math.floor((wa.width - main_size) / 2)
            g.y      = wa.y
            g.width  = main_size
            g.height = wa.height
        else
            g.x      = wa.x
            g.y      = wa.y + math.floor((wa.height - main_size) / 2)
            g.width  = wa.width
            g.height = main_size
        end
    else
        -- Active pushed to the start side; slaves fill the 2/5 region.
        if horizontal then
            g.x      = wa.x
            g.y      = wa.y
            g.width  = main_size
            g.height = wa.height
        else
            g.x      = wa.x
            g.y      = wa.y
            g.width  = wa.width
            g.height = main_size
        end
    end
    g.width  = math.max(g.width, 1)
    g.height = math.max(g.height, 1)
    p.geometries[focus] = g

    if #cls <= 1 then return end

    -- Slaves share the 2/5 region, tiled equally along the short axis,
    -- preserving tag order with the focused client removed.
    local slaves = {}
    for _, c in ipairs(cls) do
        if c ~= focus then slaves[#slaves + 1] = c end
    end
    local n = #slaves
    if n == 0 then return end

    if horizontal then
        local sx   = wa.x + main_size
        local each = math.floor(wa.height / n)
        for i, c in ipairs(slaves) do
            local sy = wa.y + (i - 1) * each
            local sh = (i == n) and (wa.y + wa.height - sy) or each
            p.geometries[c] = {
                x      = sx,
                y      = sy,
                width  = slave_size,
                height = math.max(sh, 1),
            }
        end
    else
        local sy   = wa.y + main_size
        local each = math.floor(wa.width / n)
        for i, c in ipairs(slaves) do
            local sx = wa.x + (i - 1) * each
            local sw = (i == n) and (wa.x + wa.width - sx) or each
            p.geometries[c] = {
                x      = sx,
                y      = sy,
                width  = math.max(sw, 1),
                height = slave_size,
            }
        end
    end
end

return threefifths
