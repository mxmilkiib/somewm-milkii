# Somewm Codebase Audit

Generated 2026-09-14. Scope: own code only (~23k LOC across rc.lua, rc/, plugins/, plugins/shimmer/, milktheme/, vstack/). Vendored modules (bling, lain, awesome-wm-widgets, etc.) excluded.

## Summary

| Category    | HIGH | MEDIUM | LOW | Total |
|-------------|-----:|-------:|----:|------:|
| BUG         |    9 |     11 |   0 |    20 |
| PROBLEM     |    2 |      8 |   2 |    12 |
| CODE-SMELL  |    0 |      5 |   4 |     9 |
| IMPROVEMENT |    0 |      5 |   4 |     9 |
| DEAD-CODE   |    0 |     14 |   8 |    22 |
| DUPLICATION |    0 |      8 |   2 |    10 |
| STYLE       |    0 |      0 |   1 |     1 |
| **Total**   |   11 |     51 |  21 |    83 |

Cross-cutting themes: (1) signal handlers and timers connected inside per-screen setup or module body never disconnected on hot-reload, causing accumulation; (2) the popup family (volume/brightness/resource/media/notification_center) duplicates ~50% of its scaffolding that belongs in popup_common; (3) large commented-out blocks preserved "for reference" across rc.lua, notification_center, shimmer, theme; (4) hardcoded `/home/milkii` paths and `"Hack Nerd Font"` strings (50+ occurrences) instead of theme/env-derived values.

---

# BUG

## HIGH

### B1. Shimmer stubbed to no-op in rc.lua but real module used in keybindings
`rc.lua:662-664` vs `keybindings.lua:62`
rc.lua replaces `shimmer` with a no-op stub (`setmetatable({}, { __index = function() return noop end })`), so all shimmer calls in rc.lua (`configure`, `post_startup_init`, `register_tasklist`, `apply_tasklist_safety`, `refresh_all_tasklists`, `register_taglist`, `attach_tag_hover`, `tasklist_update_callback`) do nothing. But keybindings.lua requires the real `plugins/shimmer` and its bindings call real shimmer functions expecting configuration rc.lua never applied. Shimmer keybindings operate on an unconfigured module; all rc.lua-side shimmer integration (tasklist registration, hover, safety colorization) is silently disabled.

### B2. `set_speed_multiplier` ignores its argument, hardcodes 0.5
`plugins/shimmer/animation.lua:488-493`
`M.set_speed_multiplier(multiplier)` ignores `multiplier` and hardcodes `global_speed_multiplier = 0.5`. Comment says "lock at 1.0" but sets 0.5. Called from `init.lua:516-518` and `init.lua:524-526` with calculated values that are silently discarded, so the speed adjust hotkeys do nothing.

### B3. `mode_name` undefined global in shimmer color calc
`plugins/shimmer/animation.lua:2209, 2294, 2300`
`mode_name` is referenced in `generate_letter_markup_internal` and `generate_differential_markup` but never declared as a local, parameter, or module variable. It is an undefined global access returning nil, which happens to work because `M.get_color(nil, ...)` falls back to `shimmer_mode`. If any global `mode_name` were ever defined, all shimmer color calculations would break.

### B4. Clipboard history rofi menu never appears (FIXED)
`plugins/sys_tray.lua:139`
`show_clipboard_history` ran `wl-paste --watch cliphist store` which blocks forever, so the `;` after it meant `cliphist list | rofi` never executed. Fixed by replacing the blocking `--watch` daemon with a one-shot `wl-paste | cliphist store` so the rofi menu actually runs. `wl-paste --watch` belongs in autostart, not in a click handler.

### B5. `solo_super.lua` leaks `button::press` handler and timer on every `M.keys()` call (FIXED)
`plugins/solo_super.lua:141`
`client.connect_signal("button::press", guarded(disarm))` was inside `M.keys()` and never disconnected. Fixed by connecting once at module level with a `button_press_connected` guard, and reusing a module-level `hold_timer` (callback refreshed per call) instead of allocating a new one each call.

### B6. `tag::property::layout` and per-screen signals connected in loop, never disconnected (FIXED)
`rc.lua:2866`, `rc.lua:3239`, `rc.lua:3362`
`tag.connect_signal("property::layout", ...)`, `awesome.connect_signal("brightness::updated", ...)`, and `awesome.connect_signal("media::players_active", ...)` were connected inside `connect_for_each_screen` every time it fired. Fixed by routing each connection through a `track_signal(source, name, handler)` helper that records it on `s._somewm_cleanup.signals`, with a matching `screen.connect_signal("removed", ...)` handler that disconnects them. The per-screen callback also tears down any prior registry first, so hot-reload no longer accumulates handlers.

### B7. Per-screen timers never cleaned up (FIXED)
`rc.lua:3247-3250, 3326-3329, 3397-3400, 2810-2812`
Four repeating timers (brightness poll, battery poll, media tooltip poll, layout hide timer) were created inside `connect_for_each_screen` and never stopped. Fixed by routing each through a `track_timer(t)` helper that records it on `s._somewm_cleanup.timers`; the `screen::removed` handler (and the top of the per-screen callback on re-entry) stops them all.

