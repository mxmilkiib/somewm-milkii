-- plugins/awesome_dnd.lua
-- shim to maintain backward compatibility; implementation moved to dnd_to_tag.lua
local M = require("plugins.dnd_to_tag")

function M.update_hover_from_mouse()
    local mc = mouse.coords()
    if not mc then
        M.clear_hover()
        return
    end

    local found_tag = nil
    local found_widget = nil

    -- improved heuristic: if mouse is over the top wibox for a screen and a taglist exists,
    -- map the mouse x-position proportionally to a tag index. this avoids relying on
    -- private widget internals and works even when mouse::enter events are grabbed.
    for s in screen do
        if s.mywibox and s.mywibox.visible then
            local wibox_geo = s.mywibox:geometry()
            if mc.x >= wibox_geo.x and mc.x <= wibox_geo.x + wibox_geo.width and
               mc.y >= wibox_geo.y and mc.y <= wibox_geo.y + wibox_geo.height then
                if s.mytaglist and s.tags and #s.tags > 0 then
                    local rel_x = mc.x - wibox_geo.x
                    local ratio = math.min(math.max(rel_x / math.max(wibox_geo.width, 1), 0), 1)
                    local idx = math.floor(ratio * #s.tags) + 1
                    if idx < 1 then idx = 1 end
                    if idx > #s.tags then idx = #s.tags end
                    found_tag = s.tags[idx]
                end
            end
        end
        if found_tag then break end
    end

    if found_tag then
        -- attempt to get a tag widget reference via shimmer registration (optional)
        local ok, integrations = pcall(require, "plugins.shimmer.integrations")
        if ok and integrations and integrations.get_phase_offsets then
            -- access registered taglist mapping if available
            local screen_index = found_tag.screen and found_tag.screen.index or nil
            if screen_index and integrations._get_registered_widgets then
                local widgets = integrations._get_registered_widgets and integrations._get_registered_widgets()
                if widgets and widgets.taglist and widgets.taglist[screen_index] then
                    found_widget = widgets.taglist[screen_index][found_tag]
                end
            end
        end
        M.set_hover(found_tag, found_widget)
    else
        M.clear_hover()
    end
end

return M
