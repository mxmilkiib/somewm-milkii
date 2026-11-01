-- plugins/session.lua
--
-- Session management: preserve window manager state across restarts.
--
-- Saves and restores:
--   - selected tag per screen
--   - per-tag layout selection + tuning params (mwfact, master/column
--     count, gap) so tiled splits keep their proportions
--   - per-client tag+screen assignments
--   - per-client floating/maximized/fullscreen/minimized state and
--     floating geometry, so windows reappear where they were rather than
--     at layout defaults
--   - per-tag client order (tiling position), via global client list order
--
-- Multiple windows sharing a PID (multi-window apps like Firefox, GIMP) are
-- saved as separate entries and matched on restore by name, role, then
-- fallback order so they don't collapse onto a single tag.
--
-- On restart, Wayland clients keep running with their original PIDs, so
-- we can match them and restore their tag/screen placement after the
-- ruled.client rules have been applied. Late-arriving clients (slow app
-- startup, D-Bus activation) are caught via the "manage" signal for a
-- window after the initial batch restore.
--
-- Session state lives in XDG_STATE_HOME (defaults to ~/.local/state) so it
-- survives reboots; /tmp is tmpfs and would be lost on power cycle. Writes
-- are atomic (tmp file + rename) so a crash mid-write cannot corrupt the
-- previous good state.


local gears = require("gears")
local alayout = require("awful.layout")
local atag = require("awful.tag")
local aplacement = require("awful.placement")
local guarded = require("error_guard")

local M = {}


-- // MARK: -- init