### B8. `hotkeys_popup.show_help` override leaks keygrabber on re-invocation (FIXED)
`rc.lua:591-614`
`current_obj` and `my_grabber` were per-call locals inside `show_help`. If `show_help` was called while a previous invocation was still active, the old `my_grabber` was overwritten without being stopped, leaving a dangling keygrabber that swallowed all key events. Fixed by hoisting the grabber handle to the `do`-block scope as `active_grabber` and stopping any prior grabber before starting a new one.

### B9. Xephyr wrapper has wrong paths
`rc/rc_xephyr.lua:2,4,10`
Line 2: fallback home is `/home/milk` instead of `/home/milkii`. Line 4: loads `~/.config/awesome/rc.lua` instead of `~/.config/somewm/rc.lua`. Line 10: references `~/.config/awesome/milktheme/` instead of `~/.config/somewm/milktheme/`. The Xephyr wrapper would load the wrong config or fail entirely.

## MEDIUM

### B10. `resize_no_warp.lua` center update runs before async resize completes
`rc/resize_no_warp.lua:190-196`
`mousegrabber.run` is asynchronous — it starts the grab and returns immediately. The `window_centers[c]` update at lines 190-196 executes synchronously right after, reading the pre-resize geometry. The center is never updated with the post-resize position. The update should happen inside the grabber callback when it returns `false`.

### B11. `resize_no_warp.lua` nil access on `layout`
`rc/resize_no_warp.lua:37`
`awful.layout.get(c.screen)` can return nil if no layout is set. Line 37 does `layout.mouse_resize_handler` without a nil check on `layout` itself. Should be `if not c.floating and layout and layout.mouse_resize_handler then`.

### B12. `M.history` export becomes stale after `clear_history`
`plugins/notification_center.lua:1321`, `plugins/notification_center.lua:1447`
`M.clear_history()` reassigns the `history` upvalue to a new table, but `M.history` (set at line 1447) still points to the old table. After clearing, external consumers of `M.history` see stale entries while the module's internal upvalue is a fresh empty table. The export should be a function or `clear_history` should reassign `M.history = history`.

### B13. Dead ternary in tag pager color
`plugins/tag_pager.lua:329`
`local fg = is_selected and COLOR_GOLD or (has_clients and COLOR_FG or COLOR_FG)` — the sub-expression `has_clients and COLOR_FG or COLOR_FG` always evaluates to `COLOR_FG` regardless of `has_clients`. The `has_clients` variable (computed at line 315) is dead logic here. Intent was likely a different color for empty vs occupied tags.

### B14. Tag pager detail popup doesn't emit `popup::opening`
`plugins/tag_pager.lua:860-904`
`M.show` for the detail popup never calls `awesome.emit_signal("popup::opening")`, unlike every other popup (media_popup:356, volume_popup:410, brightness_popup:535, resource_popup:758, notification_center:1220). Other popups won't auto-close when the tag pager detail popup opens, leaving two popups on screen simultaneously.

### B15. `ignore_next_wibar_click` is never set to true
`plugins/tag_pager.lua:757`, `plugins/tag_pager.lua:885-888`
The module-level `ignore_next_wibar_click` variable is declared `false` and only ever read (line 885) and reset to `false` (line 886). It is never set to `true` anywhere. The wibar outside-click handler for the detail popup can never skip a click, making the ignore-check dead code.

### B16. `naughty.destroy_all_notifications` called with suspicious nil first argument
`plugins/notification_center.lua:1264-1265`
`pcall(naughty.destroy_all_notifications, nil, naughty.notification_closed_reason.dismissed_by_user)` passes `nil` as the first argument. Depending on AwesomeWM version the `nil` may cause the call to silently no-op (pcall swallows the error), leaving live notification popups on screen after the notification center opens.

### B17. `power.lua` priming callback doesn't nil-check `out`
`plugins/power.lua:296-301`
The priming callback does `out:match(...)` without checking if `out` is nil. If `upower -i` fails (no battery, command error), `out` is nil and `out:match` throws. The `guarded` wrapper catches the error, but the priming state is silently lost, so the first AC/battery transition is treated as a change rather than a steady state.

### B18. `floating_rules.lua` non-atomic write
`plugins/floating_rules.lua:92-116`
`save_data` writes directly to `DATA_FILE` without atomic write (tmp + rename). If the WM crashes mid-write, the rules file is truncated/corrupted. Compare to `session.lua:44-92` which correctly uses tmp+rename.

### B19. `brightness.lua` synchronous `io.popen` blocks compositor
`plugins/brightness.lua:26-30, 55-63`
`get_brightnessd_sock` and `get_percent` use `io.popen` synchronously, blocking the compositor main thread on every brightness key press. These should use `awful.spawn.easy_async` like the rest of the file.

### B20. `power.lua` leaks three long-running resources on hot-reload
`plugins/power.lua:282, 279-281, 285-292`
A 30s repeating `gears.timer`, a `udevadm monitor` process, and an `upower --monitor-detail` process are spawned but never cleaned up on hot-reload. Each reload leaks one of each.

### B21. `integrations.lua` dangling `return false` from removed timer wrapper
`plugins/shimmer/integrations.lua:675-688`
In `initialize_focused_client`, the fallback block has a dangling `return false` (line 687) left over from a commented-out `gears.timer.start_new` wrapper (lines 675, 688). The `return false` now prematurely exits the function, skipping any code after the else block.

### B22. `integrations.lua` `register_tasklist` timer wrapper removed, now runs synchronously
`plugins/shimmer/integrations.lua:206-218`
Code that was clearly inside a deferred timer callback (indentation at line 206, `return false` at line 217) had its timer wrapper removed. The shimmer application now runs synchronously during tasklist registration, which can cause startup ordering issues if the tasklist widget isn't fully initialized.

