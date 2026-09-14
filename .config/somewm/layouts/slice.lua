-- slice - Horizontal slice layout
-- Each window gets a full-width horizontal slice of the screen.
-- All slices are equal height. Simple and predictable.

local math = math
local ipairs = ipairs

local slice = {}
slice.name = "slice"

function slice.arrange(p)
    local wa = p.workarea
    local cls = p.clients
    local n = #cls
    if n == 0 then return end

    local each = math.floor(wa.height / n)
    for i, c in ipairs(cls) do
        local y = wa.y + (i - 1) * each
        local h = (i == n) and (wa.y + wa.height - y) or each
        p.geometries[c] = {
            x = wa.x,
            y = y,
            width = math.max(1, wa.width),
            height = math.max(1, h),
        }
    end
end

return slice
