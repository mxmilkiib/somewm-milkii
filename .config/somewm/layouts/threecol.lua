-- threecol - Three-column layout
-- Master window in the center, slave windows split between left and right
-- columns. Master width is controlled by master_width_factor.

local math = math
local ipairs = ipairs

local threecol = {}
threecol.name = "threecol"

function threecol.arrange(p)
    local t = p.tag
    if not t and p.screen then
        local s = p.screen and screen[p.screen]
        if s then t = s.selected_tag end
    end
    local wa = p.workarea
    local cls = p.clients
    if #cls == 0 then return end

    local mwfact = (t and t.master_width_factor) or 0.5
    local main_w = math.floor(wa.width * mwfact)
    local slave_w = math.floor((wa.width - main_w) / 2)
    local right_w = wa.width - main_w - slave_w

    -- master (first client) in center
    p.geometries[cls[1]] = {
        x = wa.x + slave_w, y = wa.y,
        width = math.max(1, main_w),
        height = math.max(1, wa.height),
    }

    if #cls <= 1 then return end

    -- split remaining clients into left and right columns
    local left = {}
    local right = {}
    for i = 2, #cls do
        if #left <= #right then left[#left + 1] = cls[i]
        else right[#right + 1] = cls[i] end
    end

    local function tile_column(clients, x, w)
        if #clients == 0 then return end
        local each = math.floor(wa.height / #clients)
        for i, c in ipairs(clients) do
            local y = wa.y + (i - 1) * each
            local h = (i == #clients) and (wa.y + wa.height - y) or each
            p.geometries[c] = {
                x = x, y = y,
                width = math.max(1, w),
                height = math.max(1, h),
            }
        end
    end

    tile_column(left, wa.x, slave_w)
    tile_column(right, wa.x + slave_w + main_w, right_w)
end

return threecol
