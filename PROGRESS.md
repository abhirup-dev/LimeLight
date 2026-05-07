# FocusFX Progress Plan

This file tracks the staged path to a v0 implementation. Each phase should be self-contained: it must leave the app buildable, testable, and measurably stable before moving on.

Performance is a release blocker in every phase. Unit tests and targeted verification are required for each increment.

## Phase 0: Project Skeleton and Baseline

Goal: create a minimal buildable project with app, CLI, test targets, and shared models.

Deliverables:

- Swift/Xcode project targeting macOS 14.0+ with Swift 5.10 compatibility.
- `FocusFX.app` minimal menu bar daemon.
- `focusfx` CLI target with `--help` and `--version`.
- Shared module for protocol/config/domain types.
- Unit test target wired into the build.
- Basic logging and signpost helpers for performance instrumentation.

Performance focus:

- No background polling except explicit test hooks.
- App launches without noticeable UI stall.
- Establish baseline idle CPU and memory measurement commands.

Verification:

- Build app and CLI from clean checkout.
- Unit test: version/info models encode and decode.
- Unit test: CLI argument parser handles `--help` and `--version`.
- Manual check: app launches and quits cleanly.
- Record baseline `ps` RSS and idle CPU in this file when implemented.

Status:

- [x] focusfx-1.1 Scaffold macOS project targets — `Package.swift` with `FocusFXCore` + `FocusFXDaemon`/`focusfx`/`borders` executables + tests + `CSkyLight` system-library module + `Scripts/bundle-app.sh`.
- [x] focusfx-1.2 Daemon, CLI, models, logging baseline — NSApplication accessory app with menu-bar status item, GCD-based `SIGINT`/`SIGTERM` handlers; CLI `--help`/`--version`; `DaemonInfo` / `VersionInfo`; OSLog `Logger` + `OSSignposter` + `mainThreadBudget()` instrument.
- [x] focusfx-1.3 Baseline launch/idle metrics (recorded below).

### Baseline measurement commands

```bash
swift build
./Scripts/bundle-app.sh debug

.build/FocusFX.app/Contents/MacOS/FocusFXDaemon &
PID=$!
sleep 5
ps -o pid,rss,%cpu,etime,comm -p $PID
top -l 2 -pid $PID -stats pid,cpu,mem,command | tail -3   # use the SECOND sample
kill -TERM $PID
```

`ps` reports cumulative `%CPU` since launch; `top -l 2` (and using the second sample) reports the instantaneous interval. For deeper profiling: `xcrun xctrace record --launch -- .build/FocusFX.app/Contents/MacOS/FocusFXDaemon`.

### Baseline (2026-05-07, debug, macOS 14.7.3 / Xcode 15.4)

Daemon left idle for 18 s on this developer machine:

| Sample @ elapsed | RSS     | %CPU (cumulative) |
|------------------|---------|-------------------|
| 3 s              | 25.4 MB | 0.0%              |
| 8 s              | 21.8 MB | 0.0%              |
| 18 s             | 22.2 MB | 0.0%              |
| `top -l 1`       | 10 MB   | 0.0%              |

Plan targets (idle): CPU < 1.0%, RSS < 80 MB — baseline well under both. No `MTKView` draw loop, no polling sources. Daemon exits cleanly on `SIGTERM`. Re-record this table after each phase that adds long-running infrastructure (IPC server, window tracker, border engine, effect engine).

### Re-baseline after Phase 1 (2026-05-07, debug)

Daemon now also brings up `IPCServer` (off-main accept) and async-loads the config snapshot at startup.

| Sample @ elapsed | RSS     | %CPU |
|------------------|---------|------|
| 5 s              | 23.4 MB | 0.0% |
| 15 s             | 20.4 MB | 0.0% |
| `top -l 2` (2nd) | 9.7 MB  | 0.0% |

No regression vs. Phase 0 baseline. Re-record after WindowTracker / BorderEngine land.

## Phase 1: IPC and CLI Control Plane

Goal: make `FocusFX.app` controllable through a non-blocking local protocol before building rendering behavior.

Deliverables:

- Unix domain socket server at `~/Library/Application Support/FocusFX/focusfx.sock`.
- Newline-delimited JSON request/response protocol.
- `focusfx status --json`.
- `focusfx daemon open`.
- `focusfx daemon quit`.
- Request timeout and clear error handling.
- IPC server runs off-main.

