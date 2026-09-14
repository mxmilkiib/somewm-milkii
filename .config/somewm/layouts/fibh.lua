-- fibh - Fibonacci-horizontal
-- Like dwindle but each split is made on the long axis of the current
-- rectangle, producing a more balanced spiral than the fixed-axis dwindle.

local math = math
local ipairs = ipairs

local fibh = {}
fibh.name = "fibh"

local function arrange_recursive(cls, wa, geo_table, depth)
    if #cls == 0 then return end
    if #cls == 1 then
        geo_table[cls[1]] = {
            x = wa.x, y = wa.y,
            width = math.max(1, wa.width),
            height = math.max(1, wa.height),
        }
        return
    end

    local mid = math.ceil(#cls / 2)
    local first_half = {}
    local second_half = {}
    for i = 1, #cls do
        if i <= mid then first_half[#first_half + 1] = cls[i]
        else second_half[#second_half + 1] = cls[i] end
    end

    -- split on the long axis
    local horizontal = wa.width >= wa.height
    if horizontal then
        local half_w = math.floor(wa.width / 2)
        arrange_recursive(first_half,
            { x = wa.x, y = wa.y, width = half_w, height = wa.height },
            geo_table, depth + 1)
        arrange_recursive(second_half,
            { x = wa.x + half_w, y = wa.y, width = wa.width - half_w, height = wa.height },
            geo_table, depth + 1)
    else
        local half_h = math.floor(wa.height / 2)
        arrange_recursive(first_half,
            { x = wa.x, y = wa.y, width = wa.width, height = half_h },
            geo_table, depth + 1)
        arrange_recursive(second_half,
            { x = wa.x, y = wa.y + half_h, width = wa.width, height = wa.height - half_h },
            geo_table, depth + 1)
    end
end

function fibh.arrange(p)
    local wa = p.workarea
    local cls = p.clients
    if #cls == 0 then return end
    arrange_recursive(cls, wa, p.geometries, 0)
end

return fibh
