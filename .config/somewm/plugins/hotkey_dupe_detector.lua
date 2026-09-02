-- // MARK: DUPLICATE HOTKEY DETECTOR
-- ################################################################################
-- duplicate hotkey detector plugin for awesome wm
-- detects and reports duplicate keybindings on startup

local awful = require("awful")
local naughty = require("naughty")
local gears = require("gears")

local M = {}

-- convert modifiers table to string for comparison
local function modifiers_to_string(modifiers)
    if not modifiers or type(modifiers) ~= "table" then
        return ""
    end
    
    local mod_copy = {}
    for _, mod in ipairs(modifiers) do
        table.insert(mod_copy, tostring(mod))
    end
    table.sort(mod_copy)
    return table.concat(mod_copy, "+")
end

-- extract hotkey information from awful.key objects
local function extract_hotkey_info(key_obj)
    if not key_obj or type(key_obj) ~= "table" then
        return nil
    end
    
    -- try to access the key properties (awful.key internal structure)
    local modifiers = key_obj.modifiers or {}
    local key = key_obj.key or key_obj[2] -- fallback for different structures
    local description = ""
    local group = ""
    
    -- extract description and group if available
    if key_obj.description then
        if type(key_obj.description) == "table" then
            description = key_obj.description.description or ""
            group = key_obj.description.group or ""
        else
            description = tostring(key_obj.description)
        end
    end
    
    if not key then
        return nil
    end
    
    return {
        modifiers = modifiers,
        key = tostring(key),
        mod_string = modifiers_to_string(modifiers),
        description = description,
        group = group,
        combo = modifiers_to_string(modifiers) .. "+" .. tostring(key)
    }
end

-- check for duplicate hotkeys in a keybinding table
function M.check_duplicates(globalkeys, clientkeys)
    local duplicates = {}
    local seen_combos = {}
    local all_keys = {}
    
    -- collect all global keys
    if globalkeys then
        for _, key_obj in ipairs(globalkeys) do
            local info = extract_hotkey_info(key_obj)
            if info then
                table.insert(all_keys, {info = info, type = "global"})
            end
        end
    end
    
    -- collect all client keys
    if clientkeys then
        for _, key_obj in ipairs(clientkeys) do
            local info = extract_hotkey_info(key_obj)
            if info then
                table.insert(all_keys, {info = info, type = "client"})
            end
        end
    end
    
    -- check for duplicates
    for _, key_data in ipairs(all_keys) do
        local combo = key_data.info.combo
        if seen_combos[combo] then
            -- found duplicate
            if not duplicates[combo] then
                duplicates[combo] = {seen_combos[combo]}
            end
            table.insert(duplicates[combo], key_data)
        else
            seen_combos[combo] = key_data
        end
    end
    
    return duplicates
end

-- format duplicate information for display
local function format_duplicates(duplicates)
    local lines = {}
    local count = 0
    
    for combo, entries in pairs(duplicates) do
        count = count + 1
        table.insert(lines, string.format("• %s:", combo))
        
        for _, entry in ipairs(entries) do
            local desc = entry.info.description ~= "" and entry.info.description or "no description"
            local group = entry.info.group ~= "" and string.format(" [%s]", entry.info.group) or ""
            table.insert(lines, string.format("  - %s: %s%s", entry.type, desc, group))
        end
        table.insert(lines, "")
    end
    
    return table.concat(lines, "\n"), count
end

-- show orange notification with duplicate hotkeys
function M.notify_duplicates(globalkeys, clientkeys)
    local duplicates = M.check_duplicates(globalkeys, clientkeys)
    
    if next(duplicates) then
        local message, count = format_duplicates(duplicates)
        
        naughty.notify({
            title = string.format("⚠️ duplicate hotkeys detected (%d)", count),
            text = message,
            bg = "#FF8C00",  -- orange background
            fg = "#000000",  -- black text for contrast
            timeout = 0,     -- persistent notification
            width = 500,
            position = "bottom_middle",
            border_width = 2,
            border_color = "#FF4500"  -- darker orange border
        })
        
        return true, count
    else
        -- -- optional: show success notification
        -- naughty.notify({
        --     title = "✅ hotkey check complete",
        --     text = "no duplicate hotkeys found",
        --     bg = "#32CD32",  -- green background
        --     fg = "#000000",  -- black text
        --     timeout = 3,
        --     position = "bottom_middle"
        -- })
        
        return false, 0
    end
end

return M