### B23. `toggle_keepassxc` and `toggle_pavucontrol` both target tag 8
`rc.lua:1273-1278, 1263-1268`
Both toggle functions target tag 8. `toggle_app_tag` calls `awful.tag.viewtoggle(app_tag)` which toggles the tag's visibility. Toggling keepassxc shows/hides tag 8, which also shows/hides pavucontrol (and vice versa). Toggling one app unexpectedly affects the other.

### B24. `tag_navigation.lua` nil `selected_tag` crashes modulo
`rc/tag_navigation.lua:70-73`
If `current_screen.selected_tag` is nil, `gears.table.hasitem(all_tags, nil)` is called. The return value `current_index` would be nil, and the modulo operations at lines 80-83 would crash with "attempt to perform arithmetic on a nil value".

### B25. `property::struts` handler makes ALL strutted windows sticky
`rc.lua:3795-3802`
Any window with any non-zero strut value is unconditionally set to `sticky = true`. This is overly broad — legitimate panels and docks that shouldn't be sticky would be affected. There's no way to un-stick them since the handler only sets `true`, never `false`.

### B26. `screen_rotation.lua` loop variable shadows `client` capi module
`plugins/screen_rotation.lua:86`
The loop variable `client` shadows the `client` capi module. Inside the loop body `client.valid` and `client:move_to_tag(tag)` operate on the loop variable (correct), but any future code added inside the loop that calls `client.get()` or `client.focus` would silently fail.

### B27. Slider debounce timers not cleaned up on popup hide / row rebuild
`plugins/volume_popup.lua:226-243`, `plugins/brightness_popup.lua:356-363`
Each `make_slider_row` creates a `send_timer` that is never stopped when `refresh_popup` calls `rows_container_ref:reset()`. A pending debounce timer fires after the row widget is gone, spawning a `wpctl` command on a stale `device.id`. Resource leak and potential spurious hardware write after the popup closes.

---

# PROBLEM

## HIGH

### P1. Shell injection risk in `sys_tray.lua` battery path interpolation
`plugins/sys_tray.lua:177, 183`
`update_battery` and `show_battery_info` interpolate `bat_path` (from `upower -e` output) directly into shell command strings (`"upower -i " .. bat_path`) without sanitization. A malicious or malformed upower output could inject shell commands.

### P2. `sys_tray.lua` `easy_async` callbacks not guarded
`plugins/sys_tray.lua:106, 117, 139, 149, 159, 177, 205, 230`
Multiple `easy_async` callbacks are plain functions, not wrapped in `guarded()`. If any callback errors (e.g. nil stdout from a failed command), the error propagates uncaught. Compare to other files in the config that consistently use `guarded()`.

## MEDIUM

### P3. Hardcoded absolute paths
`rc/keybindings.lua:253,284,533`, `rc.lua:1911,2369-2370`
`/home/milkii/bin/rofi_power`, `/home/milkii/bin/rofi_nice`, `/home/milkii/bin/rofi_nice_run`, `/home/milkii/.config/somewm/milktheme/icons/somewm-logo.svg`. Should use `os.getenv("HOME")` or `gears.filesystem.get_configuration_dir()` for portability.

### P4. Hardcoded IP for Denon amplifier
`rc/keybindings.lua:496-498`
`192.168.1.24` is hardcoded in four keybindings. Should be a config variable.

### P5. Hardcoded battery sysfs path
`rc.lua:3289-3290`
`/sys/class/power_supply/BAT0/` is hardcoded. On systems with BAT1 or BATT, the battery widget silently fails (returns early at lines 3291-3294).

### P6. Hardcoded sysfs ranges in `resource_popup`
`plugins/resource_popup.lua:126-130, 154-160, 178-234`
`read_gpu()` loops `card0`-`card7`, `acpi_zones` loops `thermal_zone0`-`thermal_zone15`, `probe_hwmon()` loops `hwmon0`-`hwmon15`. Systems with more devices will have sensors silently missed. Should iterate until `read_file` returns nil.

### P7. `wpctl status` parsing depends on specific Unicode box-drawing format
`plugins/volume_popup.lua:96`
The regex depends on the `│` (U+2502) character and exact spacing. Any `wpctl` version change that alters the tree-drawing format will silently break device parsing, yielding an empty device list with no error.

### P8. `power.lua` undeclared jq dependency for lid-open
`plugins/power.lua:209`
`on_lid_open` uses `jq` to parse `wlopm -j` output, but the module header (line 29) explicitly states it avoids jq. `has_external_display` (line 183) correctly parses in Lua. The inconsistency means the module has an undeclared jq dependency for lid-open only.

### P9. `dnd_to_tag.lua` references undefined global `border_animation_timer`
`plugins/dnd_to_tag.lua:171-174, 271-273`
References `border_animation_timer` — a global variable that is never defined, required, or passed in. The `and` guards prevent nil errors, so these branches are dead code. Comment says "Fallback: stop inline timer if present" but the inline timer was removed.

### P10. `smart_borders.lua` no double-init guard
`plugins/smart_borders.lua:52`
`M.init()` has no guard against double-initialization. If called twice (e.g. on reload), all signal connections (lines 53-74) are duplicated, causing double border updates.

