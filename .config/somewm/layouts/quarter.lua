-- quarter - Four-quadrant layout
-- First four clients each get a quadrant of the screen.
-- Additional clients stack into the bottom-right quadrant.

local math = math
local ipairs = ipairs

local quarter = {}
quarter.name = "quarter"

function quarter.arrange(p)
    local wa = p.workarea
    local cls = p.clients
    local n = #cls
    if n == 0 then return end

    local half_w = math.floor(wa.width / 2)
    local half_h = math.floor(wa.height / 2)
    local right_w = wa.width - half_w
    local bottom_h = wa.height - half_h

    if n == 1 then
        p.geometries[cls[1]] = { x = wa.x, y = wa.y, width = math.max(1, wa.width), height = math.max(1, wa.height) }
        return
    end

    if n == 2 then
        p.geometries[cls[1]] = { x = wa.x, y = wa.y, width = math.max(1, half_w), height = math.max(1, wa.height) }
        p.geometries[cls[2]] = { x = wa.x + half_w, y = wa.y, width = math.max(1, right_w), height = math.max(1, wa.height) }
        return
    end

    if n == 3 then
        p.geometries[cls[1]] = { x = wa.x, y = wa.y, width = math.max(1, half_w), height = math.max(1, half_h) }
        p.geometries[cls[2]] = { x = wa.x + half_w, y = wa.y, width = math.max(1, right_w), height = math.max(1, half_h) }
        p.geometries[cls[3]] = { x = wa.x, y = wa.y + half_h, width = math.max(1, wa.width), height = math.max(1, bottom_h) }
        return
    end

    -- 4+ clients: four quadrants, extras stack in bottom-right
    p.geometries[cls[1]] = { x = wa.x, y = wa.y, width = math.max(1, half_w), height = math.max(1, half_h) }
    p.geometries[cls[2]] = { x = wa.x + half_w, y = wa.y, width = math.max(1, right_w), height = math.max(1, half_h) }
    p.geometries[cls[3]] = { x = wa.x, y = wa.y + half_h, width = math.max(1, half_w), height = math.max(1, bottom_h) }

    -- remaining clients stack vertically in bottom-right quadrant
    local extras = {}
    for i = 4, n do extras[#extras + 1] = cls[i] end
    local each = math.floor(bottom_h / #extras)
    for i, c in ipairs(extras) do
        local y = wa.y + half_h + (i - 1) * each
        local h = (i == #extras) and (wa.y + wa.height - y) or each
        p.geometries[c] = {
            x = wa.x + half_w, y = y,
            width = math.max(1, right_w),
            height = math.max(1, h),
        }
    end
end

return quarter
