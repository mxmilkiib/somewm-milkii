-- tabbed - i3-style tabbed layout
-- All clients share the full workarea. Only the focused client is visible;
-- others are placed off-screen. Cycling focus brings a different client
-- to the front.

local math = math
local ipairs = ipairs

local capi = { client = client }

local tabbed = {}
tabbed.name = "tabbed"
tabbed.need_focus_update = true

function tabbed.arrange(p)
    local wa = p.workarea
    local cls = p.clients
    if #cls == 0 then return end

    local focus = capi.client.focus
    for _, c in ipairs(cls) do
        if c == focus then
            p.geometries[c] = {
                x = wa.x, y = wa.y,
                width = math.max(1, wa.width),
                height = math.max(1, wa.height),
            }
        else
            -- place off-screen so they are not visible
            p.geometries[c] = {
                x = wa.x + wa.width + 9999, y = wa.y,
                width = 1, height = 1,
            }
        end
    end
end

return tabbed
