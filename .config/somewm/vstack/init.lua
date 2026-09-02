-- vstack - single-column vertical layout with master on top
-- Master window occupies the top portion (height controlled by
-- master_width_factor), slave windows stack below in a single column,
-- each full width. All windows are resizable:
--   Mod4+h/l adjusts master height (master_width_factor)
--   mouse drag on a border adjusts mwfact or per-client wfact

local math   = math
local ipairs = ipairs

local tag    = require("awful.tag")
local client = require("awful.client")

local capi = {
    screen       = screen,
    mouse        = mouse,
    mousegrabber = mousegrabber,
}

local vstack = {}
vstack.name = "vstack"


-- // MARK: -- arrange


function vstack.arrange(p)
    local t  = p.tag
    if not t and p.screen and capi.screen[p.screen] then
        t = capi.screen[p.screen].selected_tag
    end
    if not t then return end
    local wa = p.workarea
    local cls = p.clients
    if #cls == 0 then return end

    local nmaster  = math.min(t.master_count, #cls)
    local nslaves  = #cls - nmaster
    local mwfact   = t.master_width_factor

    -- per-client resize factors (same mechanism as awful.tile)
    local data = tag.getdata(t).windowfact
    if not data then
        data = {}
        tag.getdata(t).windowfact = data
    end

    -- master area height: full workarea if no slaves, else mwfact portion
    local master_height = wa.height
    if nslaves > 0 then
        master_height = math.floor(wa.height * mwfact)
    end

    -- stack master windows vertically within the master area
    if nmaster > 0 then
        if not data[0] then data[0] = {} end
        local coord       = wa.y
        local unused      = master_height
        local total_fact  = 0
        for i = 1, nmaster do
            data[0][i] = data[0][i] or 1
            total_fact = total_fact + data[0][i]
        end
        for i = 1, nmaster do
            local c = cls[i]
            local h = math.max(1, math.floor(unused * data[0][i] / total_fact))
            p.geometries[c] = { x = wa.x, y = coord, width = wa.width, height = h }
            coord       = coord + h
            unused      = unused - h
            total_fact  = total_fact - data[0][i]
        end
    end

    -- stack slave windows vertically below the master area
    if nslaves > 0 then
        if not data[1] then data[1] = {} end
        local slave_top    = wa.y + master_height
        local slave_height = wa.height - master_height
        local coord        = slave_top
        local unused       = slave_height
        local total_fact   = 0
        for i = 1, nslaves do
            data[1][i] = data[1][i] or 1
            total_fact = total_fact + data[1][i]
        end
        for i = 1, nslaves do
            local c = cls[i + nmaster]
            local h = math.max(1, math.floor(unused * data[1][i] / total_fact))
            p.geometries[c] = { x = wa.x, y = coord, width = wa.width, height = h }
            coord       = coord + h
            unused      = unused - h
            total_fact  = total_fact - data[1][i]
        end
    end
end


-- // MARK: -- mouse-resize


function vstack.mouse_resize_handler(c, _, _, _)
    local wa  = c.screen.workarea
    local t   = c.screen.selected_tag
    local ug  = t.gap or 0
    local g   = c:geometry()

    -- find this client's index among tiled clients to determine
    -- whether its bottom border is the master/slave boundary
    local tiled    = client.tiled(c.screen)
    local nmaster  = math.min(t.master_count, #tiled)
    local c_idx    = nil
    for i, v in ipairs(tiled) do
        if v == c then c_idx = i; break end
    end

    -- last master with slaves below: dragging adjusts mwfact
    -- any other client: dragging adjusts that client's wfact
    local is_master_boundary = c_idx and c_idx == nmaster and nmaster < #tiled

    local cursor = "sb_v_double_arrow"
    -- place cursor at the border being dragged (bottom edge of client)
    local corner_y = g.y + g.height
    if g.height + ug + 15 > wa.height then
        corner_y = g.y + g.height * 0.5
    end
    capi.mouse.coords({ x = g.x + g.width / 2, y = corner_y })

    local prev_coords = {}
    capi.mousegrabber.run(function(coords)
        if not c.valid then return false end
        for _, v in ipairs(coords.buttons) do
            if v then
                prev_coords = { x = coords.x, y = coords.y }
                if is_master_boundary then
                    local fact_y = (coords.y - wa.y) / wa.height
                    t.master_width_factor = math.min(math.max(fact_y, 0.01), 0.99)
                else
                    local wfact
                    if (g.y + g.height + ug + 15) > (wa.y + wa.height) then
                        wfact = (g.y + g.height - coords.y) / wa.height
                    else
                        wfact = (coords.y - g.y) / wa.height
                    end
                    client.setwfact(math.min(math.max(wfact, 0.01), 0.99), c)
                end
                return true
            end
        end
        return (prev_coords.x == coords.x) and (prev_coords.y == coords.y)
    end, cursor)
end


function vstack.skip_gap(nclients, t)
    return nclients == 1 and t.master_fill_policy == "expand"
end

return vstack