### P11. Module-body signal connections accumulate on hot-reload
`plugins/shimmer/border.lua:267-280`, `plugins/window_fx.lua:55-128`, `plugins/system_widgets.lua:51`
Signal connections at module level (not inside init functions) accumulate on hot-reload since `require` re-executes the module body. Each reload adds duplicate focus/unfocus/manage handlers.

### P12. `awful._keystats_hooked` pollutes `awful` module namespace
`plugins/keystats.lua:82`
`awful._keystats_hooked = true` sets a private flag on the global `awful` module table. Could conflict with other plugins or future awful versions. A module-level local flag would suffice since `require` caches modules.

### P13. Unguarded signal handlers across multiple popup files
`plugins/brightness_popup.lua:96-97,364,453`, `plugins/volume_popup.lua:151-152,221,128,143,180`, `plugins/tag_pager.lua:650,794-805,883`, `plugins/notification_center.lua:667-671,1152-1156,1383-1395`, `plugins/brightness_popup.lua:98`
`mouse::enter`/`mouse::leave`, `property::value`, and `button::press` handlers not wrapped in `guarded()`, inconsistent with the established pattern in the same files. An unhandled error in a `property::value` or `button::press` handler can break the widget permanently.

### P14. Unguarded `gears.timer.delayed_call` callbacks
`plugins/popup_common.lua:92,133`, `plugins/notification_center.lua:1093`
If the popup object is destroyed or nil by the time the callback fires, these will error unhandled. Other `delayed_call` callbacks in the codebase are wrapped in `guarded()`.

## LOW

### P15. `keystats_cli.lua` help text has wrong default DB path
`plugins/keystats_cli.lua:43`
Help text says default DB path is `~/.config/awesome/keystats_db.lua` but `get_config_dir()` returns `~/.config/somewm/`, so the actual default is `~/.config/somewm/keystats_db.lua`.

### P16. Unguarded `destroyed` signal callbacks on notifications
`plugins/brightness.lua:105-108`, `plugins/volume_osd.lua:35-37`
The `destroyed` signal callbacks on notifications are not `guarded()`. If the callback errors, it propagates uncaught.

### P17. `rc.lua:1717` shell injection risk in `copy_last_notification`
`awful.spawn.with_shell("echo '" .. last_notification_text:gsub("'", "'\"'\"'") .. "' | wl-copy")` constructs a shell command from notification text. While single quotes are escaped, this is fragile — other shell metacharacters in notification text could cause unexpected behavior.

### P18. `rc.lua:1665` stale/incorrect comment
`naughty.config.defaults.position = 'bottom_middle'  -- changed from bottom_middle for testing` — the comment says "changed from bottom_middle" but the value IS `bottom_middle`. Contradictory and confusing.

### P19. `rc.lua:1972` `set_wallpaper` doesn't handle `gears.surface.load` failure
`gears.surface.load(wallpaper)` is not wrapped in pcall. If the wallpaper file is missing or invalid, it would error and crash the `request::wallpaper` signal handler.

### P20. `rc.lua:3380` `update_media_tooltip` async callback not guarded
The `easy_async` callback is not wrapped in `guarded()`. If the callback errors (e.g. `media_tooltip` is invalid after screen removal), it crashes the async handler. Compare with `update_brightness_widget` at line 3242 which is properly guarded.

### P21. Extensive global variable pollution in rc.lua
`rc.lua:838, 846-852, 891, 897, 1870-1872, 2285, 2294, 2330, 2378, 4498, 4568`
Many variables assigned without `local`: `confirmQuitmenu`, `modkey`, `altkey`, `ctrlkey`, `shiftkey`, `terminal`, `editor`, `editor_cmd`, `tag_nav_mod_keys`, `milkdefault`, `globalkeys`, `clientkeys`, `clientbuttons`, `awesomesubmenu`, `powersubmenu`, `mymainmenu`, `mylauncher`. `arandr_tag_visible` and `pavucontrol_tag_visible` are set but never declared or read — silent globals.

---

# CODE-SMELL

## MEDIUM

### C1. `connect_for_each_screen` callback is ~844 lines long
`rc.lua:2685-3529`
Creates all per-screen widgets, timers, signal handlers, and wibox setup in one function. Extremely difficult to maintain. Should be broken into smaller functions (widget creation, timer setup, wibox assembly).

### C2. `shimmer/animation.lua` is 3279 lines with deeply nested if-elseif chains
`plugins/shimmer/animation.lua:1913-2001` (25 branches), `plugins/shimmer/animation.lua:2010-2155` (30+ branches)
`get_color_progression_offset` and `calculate_shine_modifier_internal` should be table-driven lookups. The strategy registry in `strategies.lua` was created for exactly this but is only partially used.

### C3. `shimmer/integrations.lua` `handle_tag_hover` "leave" mode is 110+ lines, 4 levels deep
`plugins/shimmer/integrations.lua:398-509`
Includes a nested `lerp_color` with a nested `hex_to_rgb`, inside a timer callback, inside an if-else chain. Too complex; should be decomposed.

### C4. `protect_widget_from_interference` monkey-patches widget instances
`plugins/shimmer/integrations.lua:264-296`
Stores original methods as `__original_set_text`/`__original_set_markup`. Fragile — if the widget is GC'd and re-created the protection is lost, and monkey-patching makes debugging difficult.

### C5. `notifications.lua` `build_widget` is ~200 lines
`plugins/notifications.lua:203-408`
Builds icon, countdown arc, title, app name, title bar, message, actions, body, and outer widget all inline. Extracting sub-builders would improve readability.

