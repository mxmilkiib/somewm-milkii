-- widetile - Wide-master tile
-- Like awful.tile but the master always gets 2/3 of the screen width
-- regardless of master_width_factor. Slaves stack vertically on the right.
-- Master count is still respected.

local math = math
local ipairs = ipairs

local tag = require("awful.tag")

local widetile = {}
widetile.name = "widetile"

local MASTER_RATIO = 2 / 3

function widetile.arrange(p)
    local t = p.tag
    if not t and p.screen then
        local s = p.screen and screen[p.screen]
        if s then t = s.selected_tag end
    end
    local wa = p.workarea
    local cls = p.clients
    if #cls == 0 then return end

    local nmaster = math.min((t and t.master_count or 1), #cls)
    local nslaves = #cls - nmaster

    if nslaves == 0 then
        for i = 1, nmaster do
            local each = math.floor(wa.height / nmaster)
            local y = wa.y + (i - 1) * each
            local h = (i == nmaster) and (wa.y + wa.height - y) or each
            p.geometries[cls[i]] = {
                x = wa.x, y = y,
                width = math.max(1, wa.width),
                height = math.max(1, h),
            }
        end
        return
    end

    local master_w = math.floor(wa.width * MASTER_RATIO)
    local slave_w = wa.width - master_w

    -- masters stacked vertically on the left
    if nmaster > 0 then
        local each = math.floor(wa.height / nmaster)
        for i = 1, nmaster do
            local y = wa.y + (i - 1) * each
            local h = (i == nmaster) and (wa.y + wa.height - y) or each
            p.geometries[cls[i]] = {
                x = wa.x, y = y,
                width = math.max(1, master_w),
                height = math.max(1, h),
            }
        end
    end

    -- slaves stacked vertically on the right
    local each = math.floor(wa.height / nslaves)
    for i = 1, nslaves do
        local c = cls[i + nmaster]
        local y = wa.y + (i - 1) * each
        local h = (i == nslaves) and (wa.y + wa.height - y) or each
        p.geometries[c] = {
            x = wa.x + master_w, y = y,
            width = math.max(1, slave_w),
            height = math.max(1, h),
        }
    end
end

return widetile
