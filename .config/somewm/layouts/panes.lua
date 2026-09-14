-- panes - Fixed-pane layout
-- Divides the screen into a fixed grid of N panes (default 4, a 2x2 grid).
-- New clients fill the next empty pane in row-major order. Once all panes
-- are full, additional clients stack into the last pane.
-- Pane count is read from tag.gap or defaults to 4.

local math = math
local ipairs = ipairs

local panes = {}
panes.name = "panes"

local DEFAULT_PANES = 4

function panes.arrange(p)
    local t = p.tag
    if not t and p.screen then
        local s = p.screen and screen[p.screen]
        if s then t = s.selected_tag end
    end
    local wa = p.workarea
    local cls = p.clients
    local n = #cls
    if n == 0 then return end

    local npanes = (t and t.gap and t.gap > 0 and t.gap) or DEFAULT_PANES
    -- choose grid dimensions as square as possible
    local cols = math.ceil(math.sqrt(npanes))
    local rows = math.ceil(npanes / cols)
    local cell_w = math.floor(wa.width / cols)
    local cell_h = math.floor(wa.height / rows)

    for i, c in ipairs(cls) do
        if i <= npanes then
            local col = (i - 1) % cols
            local row = math.floor((i - 1) / cols)
            p.geometries[c] = {
                x = wa.x + col * cell_w,
                y = wa.y + row * cell_h,
                width = math.max(1, cell_w),
                height = math.max(1, cell_h),
            }
            -- stretch last column/row to fill
            if col == cols - 1 then
                p.geometries[c].width = math.max(1, wa.x + wa.width - p.geometries[c].x)
            end
            if row == rows - 1 then
                p.geometries[c].height = math.max(1, wa.y + wa.height - p.geometries[c].y)
            end
        else
            -- extras stack into the last pane
            local extras = n - npanes
            local last_col = (npanes - 1) % cols
            local last_row = math.floor((npanes - 1) / cols)
            local base_x = wa.x + last_col * cell_w
            local base_y = wa.y + last_row * cell_h
            local last_w = (last_col == cols - 1) and (wa.x + wa.width - base_x) or cell_w
            local last_h = (last_row == rows - 1) and (wa.y + wa.height - base_y) or cell_h
            local each = math.floor(last_h / (extras + 1))
            local idx = i - npanes + 1
            local y = base_y + (idx - 1) * each
            local h = (idx == extras + 1) and (base_y + last_h - y) or each
            p.geometries[c] = {
                x = base_x, y = y,
                width = math.max(1, last_w),
                height = math.max(1, h),
            }
        end
    end
end

return panes
