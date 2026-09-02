-- plugins/keystats.lua
--
-- AwesomeWM plugin: keybind usage statistics across sessions
--
-- OVERVIEW
--   Collects usage counts per keybinding without altering behavior. It wraps awful.key at
--   definition time and increments a counter each time a binding is used. Data persists across
--   sessions in a tiny Lua DB file.
--
-- INSTALLATION
--   1) Place this file at: ~/.config/awesome/plugins/keystats.lua
--   2) Load it EARLY in your rc.lua (before defining keybindings):
--        do
--            -- Instrument all keybindings for usage stats
--            pcall(require, "plugins.keystats")
--        end
--
-- HOW IT WORKS
--   - Hooks awful.key (both table-form and positional-form APIs) to wrap on_press (or on_release
--     when on_press is absent) and increment usage on each activation.
--   - Identifies a keybind by mods+key (e.g. "Mod4+Shift|h"). Group/description are kept as
--     metadata so counts are not fragmented across identical bindings with different labels.
--   - Flushes changes to an on-disk DB every 10s and on Awesome exit, using atomic rename.
--
-- DB FILE
--   Path: ~/.config/awesome/keystats_db.lua
--   Format: a Lua table keyed by "mods|key" with fields:
--     count:number, mods:string, key:string, group?:string, desc?:string,
--     first_seen:unix_ts, last_seen:unix_ts
--
-- CLI
--   A companion CLI script is provided at plugins/keystats_cli.lua. Example usages:
--     lua ~/.config/awesome/plugins/keystats_cli.lua top 30
--     lua ~/.config/awesome/plugins/keystats_cli.lua underused 50 --group layout
--     lua ~/.config/awesome/plugins/keystats_cli.lua by-mods 15
--     lua ~/.config/awesome/plugins/keystats_cli.lua concentration 10
--     lua ~/.config/awesome/plugins/keystats_cli.lua notify-top 10  (via awesome-client)
--
-- PUBLIC API (require("plugins.keystats"))
--   .db_path -> string : DB file path
--   .flush()           : Force flush to disk
--   .snapshot() -> table : Copy of the DB table (id -> record) for safe read-only use
--   .rank_top(n, filters?)           -> rows[]
--   .rank_underused(n, filters?)     -> rows[]
--   .rank_recent(n, filters?)        -> rows[]
--   .rank_stale(n, filters?)         -> rows[]
--   .aggregate_by(field, filters?)   -> { key=..., total=..., items=... }[]  -- field: "group"|"mods"
--   .concentration(k, filters?)      -> { share=0.0..1.0, top=rows[], total_count=int }
--   .notify_top(n, filters?)         : Desktop notification with top-N bindings
--   .group_behavior[group]           : Optional behavior per group: "post" (default), "release", or "skip"
--
-- THIRD-PARTY MODULES
--   Any keybinds defined via awful.key by third-party modules (e.g., Collision) are recorded by default
--   with post-callback, deferred updates. For maximal transparency with keygrabber-heavy modules, set
--   group_behavior["Collision"] = "release" to count only on key release while leaving on_press untouched.
--
-- NOTES
--   - Safe by design: if DB cannot be written, the plugin fails silently and never blocks keys.
--   - Errors propagate unchanged: the original callback runs first; if it errors, stats won’t be updated.
--   - Migration merges older IDs that included group/desc into the current mods|key identity.
--
-- SUGGESTED ANALYSES (supported via CLI and API)
--   - Most/least used overall: identify high-value and low-value bindings to refine layout.
--   - Underused keys by group: prune or reassign bindings with near-zero usage in a group.
--   - Modifiers heatmap: aggregate by modifier combo (e.g., Mod4, Mod4+Shift, Mod4+Ctrl).
--   - Staleness audit: surface bindings not used recently (e.g., stale 30) to clean up rot.
--   - Concentration ratio: what % of usage is captured by top K bindings (habit concentration).
--   - Recency: recently used keys to understand active workflows or regressions post-changes.

local gfs = require("gears.filesystem")
local gears = require("gears")
local awful = require("awful")
local naughty = require("naughty")

local M = {}

-- Guard: only hook once per Awesome session
if rawget(awful, "_keystats_hooked") then
    return M
end
awful._keystats_hooked = true