### C6. `notification_center.lua` `create_history_row` is ~150 lines with inline commented alternatives
`plugins/notification_center.lua:793-943`
Contains three separate commented-out layout attempts (lines 872-916) interleaved with the active code, making it hard to follow the actual structure.

### C7. `brightness_popup.lua` `refresh_popup` is ~220 lines
`plugins/brightness_popup.lua:273-496`
Builds all individual display rows, the "All Displays" combined slider, and assembles them, all inline. The individual-row builder and the all-displays builder should be separate functions.

### C8. `keystats.lua` `hook_awful_key` is 74 lines with duplicated logic between two API forms
`plugins/keystats.lua:268-342`
Behavior determination, `skip` early return, `ensure_record`, and `release`/`post` wrapping are repeated nearly verbatim for table-form and positional-form APIs. A shared normalizer would halve the function.

### C9. `notifications.lua` `reflow` calls `entry.popup:geometry()` twice per iteration
`plugins/notifications.lua:144-148`
Line 144 (inside the non-animating branch) and again at line 147 (unconditionally). The second call is redundant for non-animating entries. For animating entries, the geometry read at line 147 may reflect a mid-animation position, making the `y` accumulation inaccurate for entries below.

## LOW

### C10. `shimmer/animation.lua` magic number `effective_speed = 0.5`
`plugins/shimmer/animation.lua:2498`
Comment explains it replaced a double-counting bug, but the value 0.5 is unexplained and hardcoded in the color calculation hot path.

### C11. Non-deterministic cache eviction (clear 25%/keep 75% by iterating `pairs`)
`plugins/shimmer/animation.lua:140-142, 147-149`
The cleanup logic iterates `pairs` whose order is unspecified — the "kept" entries are arbitrary, not LRU.

### C12. `hotkey_dupe_detector.lua` checks `type(key_obj.description) == "table"`
`plugins/hotkey_dupe_detector.lua:39-46`
In AwesomeWM, `awful.key.description` is always a string. The table branch is likely dead code.

### C13. `hotkey_dupe_detector.lua` relies on internal `awful.key` array structure
`plugins/hotkey_dupe_detector.lua:34`
`key_obj.key or key_obj[2]` relies on the internal array structure of `awful.key` objects. Fragile; will break if AwesomeWM changes its internal representation.

### C14. `keybindings.lua` uses value type as function dispatch
`rc/keybindings.lua:225-229`
`type(func_or_string) == "number"` triggers `rotate_screens(func_or_string)`. Any number in a keybinding silently calls `rotate_screens`. Fragile and undocumented in the keybinding table format.

---

# IMPROVEMENT

## MEDIUM

### I1. Shimmer if-elseif chains could be table-driven
`plugins/shimmer/animation.lua:1913-2001, 2010-2155`
The 25-branch and 30+ branch chains could be replaced with a table mapping mode names to handler functions, similar to how `progression_strategies` is used for the first branch. Several modes already use LUT lookups (`color_progression_lut`) but the dispatch is still if-elseif.

### I2. OSD notification pattern duplicated
`plugins/brightness.lua:67-114`, `plugins/volume_osd.lua:16-39`
Text progress bar, replaceable notification, timer-based expiry duplicated. A shared `osd_bar(pct, opts)` helper would eliminate the duplication.

### I3. `tag_pager.lua` `hit_test_client` and `render_cell_surface` duplicate coordinate math
`plugins/tag_pager.lua:299-412` (render), `plugins/tag_pager.lua:419-440` (hit-test)
Both compute `landscape_geom`, `scale`, and `unrotate_client` with identical math. A shared `cell_to_client_rect(c, sg, lg, scale, cell_w, cell_h)` helper returning `{rx, ry, rw, rh}` would eliminate the duplication and ensure the renderer and hit-test never diverge.

### I4. Tag pager detail popup could use `popup_common` for outside-click
`plugins/tag_pager.lua:875-894`
Replacing the inline handler setup with `popup_common.outside_click_setup(popup, M.hide)` would eliminate ~20 lines of duplication and gain the `also_release` focus-transfer handling for free.

### I5. `notifications.lua` and `notification_center.lua` duplicate icon resolution
`plugins/notifications.lua:204-212`, `plugins/notification_center.lua:266-337`
Both handle the same `n.icon` / `n.app_icon` / `n.icon_image` / `n.icon_surface` fallback chain. A shared `icon_utils` module would eliminate this.

## LOW

### I6. `rc.lua` `on_selected` check duplicated 3+ times
`rc.lua:3106-3116, 3147-3157, 2561-2568`
Same nested loop checking if a client is on any selected tag is duplicated in tasklist `create_callback`, `update_callback`, and the tasklist button 1 handler. Should be extracted into a helper.

### I7. `rc.lua` `always_floating_classes` list duplicates `floating_rules` data
`rc.lua:3955-3963`
Hardcoded list of always-floating classes in the `property::floating` handler duplicates part of the floating rules already managed by `plugins/floating_rules`. Could be sourced from the same data.

### I8. `rc.lua` `cycle_clients_on_tag` and `cycle_clients_exclusive` share ~80% identical code
`rc.lua:2464-2501, 2504-2555`
Same structure: get current tag, get clients, find current index, calculate next index. Only difference is `cycle_clients_exclusive` minimizes all non-target clients. Could be unified with a flag.

