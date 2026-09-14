-- tatami - Tatami-mat inspired layout
-- Arranges up to 5 clients in a pattern inspired by traditional tatami
-- mat arrangements. Extra clients stack into the smallest cell.
--
-- 1 client: full screen
-- 2 clients: left/right halves
-- 3 clients: top half split, bottom full width
-- 4 clients: four quadrants
-- 5 clients: top half split, bottom-left full, bottom-right split

local math = math
local ipairs = ipairs

local tatami = {}
tatami.name = "tatami"

function tatami.arrange(p)
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
    elseif n == 2 then
        p.geometries[cls[1]] = { x = wa.x, y = wa.y, width = math.max(1, half_w), height = math.max(1, wa.height) }
        p.geometries[cls[2]] = { x = wa.x + half_w, y = wa.y, width = math.max(1, right_w), height = math.max(1, wa.height) }
    elseif n == 3 then
        p.geometries[cls[1]] = { x = wa.x, y = wa.y, width = math.max(1, half_w), height = math.max(1, half_h) }
        p.geometries[cls[2]] = { x = wa.x + half_w, y = wa.y, width = math.max(1, right_w), height = math.max(1, half_h) }
        p.geometries[cls[3]] = { x = wa.x, y = wa.y + half_h, width = math.max(1, wa.width), height = math.max(1, bottom_h) }
    elseif n == 4 then
        p.geometries[cls[1]] = { x = wa.x, y = wa.y, width = math.max(1, half_w), height = math.max(1, half_h) }
        p.geometries[cls[2]] = { x = wa.x + half_w, y = wa.y, width = math.max(1, right_w), height = math.max(1, half_h) }
        p.geometries[cls[3]] = { x = wa.x, y = wa.y + half_h, width = math.max(1, half_w), height = math.max(1, bottom_h) }
        p.geometries[cls[4]] = { x = wa.x + half_w, y = wa.y + half_h, width = math.max(1, right_w), height = math.max(1, bottom_h) }
    else
        -- 5+: top half split, bottom-left full, bottom-right split for extras
        p.geometries[cls[1]] = { x = wa.x, y = wa.y, width = math.max(1, half_w), height = math.max(1, half_h) }
        p.geometries[cls[2]] = { x = wa.x + half_w, y = wa.y, width = math.max(1, right_w), height = math.max(1, half_h) }
        p.geometries[cls[3]] = { x = wa.x, y = wa.y + half_h, width = math.max(1, half_w), height = math.max(1, bottom_h) }

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
end

return tatami