Performance focus:

- Socket accept/read/write never blocks the main thread.
- `status` returns from cached state, not a full system scan.
- Malformed clients cannot block valid clients.

Verification:

- Unit test: request decoding and response encoding.
- Unit test: error response shape.
- Unit test: unsupported command returns stable error code.
- Integration test: app creates socket on launch.
- Integration test: 100 sequential `status --json` calls complete without app hang.
- Manual check: Activity Monitor shows near-zero idle CPU.

Status:

- [ ] Not started

## Phase 2: JSONC Config Store

Goal: load and validate a hackable config without impacting runtime responsiveness.

Deliverables:

- Default config path: `~/Library/Application Support/FocusFX/config.jsonc`.
- JSONC parser supporting comments and trailing commas.
- Config schema model for performance, borders, effects, popup, idle return, rules, and exclude rules.
- Immutable compiled config snapshot.
- Regex compilation for window-title rules.
- `focusfx config path`.
- `focusfx config validate`.
- `focusfx reload`.

Performance focus:

- Parse config off-main.
- Compile regexes off-main.
- Runtime event paths read immutable config snapshots without main-thread locks.
- Invalid config keeps last valid snapshot active.

Verification:

- Unit test: comments and trailing commas parse correctly.
- Unit test: invalid config reports diagnostics and does not replace active snapshot.
- Unit test: precedence order is CLI args, first matching rule, global config, built-in defaults.
- Unit test: rule matching by app name, bundle ID, exact title, contains, regex, and window ID.
- Performance test: generated config with 500 rules parses off-main and app stays responsive.

Status:

- [ ] Not started

## Phase 3: Window Tracking Core

Goal: track windows, focus, frames, and Spaces with the data needed for both borders and transient effects.

Deliverables:

- `WindowTracker` using SkyLight/SLS for strict JankyBorders-style window tracking.
- Accessibility fallback for focused window metadata and titles.
- Cached window registry keyed by window ID.
- Focused window query for `focusfx current-window --json`.
- `focusfx windows --json`.
- Event coalescing for move/resize/focus bursts.
- Per-window generation counters to reject stale async work.

Performance focus:

- Window events are handled on a dedicated queue.
- Move/resize events coalesce with default `16ms` window.
- Full window enumeration is avoided except startup, explicit resync, and topology changes.
- Main thread receives only minimal final UI mutations.

Verification:

- Unit test: coalescing collapses burst events into latest frame.
- Unit test: stale generation updates are rejected.
- Unit test: window registry create/update/destroy transitions.
- Integration test: `current-window --json` returns valid focused-window metadata.
- Integration test: `windows --json` returns current visible windows.
- Manual check: switch between Finder, Warp, Arc, Cursor, and Activity Monitor without stalls.

Status:

- [ ] Not started

## Phase 4: Persistent Border Engine

Goal: replace JankyBorders for active and inactive borders.

Deliverables:

- `BorderEngine` creates and manages border windows.
- Active and inactive border drawing.
- Runtime style updates.
- JankyBorders-compatible `borders` shim.
- `focusfx borders enable`.
- `focusfx borders disable`.
- `focusfx borders style`.
- `focusfx borders redraw-all`.
- Support `active_color`, `inactive_color`, `background_color`, `width`, `style`, `order`, `hidpi`, `blacklist`, `whitelist`, `ax_focus`, and `apply-to`.

Performance focus:

- Incremental border updates only for affected windows.
- Redraws are coalesced during resize/move.
- No active draw loop while borders are static.
- Avoid global redraw unless config reload or explicit `redraw-all`.

Verification:

- Unit test: JankyBorders argument parser compatibility.
- Unit test: solid, glow, and gradient color style parsing.
- Unit test: blacklist and whitelist decisions.
- Integration test: `borders active_color=... width=...` updates running daemon.
- Integration test: per-window `apply-to` override affects only target window.
- Performance test: repeated resize/move does not grow queues or stale border windows.
- Manual check: active/inactive borders follow windows across resize, move, hide, unhide, and Space change.

Status:

- [ ] Not started

## Phase 5: Transient Metal Effects

Goal: add Tinkle-style transient effects around the focused or requested window.

