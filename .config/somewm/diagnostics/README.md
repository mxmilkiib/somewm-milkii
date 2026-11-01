# somewm diagnostics (opt-in, off by default)

Read this first if a debugging session finds leftovers or half-remembered instrumentation. Everything diagnostic was stripped on 2026-10-29. This directory is the only place diagnostics live; nothing here runs unless started by hand.

## Two separate repos

- Compositor: `~/src/somewm` (dev tree) and `~/src/somewm-fixed` (the build the session runs, branch `feature/2026.10oct.29-personal-layer`, launched by `~/bin/somewm`). It carries fixes only, no diagnostics.
- Config: `~/.config/somewm` (this repo, standalone). Config changes never go to the compositor repo and the reverse.
- The systemd drop-ins are in `~/.config/systemd/user/` (the dotfiles tree, not a repo).

## State of the leak hunt (2026-10-29)

- Cause found: the startup profiler appended a table to a log on every `require`, forever. The wibox drawable requires a module per redraw. That led to the 00:24 OOM kill at 89 GB resident plus 103 GB swap. Fixed in config commit `d63a189` (stops logging after t+30s).
- Compositor fixes shipped in `feature/2026.10oct.29-personal-layer` (formerly `combined/main`): border colour changes paint the stored node and skip the full arrange (`5c68f53`, `94777e7`), and the drawable looks up the animation module once (`3901719`).
- Also fixed in the config: one shared `playerctl --follow` (`media_feed` in [rc.lua](../rc.lua)) instead of one per screen.
- Not proven closed. Measured growth explains a few GB over 4 hours, not 190 GB. Clean data so far: pids 2264 and 2287 grew under 100 MB over about 20 minutes each, with a flat tail. No long soak has run.
- Baseline census after boot: about 93k-107k Lua tables, 16k-18k functions, 57-85 MB Lua heap. The table count moved between 93k and 170k across runs, so one reading proves nothing.
- Open: the C heap was never profiled at startup (needs a restart). The integration run had 106 failures, only `test-animation-client-border` was checked (fails with the original code too).

## The memory cap stays

`~/.config/systemd/user/somewm.service.d/memory.conf` sets `MemoryMax=12G` and `MemorySwapMax=2G`. A runaway kills the compositor at 12 GB instead of taking the machine into swap. It is a safety net, not a diagnostic; keep it.

## Framework: `somewm-diag`

Run from this directory (or symlink into `~/bin`):

| Command | Does |
|---|---|
| `somewm-diag start` | Samples every 30 s and runs a Lua census hourly, as transient `systemd-run --user` units. |
| `somewm-diag stop` | Stops both. |
| `somewm-diag status` | Unit state and the last 3 samples. |
| `somewm-diag report` | Per compositor pid: anon at first and last sample, whole-run and last-hour growth in MB/h. |
| `somewm-diag census` | One census now. Full GC first, so the compositor pauses about a second. |
| `somewm-diag fds [PID]` | File descriptors by type, plus GPU (dmabuf) memory held. |

- Data goes to `~/.local/share/somewm-diag/` (`samples.tsv`, `census.log`). Delete the directory when done.
- Transient units end at reboot. Start again after one; a soak that spans a reboot is two soaks.
- Reading a soak: `anon_kb` should level off after warm-up. A steady climb is a leak. If anon grows but `lua_kb` does not, the leak is in C. `lua_kb` is read before a GC, so it is noisy; the census is the reliable Lua figure.
- GPU buffers do not show in anon. `fds` shows them (about 0.9-1.2 GB held).
- Sampler script: [somewm-diag](somewm-diag). Census walker: [census.lua](census.lua).

## Opt-in: startup profiler

[rc/startup_profiler.lua](../rc/startup_profiler.lua) times every `require`, `io.popen`, `os.execute` and spawn, and runs an event-loop stall watchdog. Gated at [rc.lua:175](../rc.lua#L175): set `SOMEWM_STARTUP_PROFILE=1` in the compositor's environment (for example `systemctl --user set-environment SOMEWM_STARTUP_PROFILE=1`, then restart the session) and unset it afterwards.

- Its logging stops after t+30s, but the 50 ms watchdog timer and the wrapped calls keep running for the whole session. Do not leave it on.
- Reports go to the journal and `/tmp/somewm-startup-profile.log`.

## Opt-in: grab debugging

[grab_debug.lua](grab_debug.lua) logs mousegrabber transitions to `~/.local/state/somewm/grab-debug.log` (unrotated, 0.25 s poll). It was removed from the config because the call sites were scattered. To re-enable, copy it to `plugins/` and re-add `grab_debug.claim(tag)` before a grab starts and `grab_debug.event(tag, msg)` where it ends or a watchdog fires. The sites it covered:

- `awful.mouse.client.move` and `.resize` in [rc/keybindings.lua](../rc/keybindings.lua) (`require("plugins.grab_debug").claim(...)`)
- tag pager cell drag, watchdog and `M.hide` in [plugins/tag_pager.lua](../plugins/tag_pager.lua)
- modifier drag in [plugins/dnd_to_tag.lua](../plugins/dnd_to_tag.lua)
- header drag in [plugins/popup_common.lua](../plugins/popup_common.lua)
- the stale-grab clear after a hot reload in [rc.lua](../rc.lua)

Pre-removal copies of those files are the newest `*.20261029_0236.bak` next to each (gitignored).

## Other ways in

- `perf record -e cpu-clock:u --user-callchains -g -p PID` attaches to the live compositor (plain `-g` and dwarf fail under `perf_event_paranoid=2`).
- Heap profiling at startup: tcmalloc or jemalloc, needs a restart.
- Sanitizers: the default build is release without them (`b3044af`); tests use ASAN and `tests/lsan-suppressions.txt` in the compositor repo.
