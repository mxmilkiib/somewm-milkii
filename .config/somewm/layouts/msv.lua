-- msv - Master-stack-vertical
-- Master on the left, all slaves in a single vertical column on the right.
-- Distinct from awful.tile: slaves share one column rather than stacking
-- horizontally first. Master width is controlled by master_width_factor.

local math = math
local ipairs = ipairs

local tag = require("awful.tag")

local msv = {}
msv.name = "msv"

function msv.arrange(p)
    local t = p.tag
    if not t and p.screen then
        local s = p.screen and screen[p.screen]
        if s then t = s.selected_tag end
    end
    local wa = p.workarea
    local cls = p.clients
    if #cls == 0 then return end

    local mwfact = (t and t.master_width_factor) or 0.5
    local nmaster = math.min((t and t.master_count or 1), #cls)
    local nslaves = #cls - nmaster

    -- no slaves: master fills everything
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

    local master_w = math.floor(wa.width * mwfact)
    local slave_w = wa.width - master_w

    -- master column: stack masters vertically
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

    -- slaves: single vertical column on the right
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

return msv