function M.init()
    local session_dir = (os.getenv("XDG_STATE_HOME") or (os.getenv("HOME") .. "/.local/state")) .. "/somewm"
    gears.filesystem.make_directories(session_dir)
    local session_tags_file = session_dir .. "/selected-tags"
    local session_state_file = session_dir .. "/client-placements"
    local session_layouts_file = session_dir .. "/tag-layouts"

    -- // MARK -- save

    -- write current tag selections and client placements to disk.
    -- atomic (tmp + rename) so a crash mid-write cannot corrupt the
    -- previous good state. exposed as M.save_state for manual triggering.
    local function save_state()
        -- save selected tag per screen (atomic: tmp + rename)
        local tags_tmp = session_tags_file .. ".tmp"
        local file = io.open(tags_tmp, 'w+')
        if file then
            for s in screen do
                -- guard against a screen with no selected tag; default to 1
                file:write((s.selected_tag and s.selected_tag.index or 1), '\n')
            end
            file:close()
            os.rename(tags_tmp, session_tags_file)
        end

        -- save per-tag layout state so tiled windows regain their split
        -- proportions instead of rc.lua defaults.
        -- format (tab-separated):
        --   screen_index:tag_index \t layout_name \t mwfact \t mcount \t ncol \t gap
        local layouts_tmp = session_layouts_file .. ".tmp"
        local lf = io.open(layouts_tmp, 'w+')
        if lf then
            for s in screen do
                for _, t in ipairs(s.tags) do
                    if t and t.valid then
                        local l = t.layout
                        lf:write(s.index .. ":" .. t.index, '\t',
                                  l and alayout.getname(l) or "", '\t',
                                  tostring(t.master_width_factor or ""), '\t',
                                  tostring(t.master_count or ""), '\t',
                                  tostring(t.column_count or ""), '\t',
                                  tostring(t.gap or ""), '\n')
                    end
                end
            end
            lf:close()
            os.rename(layouts_tmp, session_layouts_file)
        end

        -- save per-client tag+screen assignments.
        -- one line per client so multiple windows sharing a PID are all
        -- preserved (previously keyed by PID alone, which collapsed them).
        -- format (tab-separated):
        --   pid \t screen \t tags \t class \t instance \t role \t name \t geometry \t flags
        -- tags is a comma-separated list of screen_index:tag_index:position
        -- (position is the client's index in the tag's client list, used to
        -- restore tiling order). geometry is "x,y,width,height". flags is a
        -- comma-separated list of client states (floating, maximized, ...).
        -- atomic: write to .tmp then rename so a crash mid-write leaves
        -- the previous good state intact.
        local state_tmp = session_state_file .. ".tmp"
        local sf = io.open(state_tmp, 'w+')
        if not sf then return end
        for _, c in ipairs(client.get()) do
            if c.valid and c.pid then
                local ctags = c:tags() or {}
                local tag_indices = {}
                for _, t in ipairs(ctags) do
                    if t and t.valid and t.screen and t.screen.valid then
                        -- encode as screen:tag:position so multi-screen
                        -- placement and tiling order are preserved
                        local pos = 0
                        for i, tc in ipairs(t:clients()) do
                            if tc == c then pos = i break end
                        end
                        table.insert(tag_indices, t.screen.index .. ":" .. t.index .. ":" .. pos)
                    end
                end
                if #tag_indices > 0 then
                    local sidx = c.screen and c.screen.valid and c.screen.index or 1
                    local class = c.class or ""
                    local instance = c.instance or ""
                    local role = c.role or ""
                    -- strip tabs/newlines from name so it stays on one line
                    local name = (c.name or ""):gsub("[\t\n]", " ")
                    local g = c:geometry()
                    local flags = {}
                    for _, f in ipairs({
                        "floating", "maximized", "maximized_horizontal",
                        "maximized_vertical", "fullscreen", "minimized",
                        "ontop", "sticky", "above", "below",
                    }) do
                        if c[f] then table.insert(flags, f) end
                    end
                    sf:write(c.pid, '\t', sidx, '\t', table.concat(tag_indices, ','),
                              '\t', class, '\t', instance, '\t', role, '\t', name,
                              '\t', g.x .. ',' .. g.y .. ',' .. g.width .. ',' .. g.height,
                              '\t', table.concat(flags, ','), '\n')
                end
            end
        end
        sf:close()
        os.rename(state_tmp, session_state_file)
    end

    M.save_state = save_state

    awesome.connect_signal('exit', guarded(function(reason_restart)
        if not reason_restart then return end
        save_state()
    end))

    -- // MARK -- restore

    awesome.connect_signal('startup', guarded(function()
        -- restore selected tags per screen
        local file = io.open(session_tags_file, 'r')
        if file then
            local selected_tags = {}
            for line in file:lines() do
                table.insert(selected_tags, tonumber(line))
            end
            for s in screen do
                local i = selected_tags[s.index]
                if i and s.tags[i] then
                    local t = s.tags[i]
                    t:view_only()
                end
            end
            file:close()
        end

        -- tab-split that preserves empty fields; a plain gmatch('[^\t]+')
        -- would collapse them and shift the remaining columns left.
        local function split_tabs(line)
            local parts = {}
            local pos = 1
            while true do
                local s, e = line:find('\t', pos, true)
                if not s then
                    table.insert(parts, line:sub(pos))
                    break
                end
                table.insert(parts, line:sub(pos, s - 1))
                pos = e + 1
            end
            return parts
        end

        -- restore per-tag layout selection and tuning params before clients
        -- are placed, so tiled windows get their saved split proportions.
        local lf = io.open(session_layouts_file, 'r')
        if lf then
            for line in lf:lines() do
                local parts = split_tabs(line)
                local si, ti = (parts[1] or ""):match('^(%d+):(%d+)$')
                local sc = si and screen[tonumber(si)]
                local t = sc and sc.valid and sc.tags[tonumber(ti)]
                if t and t.valid then
                    local lname = parts[2] or ""
                    -- find the saved layout in the tag's own list first,
                    -- falling back to the global list for layouts the tag
                    -- no longer cycles through.
                    local function find_layout(list)
                        for _, l in ipairs(list or {}) do
                            if alayout.getname(l) == lname then return l end
                        end
                    end
                    local saved_layout = find_layout(t.layouts) or find_layout(alayout.layouts)
                    if saved_layout and t.layout ~= saved_layout then
                        t.layout = saved_layout
                    end
                    local mw = tonumber(parts[3]); if mw then t.master_width_factor = mw end
                    local mc = tonumber(parts[4]); if mc then t.master_count = mc end
                    local nc = tonumber(parts[5]); if nc then t.column_count = nc end
                    local gp = tonumber(parts[6]); if gp then t.gap = gp end
                end
            end
            lf:close()
        end

        -- parse saved client placements into lists grouped by PID.
        -- each PID maps to a list of saved entries so multi-window apps
        -- don't collapse onto one tag.
        local saved_by_pid = {}
        local sf = io.open(session_state_file, 'r')
        if sf then
            for line in sf:lines() do
                local parts = split_tabs(line)
                if #parts >= 3 then
                    local pid = tonumber(parts[1])
                    local sidx = tonumber(parts[2])
                    local tag_specs = {}
                    for spec in (parts[3] or ""):gmatch('[^,]+') do
                        -- screen:tag or screen:tag:position (old files lack pos)
                        local si, ti, pos = spec:match('^(%d+):(%d+):?(%d*)$')
                        if si and ti then
                            -- pos 0/absent means "unknown": leave unordered
                            -- rather than letting it sort ahead of pos 1.
                            local pnum = tonumber(pos)
                            table.insert(tag_specs, {
                                screen = tonumber(si),
                                tag = tonumber(ti),
                                pos = (pnum and pnum > 0) and pnum or nil,
                            })
                        end
                    end
                    local gx, gy, gw, gh = (parts[8] or ""):match('^(%-?%d+),(%-?%d+),(%-?%d+),(%-?%d+)$')
                    -- nil (not empty) flags means an old-format line with no
                    -- saved state at all; restore then skips attributes.
                    local flags = nil
                    if parts[9] ~= nil then
                        flags = {}
                        for fl in parts[9]:gmatch('[^,]+') do
                            flags[fl] = true
                        end
                    end
                    saved_by_pid[pid] = saved_by_pid[pid] or {}
                    table.insert(saved_by_pid[pid], {
                        screen = sidx,
                        tags = tag_specs,
                        class = parts[4] or "",
                        instance = parts[5] or "",
                        role = parts[6] or "",
                        name = parts[7] or "",
                        geometry = gx and {
                            x = tonumber(gx), y = tonumber(gy),
                            width = tonumber(gw), height = tonumber(gh),
                        } or nil,
                        flags = flags,
                        used = false,
                    })
                end
            end
            sf:close()
        end

        if not next(saved_by_pid) then return end

        -- track clients we've already placed so re-runnable batch passes and
        -- the manage handler don't re-match them to a different saved entry.
        local placed = {}

        -- apply a saved entry's window-state attributes to a client.
        -- deferred callers run this after manage-time placement rules so
        -- e.g. awful.placement.centered can't overwrite restored geometry.
        local function apply_attrs(c, entry)
            if not c or not c.valid or not entry.flags then return end
            local f = entry.flags
            -- restore floating first so the layout lets the geometry stick
            c.floating = f.floating == true
            if entry.geometry then
                -- only floating clients (or clients on a floating-layout
                -- tag) own their geometry; tiling layouts recompute it on
                -- the next arrange, so don't bother setting it there.
                local owns_geom = c.floating
                if not owns_geom then
                    for _, t in ipairs(c:tags()) do
                        if t.valid and atag.object.get_layout(t) == alayout.suit.floating then
                            owns_geom = true
                            break
                        end
                    end
                end
                if owns_geom then
                    c:geometry(entry.geometry)
                    -- pull the window back into view if its saved position
                    -- is now fully offscreen (e.g. an output disappeared)
                    local g = c:geometry()
                    local visible = false
                    for s in screen do
                        local sg = s.geometry
                        if g.x < sg.x + sg.width and g.x + g.width > sg.x
                           and g.y < sg.y + sg.height and g.y + g.height > sg.y then
                            visible = true
                            break
                        end
                    end
                    if not visible then
                        aplacement.no_offscreen(c)
                    end
                end
            end
            c.maximized = f.maximized == true
            c.maximized_horizontal = f.maximized_horizontal == true
            c.maximized_vertical = f.maximized_vertical == true
            c.fullscreen = f.fullscreen == true
            c.ontop = f.ontop == true
            c.sticky = f.sticky == true
            c.above = f.above == true
            c.below = f.below == true
            c.minimized = f.minimized == true
        end

        -- reorder the global client list so each tag's tiled windows land
        -- in their saved positions. tiling order follows globalconf order,
        -- and client:swap() is the only primitive that mutates it, so this
        -- is a selection pass of swaps over client.get().
        local function restore_order()
            -- desired order: tags by index per screen, clients by saved
            -- position within each tag; anything unmatched keeps its
            -- current relative order at the end.
            local desired = {}
            local seen = {}
            for s in screen do
                for _, t in ipairs(s.tags) do
                    if t and t.valid then
                        local saved = {}
                        for _, entries in pairs(saved_by_pid) do
                            for _, e in ipairs(entries) do
                                if e.client then
                                    for _, spec in ipairs(e.tags) do
                                        if spec.pos and spec.screen == s.index
                                           and spec.tag == t.index then
                                            table.insert(saved, { pos = spec.pos, c = e.client })
                                        end
                                    end
                                end
                            end
                        end
                        table.sort(saved, function(a, b) return a.pos < b.pos end)
                        for _, it in ipairs(saved) do
                            if it.c.valid and not seen[it.c] then
                                seen[it.c] = true
                                table.insert(desired, it.c)
                            end
                        end
                    end
                end
            end
            for _, c in ipairs(client.get()) do
                if c.valid and not seen[c] then
                    seen[c] = true
                    table.insert(desired, c)
                end
            end
            if #desired == 0 then return end
            for i = 1, #desired do
                local cur = client.get()
                if cur[i] and cur[i] ~= desired[i] and cur[i].valid and desired[i].valid then
                    cur[i]:swap(desired[i])
                end
            end
        end

        -- apply a saved entry's screen+tags to a client and mark both consumed.
        local function apply_entry(c, entry)
            if not c or not c.valid or placed[c] then return end
            -- restore screen
            local target_screen = screen[entry.screen]
            if target_screen and target_screen.valid and c.screen ~= target_screen then
                c:move_to_screen(target_screen)
            end
            -- restore tags
            local target_tags = {}
            for _, spec in ipairs(entry.tags) do
                local sc = screen[spec.screen]
                if sc and sc.valid and sc.tags[spec.tag] then
                    table.insert(target_tags, sc.tags[spec.tag])
                end
            end
            if #target_tags > 0 then
                c:tags(target_tags)
            end
            entry.client = c
            -- apply geometry/state on the next tick so it lands after
            -- manage-time placement rules and layout arranges.
            gears.timer.start_new(0, guarded(function()
                apply_attrs(c, entry)
                return false
            end))
            placed[c] = true
            entry.used = true
        end

        -- batch restore: match unused saved entries to unplaced current
        -- clients sharing the same PID. re-runnable so it can be called
        -- immediately and again shortly after for stragglers.
        local function run_batch()
            -- group unplaced current clients by PID, filtering out any
            -- whose class doesn't match any saved entry for that PID
            -- (guards against PID reuse by a different application).
            local current_by_pid = {}
            for _, c in ipairs(client.get()) do
                if c.valid and c.pid and not placed[c] and saved_by_pid[c.pid] then
                    local entries = saved_by_pid[c.pid]
                    local class_ok = false
                    local cclass = c.class or ""
                    for _, e in ipairs(entries) do
                        if not e.used and (e.class == "" or e.class == cclass) then
                            class_ok = true
                            break
                        end
                    end
                    if class_ok then
                        current_by_pid[c.pid] = current_by_pid[c.pid] or {}
                        table.insert(current_by_pid[c.pid], c)
                    end
                end
            end

            for pid, saved_entries in pairs(saved_by_pid) do
                local current = current_by_pid[pid]
                if current then
                    -- match saved entries to current clients.
                    -- pass 1: exact name match.
                    -- pass 2: unique role match.
                    -- pass 3: assign remaining in order.
                    local used_saved = {}
                    local used_current = {}

                    -- pass 1: exact name match
                    for si, entry in ipairs(saved_entries) do
                        if not entry.used and entry.name ~= "" then
                            for ci, c in ipairs(current) do
                                if not used_current[ci] and (c.name or "") == entry.name then
                                    used_saved[si] = ci
                                    used_current[ci] = si
                                    break
                                end
                            end
                        end
                    end

                    -- pass 2: unique role match
                    for si, entry in ipairs(saved_entries) do
                        if not used_saved[si] and not entry.used and entry.role ~= "" then
                            local match_ci = nil
                            local count = 0
                            for ci, c in ipairs(current) do
                                if not used_current[ci] and (c.role or "") == entry.role then
                                    count = count + 1
                                    match_ci = ci
                                end
                            end
                            if count == 1 then
                                used_saved[si] = match_ci
                                used_current[match_ci] = si
                            end
                        end
                    end

                    -- pass 3: assign remaining in order
                    local remaining_saved = {}
                    for si = 1, #saved_entries do
                        if not used_saved[si] and not saved_entries[si].used then
                            table.insert(remaining_saved, si)
                        end
                    end
                    local remaining_current = {}
                    for ci = 1, #current do
                        if not used_current[ci] then
                            table.insert(remaining_current, ci)
                        end
                    end
                    for i = 1, math.min(#remaining_saved, #remaining_current) do
                        used_saved[remaining_saved[i]] = remaining_current[i]
                    end

                    -- apply placements
                    for si, ci in pairs(used_saved) do
                        apply_entry(current[ci], saved_entries[si])
                    end
                end
            end

            restore_order()
        end

        -- synchronous first pass: pre-existing Wayland clients are already
        -- managed by the time "startup" fires, so their ruled.client rules
        -- have applied and their class/name/role are populated. placing
        -- them here avoids the 1-2 frame flash of empty tags before a timer
        -- would fire. the timer passes below catch anything not ready yet;
        -- the placed/used tracking makes this safe to call early.
        run_batch()

        -- second pass on the next tick catches clients still being managed
        -- when the synchronous pass ran. a third pass shortly after picks up
        -- any further stragglers.
        gears.timer.start_new(0, guarded(function() run_batch() return false end))
        gears.timer.start_new(0.15, guarded(function() run_batch() return false end))

        -- late arrivals: clients that appear after the batch window (slow
        -- app startup, D-Bus activation). listen on "request::manage"
        -- (somewm 2.0 removed the plain "manage" signal) and restore
        -- any matching unused saved entry. the apply is deferred to the
        -- next tick so ruled.client rules apply first.
        local function on_manage(c)
            if not c.valid or not c.pid then return end
            local saved_entries = saved_by_pid[c.pid]
            if not saved_entries then return end

            -- class check guards against PID reuse by a different app
            local cclass = c.class or ""
            local class_ok = false
            for _, e in ipairs(saved_entries) do
                if not e.used and (e.class == "" or e.class == cclass) then
                    class_ok = true
                    break
                end
            end
            if not class_ok then return end

            gears.timer.start_new(0, guarded(function()
                if not c.valid then return false end
                -- find best unused entry: name match, then role match,
                -- then first unused.
                local best_si = nil
                local cname = c.name or ""
                if cname ~= "" then
                    for si, e in ipairs(saved_entries) do
                        if not e.used and e.name == cname then
                            best_si = si
                            break
                        end
                    end
                end
                if not best_si then
                    local crole = c.role or ""
                    if crole ~= "" then
                        for si, e in ipairs(saved_entries) do
                            if not e.used and e.role == crole then
                                best_si = si
                                break
                            end
                        end
                    end
                end
                if not best_si then
                    for si, e in ipairs(saved_entries) do
                        if not e.used and (e.class == "" or e.class == cclass) then
                            best_si = si
                            break
                        end
                    end
                end
                if best_si then
                    apply_entry(c, saved_entries[best_si])
                    restore_order()
                end
                return false  -- one-shot
            end))
        end

        client.connect_signal('request::manage', on_manage)

        -- stop listening after 30s; any later client is treated as new
        -- rather than a session restore.
        gears.timer.start_new(30, guarded(function()
            client.disconnect_signal('request::manage', on_manage)
            saved_by_pid = nil
            return false
        end))
    end))
end


return M
