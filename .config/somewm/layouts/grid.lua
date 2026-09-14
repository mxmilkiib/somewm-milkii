-- grid - Equal-area grid layout
-- Distributes clients into a row-by-column grid where every cell is the
-- same size. Columns and rows are chosen to be as square as possible.

local math = math
local ipairs = ipairs

local grid = {}
grid.name = "grid"

function grid.arrange(p)
    local wa = p.workarea
    local cls = p.clients
    local n = #cls
    if n == 0 then return end

    -- choose columns so cells are as square as possible
    local cols = math.ceil(math.sqrt(n))
    local rows = math.ceil(n / cols)
    local cell_w = math.floor(wa.width / cols)
    local cell_h = math.floor(wa.height / rows)

    for i, c in ipairs(cls) do
        local col = (i - 1) % cols
        local row = math.floor((i - 1) / cols)
        local is_last_row = row == rows - 1
        local last_row_count = n - (rows - 1) * cols
        local w = cell_w
        if is_last_row and last_row_count < cols then
            w = math.floor(wa.width / last_row_count)
        end
        p.geometries[c] = {
            x = wa.x + col * cell_w,
            y = wa.y + row * cell_h,
            width = math.max(1, w),
            height = math.max(1, cell_h),
        }
        -- stretch last cell in each row to fill remaining width
        if col == cols - 1 or (is_last_row and i == n) then
            p.geometries[c].width = math.max(1, wa.x + wa.width - p.geometries[c].x)
        end
        -- stretch last row to fill remaining height
        if row == rows - 1 then
            p.geometries[c].height = math.max(1, wa.y + wa.height - p.geometries[c].y)
        end
    end
end

return grid