### I9. `keystats_cli.lua` redundant open/close before `dofile`
`plugins/keystats_cli.lua:11-18`
`load_db` opens and closes the file to check readability, then calls `dofile`. The open/close is redundant since `pcall(dofile, path)` handles non-existent files.

### I10. `rc.lua` `layout_hide_timer` timeout is a magic number
`rc.lua:2810-2812`
The `0.20` second timeout should be a named constant like the other timing constants at lines 858-865.

---

# DEAD-CODE

## MEDIUM

### D1. `tag_indicators.lua` two large commented-out blocks
`plugins/tag_indicators.lua:92-164` (73 lines, legacy widget-overlay), `plugins/tag_indicators.lua:390-419` (30 lines, legacy widget template)
Both marked "disabled" and kept "for reference" but never reachable.

### D2. `tag_indicators.lua` `wrap_taglist_template` never called
`plugins/tag_indicators.lua:268-347`
Defined but never invoked. `M.init()` calls `apply_tag_label_patch()` instead. The function and its helper `update_occ_square_widget` (only called by `wrap_taglist_template` and `M.update_square`) are dead unless `M.update_square` is called externally.

### D3. `tag_indicators.lua` `get_theme_square_color` fallback chain unreachable
`plugins/tag_indicators.lua:175`
`return TAG_SQUARE_COLOR or beautiful.taglist_fg_occupied or ...` — `TAG_SQUARE_COLOR` is always a non-nil string (set at line 19), so the `or` fallbacks can never execute.

### D4. `notification_center.lua` ~250 lines of commented-out code
`plugins/notification_center.lua:508-596` (89 lines), `plugins/notification_center.lua:685-787` (103 lines), `plugins/notification_center.lua:872-916` (45 lines), `plugins/notification_center.lua:1111-1115,1129-1132,1141` (margin values), `plugins/notification_center.lua:1419-1426` (width adjustment)

### D5. `resource_popup.lua` commented-out blocks
`plugins/resource_popup.lua:338-350` (13 lines, old temp sensor list), `plugins/resource_popup.lua:539-548` (10 lines, disabled fan section), `plugins/resource_popup.lua:620-622` (commented-out `separator()` and `fan_body`)

### D6. `notifications.lua` commented-out font and config lines
`plugins/notifications.lua:34,39-40` (old font definitions), `plugins/notifications.lua:436` (commented-out `border_width = 0`)

### D7. `keystats.lua` redundant nil-guards in `compute_id`
`plugins/keystats.lua:163-164`
`(mods_key or "")` — `mods_key` is always a string from `table.concat`. `(tostring(key) or "?")` — `tostring()` never returns nil. Both `or` fallbacks are unreachable.

### D8. `dnd_to_tag.lua` `border_animation_timer` fallback branches
`plugins/dnd_to_tag.lua:170-174, 270-274`
Dead code — the variable is never defined and the `and` guards ensure they never execute.

### D9. `solo_super.lua` DEBUG diagnostic code
`plugins/solo_super.lua:48-82, 99-101`
`DEBUG = false` and all associated diagnostic notification code never executes.

### D10. `shimmer/animation.lua` large commented-out caching block
`plugins/shimmer/animation.lua:2379-2403` (~25 lines in `get_letter_shimmer_markup`)

### D11. `shimmer/animation.lua` commented-out old solid color branch
`plugins/shimmer/animation.lua:2625-2636`

### D12. `shimmer/animation.lua` commented-out alternative `preset_list`
`plugins/shimmer/animation.lua:320-344`

### D13. `shimmer/animation.lua` commented-out old `set_speed_multiplier`/`get_speed_multiplier`
`plugins/shimmer/animation.lua:479-485`

### D14. `shimmer/helpers.lua` five commented-out RNG-based implementations
`plugins/shimmer/helpers.lua:237-244, 253-258, 272-279, 324-329, 348-354`

### D15. `shimmer/helpers.lua` four commented-out RNG-based offset/shine calculations
`plugins/shimmer/helpers.lua:84-90, 101-104, 156-162, 165-169`

### D16. `shimmer/animation.lua` ~14 "old: static ..." commented-out marker lines
`plugins/shimmer/animation.lua:2038-2040, 2045-2047, 2053-2055, 2060-2062, 2066-2068, 2072-2074, 2078-2081, 2091-2093, 2101-2103, 2107-2109, 2113-2115, 2119-2121, 2126-2128, 2133-2135`

### D17. `shimmer/init.lua` commented-out legacy API functions
`plugins/shimmer/init.lua:480-486, 634-636, 701-702`

### D18. `shimmer/integrations.lua` commented-out alternatives and dangling timer wrappers
`plugins/shimmer/integrations.lua:437-446, 675-688, 748-751`

### D19. `hotkey_dupe_detector.lua` commented-out success notification
`plugins/hotkey_dupe_detector.lua:146-154`

### D20. `rc.lua` 338-line commented-out `awful.rules.rules` block
`rc.lua:4072-4410`
The entire old rules system is commented out but kept for reference.

### D21. `rc.lua` 148-line commented-out tyrannical configuration
`rc.lua:899-1047`

### D22. `keybindings.lua` ~100 lines of commented-out solo-super keygrabber code
`rc/keybindings.lua:816-918`

## LOW

### D23. `theme.lua` ~20+ commented-out alternative theme values
`milktheme/theme.lua:74, 84-89, 104-105, 138-140, 180, 192, 196-199, 202, 247, 252-257, 259, 289-290, 317, 333-339, 405, 591`