Deliverables:

- `EffectEngine` with transparent click-through overlay window.
- Metal renderer with `neon`, `shockwave`, `line`, and `cometRing`.
- `focusfx trigger`.
- Effect selection from config rules.
- Effect duration, color, and target window overrides.
- Renderer pauses when inactive.

Performance focus:

- `MTKView` draw loop runs only during active effect.
- Metal pipeline states are compiled once and reused.
- Effect triggers never block IPC response on render completion.
- Repeated triggers cancel or replace stale effects cleanly.

Verification:

- Unit test: effect config resolution by rule and CLI override.
- Unit test: invalid effect name returns stable error.
- Integration test: `focusfx trigger --effect neon` succeeds.
- Integration test: repeated trigger burst does not hang daemon.
- Performance test: idle GPU activity stops after effect completion.
- Manual check: effects render on focused window and never intercept mouse input.

Status:

- [ ] Not started

## Phase 6: Popup Engine and Idle Return

Goal: add contextual popups and focus-return-after-idle behavior.

Deliverables:

- `PopupEngine` with click-through transparent overlay window.
- `focusfx popup`.
- Popup placement rules.
- Popup content with app icon, app name, window title, title, and message.
- `IdleReturnDetector` using HID event idle time.
- Idle return popup/effect from config.

Performance focus:

- Idle detector runs on a background queue.
- Poll interval defaults to `1s`.
- Popup rendering is short-lived and does not take focus.
- App/window icon lookup is cached.

Verification:

- Unit test: idle active -> idle -> pending return -> emitted transitions.
- Unit test: popup message template substitution such as `{idleMinutes}`.
- Unit test: popup placement inside target frame.
- Integration test: `focusfx popup --title Test --message Hello` succeeds.
- Manual check: return after configured idle threshold shows popup exactly once.
- Manual check: popup does not steal focus or block clicks.

Status:

- [ ] Not started

## Phase 7: Hammerspoon and AeroSpace Integration

Goal: make the app easy to automate from the user’s current window-management environment.

Deliverables:

- `focusfx.lua` Hammerspoon helper.
- Example Hammerspoon hotkeys.
- AeroSpace startup snippets.
- AeroSpace workspace-change hook snippet.
- Compatibility note for replacing existing `borders` startup command.
- Optional `aerospaceWorkspace` context support when provided by hook.

Performance focus:

- Hammerspoon calls use short-lived CLI invocations with timeouts.
- AeroSpace hooks must not block workspace switching.
- Hook commands should return quickly after enqueueing work.

Verification:

- Unit test: CLI command construction in Lua examples, if test harness is available.
- Integration test: `focusfx trigger` and `focusfx popup` are safe for repeated hotkey calls.
- Manual check: AeroSpace `after-startup-command` starts daemon and borders.
- Manual check: AeroSpace workspace-change hook triggers a short effect.
- Manual check: Hammerspoon hotkey triggers effect without delay.

Status:

- [ ] Not started

## Phase 8: v0 Hardening and Release Candidate

Goal: stabilize performance, crash behavior, diagnostics, and developer ergonomics for v0.

Deliverables:

- `focusfx perf --json`.
- Structured diagnostics for AX permission, SkyLight availability, socket state, config validity, and render state.
- Crash-safe cleanup of socket and stale overlay/border windows.
- README with install, config, CLI, Hammerspoon, and AeroSpace examples.
- Known limitations section.
- Basic uninstall instructions.

Performance focus:

- Idle CPU target: under `1%`.
- Physical memory target: under `80 MB`.
- Main-thread p95 task duration under `8ms` during focus bursts.
- 100 rapid focus changes must not hang the app.
- 100 IPC status calls must not stall UI.
- Large config reload must not block UI.

Verification:

- Full unit test suite passes.
- Integration tests pass.
- Manual QA matrix:
  - Finder
  - Warp
  - Arc
  - Cursor
  - Activity Monitor
  - full-screen app
  - minimized window restore
  - multi-monitor
  - AeroSpace workspace switch
  - Hammerspoon hotkey
- Instruments pass:
  - no main-thread hangs during event bursts
  - no persistent Metal draw loop while idle
  - no steady memory growth after repeated focus/resize/config reload cycles

Status:

- [ ] Not started