local config_dir = gfs.get_configuration_dir()
local DB_PATH = config_dir .. "keystats_db.lua"

local stats = {}
local dirty = false
local EXCLUDE_GROUPS = {}
-- Behavior per group:
--  nil or "post"  -> wrap on_press (or on_release if only release)
--  "release"      -> do NOT wrap on_press; wrap existing on_release or inject a counting on_release
--  "skip"         -> do not instrument this group's bindings
local GROUP_BEHAVIOR = {}

local function now()
    return os.time()
end

local function safe_dofile(path)
    local ok, data = pcall(dofile, path)
    if ok and type(data) == "table" then return data end
    return {}
end

-- Serialize a Lua string safely
local function q(s)
    return string.format("%q", tostring(s or ""))
end

local function write_db()
    if not dirty then return end
    -- Atomic write: write to tmp then rename
    local tmp = DB_PATH .. ".tmp"
    local f, err = io.open(tmp, "w")
    if not f then
        -- Cannot write; give up silently to avoid breaking key behavior
        return
    end
    f:write("return {\n")
    for id, rec in pairs(stats) do
        local mods_concat
        if type(rec.mods) == "table" then
            mods_concat = table.concat(rec.mods or {}, "+")
        else
            mods_concat = tostring(rec.mods or "")
        end
        f:write("  [", q(id), "] = {\n")
        f:write("    count = ", tostring(rec.count or 0), ",\n")
        f:write("    key = ", q(rec.key), ",\n")
        f:write("    mods = ", q(mods_concat), ",\n")
        f:write("    desc = ", q(rec.desc), ",\n")
        f:write("    group = ", q(rec.group), ",\n")
        f:write("    first_seen = ", tostring(rec.first_seen or 0), ",\n")
        f:write("    last_seen = ", tostring(rec.last_seen or 0), ",\n")
        f:write("  },\n")
    end
    f:write("}\n")
    f:close()
    os.rename(tmp, DB_PATH)
    dirty = false
end

-- Periodic flush
local flush_timer = gears.timer({ timeout = 10, autostart = true, callback = write_db })