### D24. `shimmer/animation.lua` three commented-out `SHINE_TIME_QUANTIZATION` values
`plugins/shimmer/animation.lua:1491-1493`

### D25. `shimmer/animation.lua` commented-out `palette_length = 256`
`plugins/shimmer/animation.lua:350`

### D26. `shimmer/animation.lua` six commented-out `target_fps` values
`plugins/shimmer/animation.lua:153-158`

### D27. `shimmer/animation.lua` two "duplicate function removed" comments
`plugins/shimmer/animation.lua:634, 637`

### D28. `keybindings.lua` first `add_client_keys` definition never called
`rc/keybindings.lua:154-174`
A local function `add_client_keys` is defined but never invoked. The actual client keys are added at line 793 using a second `add_client_keys` defined at line 775.

### D29. `keybindings.lua` unused locals `quake` and `toggle_mode_glyphs_style`
`rc/keybindings.lua:146` (`local quake = ctx.quake`), `rc/keybindings.lua:145` (`local toggle_mode_glyphs_style`)
Assigned but never referenced; the keybindings use `ctx.quake_toggle_lain` and `ctx.toggle_mode_glyphs_style` directly.

### D30. `rc.lua` functions defined and passed to keybindings but never used there
`rc.lua:1835` (`notification_center_delete_oldest` defined at line 1760), `rc.lua:1303-1309, 1845` (`toggle_arandr` defined, passed, but binding commented out at keybindings.lua:489)

### D31. `rc.lua` functions defined but never called
`rc.lua:1584-1626` (`get_tag_dominant_color`, 42 lines), `rc.lua:1538-1580` (`create_terminal_icon_surface`, 42 lines), `rc.lua:823-834` (`blend_hex_colors`, 11 lines)

### D32. `rc.lua` `FORCE_GENERIC_ICONS` and `GENERIC_ICON_PATH` never defined
`rc.lua:3098`
Never declared as locals; always nil, so the condition is always false. The entire if-branch is dead code.

### D33. `rc.lua` `s.myaltwibox` created with no widgets, never shown
`rc.lua:3503-3524`
Created per screen with empty left/middle/right sections, set to `visible = false`, and never toggled or populated.

### D34. `rc.lua` `keyboard_widget` created but commented out in wibox
`rc.lua:3416, 3486`
`system_widgets.keyboard()` is called and the widget is created, but it's commented out in the wibox setup (line 3486).

### D35. `window_fx.lua` ghost wibox never explicitly destroyed
`plugins/window_fx.lua:73-94`
The ghost wibox created for close animation is set `visible = false` but never explicitly destroyed. During rapid window close sequences multiple invisible wiboxes can accumulate before GC.

---

# DUPLICATION

## MEDIUM

### U1. `make_text` helper byte-for-byte identical across three files
`plugins/volume_popup.lua:47-56`, `plugins/brightness_popup.lua:56-65`, `plugins/resource_popup.lua:378-387`
Same function, same defaults, same widget structure. Should live in `popup_common.lua`.

### U2. `separator` helper byte-for-byte identical across three files
`plugins/volume_popup.lua:58-65`, `plugins/brightness_popup.lua:67-74`, `plugins/resource_popup.lua:389-396`
Same `forced_height = dpi(1)`, `forced_width = CONTENT_W`, `bg = COLOR_PURPLE` pattern.

### U3. Color/font constants block near-identical across all popup files
`plugins/volume_popup.lua:20-28`, `plugins/brightness_popup.lua:19-29`, `plugins/resource_popup.lua:31-42`, `plugins/media_popup.lua:16-19`, `plugins/notifications.lua:17-41`, `plugins/notification_center.lua:111-125`
Each file independently defines `COLOR_PURPLE`, `COLOR_GOLD`, `COLOR_BLACK`, `COLOR_WHITE`, `COLOR_GREY`, `FONT_HEAD`, `FONT` with the same theme-fallback pattern `(beautiful.main_gold and beautiful.main_gold.base) or "#FFD700"`. A shared `popup_theme` module would eliminate this.

### U4. `hide` function follows the same pattern in all popup files
`plugins/volume_popup.lua:394-404`, `plugins/brightness_popup.lua:519-529`, `plugins/resource_popup.lua:668-677`, `plugins/media_popup.lua:374-381`
Each does: set `popup.visible = false`, call `popup_common.outside_click_teardown(popup)`, remove the escape key via `root._remove_key`. Only variation: volume/brightness also clear `popup._showing`. Could be a single `popup_common.hide(popup)`.

### U5. `show` function follows the same pattern across all popup files
`plugins/volume_popup.lua:406-433`, `plugins/brightness_popup.lua:531-555`, `plugins/resource_popup.lua:755-769`, `plugins/media_popup.lua:354-372`
Each does: `ensure_popup()`, emit `popup::opening`, refresh content, `popup:_apply_size_now(false)`, set `popup.visible = true`, `awful.placement.next_to`, setup outside-click if not pinned, append escape key. The `popup_common` module already shares the pin and outside-click logic but not the show/hide/toggle lifecycle.

### U6. `attach` function near-identical across popup files
`plugins/volume_popup.lua:446-462`, `plugins/brightness_popup.lua:568-579`, `plugins/resource_popup.lua:791-809`
Each connects `button::press` on the widget, calls `popup_common.widget_press(popup)`, and toggles on left-click / hides on right-click. `volume_popup` additionally handles scroll-wheel swallow. A `popup_common.attach(popup, widget, opts)` would cover all cases.

