-- expose - Exposé-style overview layout
-- Scales all clients down into a grid of equal-sized thumbnails, similar
-- to macOS Exposé or GNOME overview. Every window gets an equal cell.
-- Clicking a cell focuses that client (handled by normal click-to-focus).
--
-- This is a pure layout: it arranges real clients into a grid. For a true
-- live-thumbnail overlay with click-to-zoom, a popup widget would be needed,
-- but this layout gives the visual effect of Exposé as a tiling mode.

local math = math
local ipairs = ipairs

local expose = {}
expose.name = "expose"

function expose.arrange(p)
    local wa = p.workarea
    local cls = p.clients
    local n = #cls
    if n == 0 then return end

    -- choose a grid that keeps cells as square as possible,
    -- leaving a small margin between cells for visual separation
    local cols = math.ceil(math.sqrt(n))
    local rows = math.ceil(n / cols)
    local gap = 4
    local avail_w = wa.width - gap * (cols + 1)
    local avail_h = wa.height - gap * (rows + 1)
    local cell_w = math.floor(avail_w / cols)
    local cell_h = math.floor(avail_h / rows)

    for i, c in ipairs(cls) do
        local col = (i - 1) % cols
        local row = math.floor((i - 1) / cols)
        local is_last_row = row == rows - 1
        local last_row_count = n - (rows - 1) * cols

        local x = wa.x + gap + col * (cell_w + gap)
        local y = wa.y + gap + row * (cell_h + gap)
        local w = cell_w
        local h = cell_h

        -- stretch last cell in each row to fill remaining width
        if col == cols - 1 then
            w = wa.x + wa.width - gap - x
        end
        -- stretch last row to fill remaining height
        if is_last_row then
            h = wa.y + wa.height - gap - y
        end
        -- if last row has fewer cells, center them
        if is_last_row and last_row_count < cols then
            local total_w = last_row_count * cell_w + (last_row_count - 1) * gap
            local offset = math.floor((wa.width - total_w) / 2)
            x = wa.x + offset + col * (cell_w + gap)
            w = cell_w
        end

        p.geometries[c] = {
            x = x, y = y,
            width = math.max(1, w),
            height = math.max(1, h),
        }
    end
end

return expose