local function normalize_mods(mods)
    local t = {}
    if type(mods) == "table" then
        for _, m in ipairs(mods) do
            t[#t+1] = tostring(m)
        end
    end
    table.sort(t)
    return t
end

local function mods_to_key(mods)
    return table.concat(mods or {}, "+")
end

local function compute_id(mods, key)
    local mods_key = mods_to_key(mods)
    return (mods_key or "") .. "|" .. (tostring(key) or "?")
end

local function ensure_record(mods, key, group, desc)
    local id = compute_id(mods, key)
    local rec = stats[id]
    if not rec then
        rec = {
            count = 0,
            key = key,
            mods = mods,
            desc = desc,
            group = group,
            first_seen = now(),
            last_seen = 0,
        }
        stats[id] = rec
        dirty = true
    else
        -- Keep descriptive fields up to date if they change
        rec.key = rec.key or key
        rec.mods = rec.mods or mods
        rec.desc = rec.desc or desc
        rec.group = rec.group or group
    end
    return rec, id
end

local function update_stats_deferred(rec)
    if gears and gears.timer and gears.timer.delayed_call then
        gears.timer.delayed_call(function()
            rec.count = (rec.count or 0) + 1
            rec.last_seen = now()
            dirty = true
        end)
    else
        rec.count = (rec.count or 0) + 1
        rec.last_seen = now()
        dirty = true
    end
end

local function wrap_fn(fn, rec)
    if type(fn) ~= "function" then return fn end
    return function(...)
        -- Execute original callback first to keep behavior identical
        local r1, r2, r3, r4, r5 = fn(...)
        -- Only update stats if the callback returns without error, and defer to next tick
        update_stats_deferred(rec)
        return r1, r2, r3, r4, r5
    end
end

-- Hook awful.key so that created key objects have wrapped callbacks
local function hook_awful_key()
    local original_key = awful.key

    -- Load existing DB once we are sure gears is available
    stats = safe_dofile(DB_PATH)
    -- Migration: if keys contain more than one '|' segment, merge into mods|key form
    do
        local migrated = {}
        local changed = false
        for id, rec in pairs(stats) do
            local mods, key = id:match("^([^|]*)|([^|]*)")
            if mods and key then
                local new_id = mods .. "|" .. key
                if new_id ~= id then
                    local tgt = migrated[new_id]
                    if not tgt then
                        -- Copy rec but ensure fields are typed
                        tgt = {
                            count = rec.count or 0,
                            key = rec.key or key,
                            mods = rec.mods or mods,
                            desc = rec.desc,
                            group = rec.group,
                            first_seen = rec.first_seen or 0,
                            last_seen = rec.last_seen or 0,
                        }
                        migrated[new_id] = tgt
                    else
                        -- Merge counts and timestamps
                        tgt.count = (tgt.count or 0) + (rec.count or 0)
                        tgt.first_seen = math.min(tgt.first_seen or tgt.last_seen or now(), rec.first_seen or rec.last_seen or now())
                        tgt.last_seen = math.max(tgt.last_seen or 0, rec.last_seen or 0)
                        -- Prefer non-nil desc/group
                        if (not tgt.desc or tgt.desc == "") and rec.desc then tgt.desc = rec.desc end
                        if (not tgt.group or tgt.group == "") and rec.group then tgt.group = rec.group end
                    end
                    changed = true
                else
                    migrated[new_id] = rec
                end
            else
                migrated[id] = rec
            end
        end
        if changed then
            stats = migrated
            dirty = true
        end
    end

    awful.key = function(a, b, c, d, e)
        -- Table-form API: awful.key{ modifiers=..., key=..., on_press=..., on_release=..., description=..., group=... }
        if type(a) == "table" and (a.key or a.on_press or a.on_release or a.modifiers) then
            -- Shallow-copy to avoid mutating user-provided tables
            local t = {}
            for k, v in pairs(a) do t[k] = v end
            local mods = normalize_mods(t.modifiers or {})
            local key = t.key
            local desc = t.description
            local group = t.group
            -- Determine behavior for this group
            local behavior = (group and (GROUP_BEHAVIOR[group] or (EXCLUDE_GROUPS[group] and "skip"))) or nil
            if behavior == "skip" then
                return original_key(t)
            end
            local rec = ensure_record(mods, key, group, desc)

            if behavior == "release" then
                -- Do not wrap on_press
                if type(t.on_release) == "function" then
                    t.on_release = wrap_fn(t.on_release, rec)
                else
                    -- Inject a release-only counter
                    t.on_release = function() update_stats_deferred(rec) end
                end
            else
                -- Default behavior: post-press (or post-release if only release)
                if type(t.on_press) == "function" then
                    t.on_press = wrap_fn(t.on_press, rec)
                elseif t.on_press == nil and type(t.on_release) == "function" then
                    t.on_release = wrap_fn(t.on_release, rec)
                end
            end
            return original_key(t)
        end

        -- Positional-form API: awful.key(mods, key, press, [release], [desc_tbl])
        local mods, key, press, release, desc_tbl = a, b, c, d, e
        -- If release is a table and desc_tbl missing, it's actually the description
        if type(release) == "table" and desc_tbl == nil then
            desc_tbl, release = release, nil
        end

        local group, desc
        if type(desc_tbl) == "table" then
            group = desc_tbl.group
            desc = desc_tbl.description
        end
        -- Determine behavior for this group
        local behavior = (group and (GROUP_BEHAVIOR[group] or (EXCLUDE_GROUPS[group] and "skip"))) or nil
        if behavior == "skip" then
            return original_key(mods, key, press, release, desc_tbl)
        end

        local rec = ensure_record(normalize_mods(mods), key, group, desc)

        if behavior == "release" then
            -- Do not wrap on_press
            if type(release) == "function" then
                release = wrap_fn(release, rec)
            else
                -- Inject a release-only counter
                release = function() update_stats_deferred(rec) end
            end
        else
            -- Default behavior: post-press (or post-release if only release)
            if type(press) == "function" then
                press = wrap_fn(press, rec)
            elseif press == nil and type(release) == "function" then
                release = wrap_fn(release, rec)
            end
        end

        return original_key(mods, key, press, release, desc_tbl)
    end
end

-- Flush on Awesome exit
awesome.connect_signal("exit", function() write_db() end)

-- Initialize immediately upon require
hook_awful_key()

-- Public API (optional)
M.db_path = DB_PATH
M.flush = write_db
M.snapshot = function()
    local out = {}
    for id, rec in pairs(stats) do
        out[id] = {
            count = rec.count or 0,
            key = rec.key,
            mods = rec.mods,
            desc = rec.desc,
            group = rec.group,
            first_seen = rec.first_seen or 0,
            last_seen = rec.last_seen or 0,
        }
    end
    return out
end
M.exclude_groups = EXCLUDE_GROUPS
M.group_behavior = GROUP_BEHAVIOR

-- Internal helpers for analysis
local function passes_filters_row(row, f)
    if not f then return true end
    if f.group and (row.group or "") ~= f.group then return false end
    if f.mods and (row.mods or "") ~= f.mods then return false end
    if f.key and (row.key or "") ~= f.key then return false end
    if f.min_count and (row.count or 0) < f.min_count then return false end
    if f.max_count and (row.count or 0) > f.max_count then return false end
    if f.since_days then
        local cutoff = now() - (f.since_days * 86400)
        if (row.last_seen or 0) < cutoff then return false end
    end
    return true
end

local function rows_array(f)
    local arr = {}
    for id, rec in pairs(stats) do
        local mods_str
        if type(rec.mods) == "table" then mods_str = mods_to_key(rec.mods) else mods_str = tostring(rec.mods or "") end
        local row = {
            id = id,
            mods = mods_str or "",
            key = rec.key or "",
            group = rec.group or "",
            desc = rec.desc or "",
            count = rec.count or 0,
            first_seen = tonumber(rec.first_seen or 0),
            last_seen = tonumber(rec.last_seen or 0),
        }
        if passes_filters_row(row, f) then arr[#arr+1] = row end
    end
    return arr
end

local function sort_desc(arr, field)
    table.sort(arr, function(a, b) return (a[field] or 0) > (b[field] or 0) end)
end
local function sort_asc(arr, field)
    table.sort(arr, function(a, b) return (a[field] or 0) < (b[field] or 0) end)
end
local function take(arr, n)
    if not n or n <= 0 or #arr <= n then return arr end
    local out = {}
    for i = 1, n do out[i] = arr[i] end
    return out
end

function M.rank_top(n, filters)
    local rows = rows_array(filters)
    sort_desc(rows, "count")
    return take(rows, n or 20)
end

function M.rank_underused(n, filters)
    local rows = rows_array(filters)
    sort_asc(rows, "count")
    return take(rows, n or 20)
end

function M.rank_recent(n, filters)
    local rows = rows_array(filters)
    sort_desc(rows, "last_seen")
    return take(rows, n or 20)
end

function M.rank_stale(n, filters)
    local rows = rows_array(filters)
    sort_asc(rows, "last_seen")
    return take(rows, n or 20)
end

function M.aggregate_by(field, filters)
    assert(field == "group" or field == "mods", "field must be 'group' or 'mods'")
    local rows = rows_array(filters)
    local map = {}
    for _, r in ipairs(rows) do
        local k = r[field] or ""
        local slot = map[k]
        if not slot then slot = { key = k, total = 0, items = 0 }; map[k] = slot end
        slot.total = slot.total + (r.count or 0)
        slot.items = slot.items + 1
    end
    local out = {}
    for k, v in pairs(map) do out[#out+1] = { key = k, total = v.total, items = v.items } end
    table.sort(out, function(a,b) return a.total > b.total end)
    return out
end

function M.concentration(k, filters)
    local rows = rows_array(filters)
    sort_desc(rows, "count")
    local total = 0
    for _, r in ipairs(rows) do total = total + (r.count or 0) end
    local topk = take(rows, k or 10)
    local top_sum = 0
    for _, r in ipairs(topk) do top_sum = top_sum + (r.count or 0) end
    local share = (total > 0) and (top_sum / total) or 0
    return { share = share, top = topk, total_count = total }
end

function M.notify_top(n, filters)
    local top = M.rank_top(n or 10, filters)
    if not naughty or type(naughty.notify) ~= "function" then return end
    local lines = {}
    for i, r in ipairs(top) do
        lines[#lines+1] = string.format("%2d) %-18s %-4s  %5d  %s", i, r.mods, r.key, r.count, r.desc or "")
    end
    naughty.notify({
        title = "Hotkeys: Top " .. tostring(#top),
        text = table.concat(lines, "\n"),
        timeout = 6,
    })
end

return M