### U7. `popup::opening` close handler identical across files
`plugins/volume_popup.lua:487-489`, `plugins/brightness_popup.lua:591-593`, `plugins/media_popup.lua:404-406`, `plugins/notification_center.lua:1466-1468`
`awesome.connect_signal("popup::opening", guarded(function() if popup and popup.visible then hide() end end))` — same in every file.

### U8. Border width and shape fallbacks identical across all popup files
All files use `beautiful.bar_edge_width or beautiful.border_width or dpi(1)` for border width and `function(cr, w, h) gshape.rounded_rect(cr, w, h, beautiful.border_radius or dpi(3)) end` for shape. Appears in volume_popup:386-390, brightness_popup:511-515, resource_popup:658-662, media_popup:103-106, notifications.lua:437-441, notification_center.lua:1199-1201.

### U9. `mode_glyphs.lua` and `shimmer/animation.lua` duplicate prefix builders
`plugins/mode_glyphs.lua:16-38`, `plugins/shimmer/animation.lua:1803-1818`
`get_prefix` and `get_client_status_prefix` are nearly identical — both build the same symbol string (`✈`, `+`/`⬌`/`⬍`, `▪`, `⌃`/`▴`/`▾`) from the same client properties. The animation.lua version adds a trailing space and uses the table pool, but the logic is identical.

### U10. `shimmer/helpers.lua` and `shimmer/strategies.lua` duplicate noise/fib helpers
`plugins/shimmer/helpers.lua:25-28` and `plugins/shimmer/strategies.lua:16-17` (`_fract`, `_noise1`), `plugins/shimmer/helpers.lua:65-72, 217-224` and `plugins/shimmer/strategies.lua:135-141, 145-151` (`fib` defined four times with identical implementation)

### U11. Hex-to-RGB parsing implemented independently in 4+ places
`plugins/shimmer/animation.lua:181-202, 3129-3135` (`hex_to_hsv`), `plugins/shimmer/integrations.lua:472-484` (`hex_to_rgb` in `lerp_color`), `plugins/shimmer/border.lua:163-167` (inline `color:match("#(%x%x)(%x%x)(%x%x)")`)

### U12. Cache eviction pattern repeated 6+ times
`plugins/shimmer/animation.lua:265-280, 286-303, 1667-1677, 1707-1723, 2344-2357`, `plugins/shimmer/integrations.lua:132-147`
The "clear 25%/keep 75% by iterating `pairs`" pattern. A shared `evict_cache(cache_table, stats, max_entries, keep_ratio)` helper would eliminate this.

### U13. Text progress bar rendering duplicated
`plugins/brightness.lua:75-78`, `plugins/volume_osd.lua:18-19`
`string.rep("█", filled) .. string.rep("░", bar_len - filled)` duplicated in both OSD modules.

### U14. `tag_pager.lua` and `notification_center.lua` duplicate icon caching pattern
`plugins/tag_pager.lua:223-262`, `plugins/notification_center.lua:433-505`
Both cache icon resolution results by a string key, both fall back to `menubar.utils.lookup_icon`, both handle terminal class names specially.

## LOW

### U15. `keybindings.lua` and `rc.lua` both define `create_matcher`
`rc/keybindings.lua:68-74`, `rc.lua:818-820`
The keybindings.lua version supports instance matching via a second parameter; the rc.lua version only matches by class. The rc.lua version is used at line 818 but the function is never actually called in rc.lua (it was used by old commented-out rules).

### U16. `battery_popup.lua` `read_file` pattern
`plugins/battery_popup.lua:53-59`
The open/read-line/close pattern could use a shared helper since it's a common pattern, though it only appears once in the audited files.

---

# STYLE

## LOW

### S1. `rc.lua:840` `function() do end end` no-op
`{"Cancel", function() do end end}` uses `do end` (an empty block) as a no-op. Should simply be `function() end`.

---

# Appendix: Cross-cutting observations

## Hardcoded `"Hack Nerd Font"` strings (50+ occurrences)
13 in rc.lua, 9 in notification_center.lua, 6 in notifications.lua, 6 in brightness_popup.lua, 5 in theme.lua, 4 in volume_popup.lua, 4 in resource_popup.lua, 3 in battery_popup.lua, 2 in system_widgets.lua, 2 in media_popup.lua, 1 in popup_common.lua. Should be derived from `beautiful.font` or a `scale_font` helper (which already exists in milktheme/theme.lua:31).

## Signal/timer cleanup pattern
The recurring HIGH-severity bug class is signal handlers and timers connected inside `connect_for_each_screen` (rc.lua) or at module body (shimmer/border, window_fx, system_widgets) without disconnect/cleanup on hot-reload or screen removal. A consistent `init()`/`deinit()` pair per module, or a `gears.object`-based registration that tracks and tears down connections, would address B5-B7, B20, P10, P11, and several MEDIUM items at once.

## Popup family refactor
The volume/brightness/resource/media/notification_center popups share show/hide/attach/outside-click/constants scaffolding that belongs in `popup_common`. Consolidating U1-U8 into `popup_common` (plus a `popup_theme` constants module) would remove ~300 lines of duplication and make the popup lifecycle consistent (fixing B14, B15, B27 in the process).
