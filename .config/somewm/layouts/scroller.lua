-- scroller - Horizontal scrolling layout (niri/paperwm style)
-- Windows are arranged in a horizontal line, each taking the full screen
-- height and a fixed fraction of the width. The focused window is always
-- placed at the left edge of the workarea; windows before it scroll
-- off-screen to the left.

local math = math
local ipairs = ipairs

local capi = { client = client }

local scroller = {}
scroller.name = "scroller"
scroller.need_focus_update = true

-- each window gets this fraction of the workarea width
local WINDOW_RATIO = 0.55

function scroller.arrange(p)
    local wa = p.workarea
    local cls = p.clients
    if #cls == 0 then return end

    local focus = capi.client.focus
    local focus_idx = 1
    for i, c in ipairs(cls) do
        if c == focus then focus_idx = i; break end
    end

    local win_w = math.floor(wa.width * WINDOW_RATIO)

    for i, c in ipairs(cls) do
        local offset = (i - focus_idx) * win_w
        p.geometries[c] = {
            x = wa.x + offset,
            y = wa.y,
            width = math.max(1, win_w),
            height = math.max(1, wa.height),
        }
    end
end

return scroller
