# LimeLight: High-Performance Focus Effects + JankyBorders Replacement

## Summary

Build a fresh macOS utility that combines Tinkle-style transient focus effects with JankyBorders-style persistent window borders, with performance and main-thread responsiveness as first-class design constraints.

Target this machine first: macOS 14.7.3, Xcode 15.4, Swift 5.10, SDK 14.5. Avoid Swift 6, Xcode 26, and macOS 15-only APIs.

Chosen direction:

- Fresh app, not a Tinkle fork.
- JSONC config only.
- Strict JankyBorders parity using private SkyLight/SLS APIs.
- AeroSpace support through CLI/event-hook snippets.
- Ship `LimeLight.app`, `limelight` CLI, `borders` compatibility shim, and `limelight.lua`.
- Keep UI/main thread work minimal; window tracking, IPC, parsing, coalescing, and redraw scheduling must run off-main where possible.

## Architecture & Performance Model

### Process Structure

- `LimeLight.app` runs as a menu bar daemon with `LSUIElement = true`.
- Core subsystems:
  - `WindowTracker`: tracks windows, Spaces, focus, movement, resize, creation, destruction.
  - `BorderEngine`: persistent active/inactive borders compatible with JankyBorders.
  - `EffectEngine`: transient Metal effects.
  - `PopupEngine`: SwiftUI/AppKit popups.
  - `IdleReturnDetector`: return-after-idle triggers.
  - `IPCServer`: Unix socket JSON protocol.
  - `ConfigStore`: JSONC loading, validation, rule matching, live reload.
- Main thread owns only AppKit/SwiftUI object creation, window ordering, and final UI mutations.
- Non-main queues:
  - `window-event-queue`: SkyLight/SLS event handling and coalescing.
  - `render-scheduling-queue`: border invalidation and redraw batching.
  - `ipc-queue`: socket accept/read/write and command parsing.
  - `config-queue`: config parsing, validation, schema checks, rule compilation.
  - `idle-queue`: idle polling and state transitions.

### Main-Thread Rules

- Never parse config on the main thread.
- Never block on IPC from the main thread.
- Never call shell commands from the main thread.
- Never perform regex matching on the main thread.
- Never perform full window enumeration on the main thread except during controlled startup handoff.
- Main-thread work must be limited to short AppKit calls:
  - create/order/hide windows
  - update window frame
  - assign views/layers
  - apply final drawing buffers if required by API
- Any operation expected to take more than `2ms` must be scheduled off-main.
- Add debug instrumentation to log any main-thread task exceeding `8ms`.

### Event Coalescing

- Coalesce move/resize/focus bursts before redraw.
- Default coalescing window: `16ms`.
- During live resize/move, update border frame at most once per display frame.
- Drop stale redraw requests when a newer frame for the same window exists.
- Maintain a per-window generation counter so async redraws cannot apply stale output.
- Avoid global redraws except:
  - config reload affecting global border settings
  - display/Space topology change
  - explicit `limelight borders redraw-all`

## Public Interfaces

### CLI

Primary binary:

```bash
limelight daemon open
limelight daemon quit
limelight status --json
limelight reload
limelight current-window --json
limelight trigger [--effect NAME] [--window focused|WINDOW_ID] [--color '#RRGGBB'] [--duration-ms 500]
limelight popup [--title TEXT] [--message TEXT] [--window focused|WINDOW_ID]
limelight borders enable
limelight borders disable
limelight borders style [--active-color 0xffe1e3e4] [--inactive-color 0xff494d64] [--width 5.0]
limelight borders redraw-all
limelight windows --json
limelight effects list --json
limelight config path
limelight config validate
limelight perf --json
```

JankyBorders compatibility shim:

```bash
borders active_color=0xffe1e3e4 inactive_color=0xff494d64 width=5.0 style=round
borders style=round active_color=glow(0xffff0000) inactive_color=0xff494d64 width=5.0
```

The shim maps supported JankyBorders args into daemon commands. Unsupported args return a clear error.

### IPC

Use newline-delimited JSON over:

```text
~/Library/Application Support/LimeLight/limelight.sock
```

Request:

```json
{"id":"uuid","command":"trigger","args":{"effect":"cometRing","target":"focused"}}
```

Response:

```json
{"id":"uuid","ok":true,"result":{}}
```

Error:

```json
{"id":"uuid","ok":false,"error":{"code":"not_authorized","message":"Accessibility permission is not granted"}}
```

IPC requirements:

- Socket server runs off-main.
- Each client request has a default timeout of `1500ms`.
- Long-running commands must return accepted/status rather than block.
- `limelight status --json` must respond without forcing a full window rescan.

### Hammerspoon

Ship `limelight.lua`:

```lua
local limelight = require("limelight")

limelight.trigger("cometRing")
limelight.popup("Back", "Returned after idle")
limelight.borders.enable()
limelight.borders.disable()
limelight.reload()
limelight.currentWindow()
```

Use the CLI in v1. Calls must be non-interactive and safe for hotkeys.

### AeroSpace

LimeLight must work without AeroSpace, but provide ready snippets.

Native startup:

```toml
after-startup-command = [
  'exec-and-forget limelight daemon open',
  'exec-and-forget limelight borders enable'
]
```

JankyBorders-compatible startup:

```toml
after-startup-command = [
  'exec-and-forget borders style=round active_color=0xffff0000 inactive_color=0xff494d64 width=5.0'
]
```

Workspace hook:

```toml
exec-on-workspace-change = [
  '/bin/bash', '-lc',
  'limelight trigger --effect workspacePulse --duration-ms 350'
]
```

## JSONC Config

Default path:

```text
~/Library/Application Support/LimeLight/config.jsonc
```

Support comments and trailing commas. Provide a JSON Schema at:

```text
~/Library/Application Support/LimeLight/config.schema.json
```

Default config:

```jsonc
{
  "performance": {
    "eventCoalesceMs": 16,
    "maxMainThreadTaskMs": 8,
    "idleCpuTargetPercent": 1.0,
    "enablePerfLogging": true
  },

  "borders": {
    "enabled": true,
    "style": "round",
    "order": "below",
    "width": 5.0,
    "hidpi": false,
    "active": { "color": "0xffe1e3e4" },
    "inactive": { "color": "0xff494d64" },
    "background": {
      "enabled": false,
      "color": "0x00000000"
    }
  },

  "effects": {
    "default": {
      "name": "cometRing",
      "color": "#00D1FF",
      "durationMs": 500
    }
  },

  "popup": {
    "enabled": true,
    "placement": "topRight",
    "durationMs": 2200,
    "showAppIcon": true,
    "showWindowTitle": true
  },

  "idleReturn": {
    "enabled": true,
    "thresholdSeconds": 300,
    "popup": {
      "title": "Welcome back",
      "message": "Idle for {idleMinutes}m"
    },
    "effect": "cometRing"
  },

  "rules": [
    {
      "name": "Warp windows",
      "match": { "appName": "Warp" },
      "borders": {
        "active": { "color": "glow(0xff00d1ff)" },
        "inactive": { "color": "0x88494d64" },
        "width": 6.0
      },
      "effect": {
        "name": "cometRing",
        "color": "#00D1FF"
      }
    },
    {
      "name": "Browser docs",
      "match": {
        "windowTitleRegex": ".*GitHub.*|.*docs.*"
      },
      "effect": {
        "name": "neon",
        "color": "#FFD166"
      }
    }
  ],

  "exclude": [
    { "appName": "System Settings" },
    { "windowTitleRegex": "^Picture in Picture$" }
  ]
}
```

Rule matching:

- `appName`
- `bundleIdentifier`
- `windowTitle`
- `windowTitleContains`
- `windowTitleRegex`
- `windowID`
- optional `aerospaceWorkspace` when supplied by hook/CLI context

Precedence:

1. CLI args
2. First matching rule in config order
3. Global config
4. Built-in defaults

Performance requirement:

- Parse JSONC and compile regexes off-main.
- Store compiled rules in an immutable snapshot.
- Window events read the current config snapshot without locking the main thread.
- Invalid config keeps the last valid snapshot active.

## JankyBorders Parity

Implement these JankyBorders-compatible options:

- `active_color`
- `inactive_color`
- `background_color`
- `width`
- `style=round|square|uniform`
- `order=above|below`
- `hidpi=on|off`
- `blacklist`
- `whitelist`
- `ax_focus=on|off`
- `apply-to=WINDOW_ID`

Color styles:

- solid: `0xffe1e3e4`
- glow: `glow(0xffff0000)`
- gradient: `gradient(top_left=0xff...,bottom_right=0xff...)`
- gradient: `gradient(top_right=0xff...,bottom_left=0xff...)`

Behavior:

- Draw active and inactive borders.
- Update borders on focus, move, resize, create, destroy, hide, unhide, and Space change.
- Keep borders attached to target windows and Spaces.
- Support runtime updates through both `limelight` and `borders`.
- Support per-window overrides via `apply-to`.
- Prefer incremental updates over full redraws.
- Keep idle CPU near zero.

## Test Plan

### Unit Tests

- JSONC parsing with comments/trailing commas.
- Config schema validation.
- Rule matching by app name, bundle ID, title, contains, regex, window ID.
- Config precedence.
- JankyBorders argument compatibility.
- IPC request/response success and error paths.
- Idle return state transitions.
- Event coalescing behavior and stale redraw rejection.

### Integration Tests

- Launch daemon and verify socket appears.
- `limelight status --json` returns valid JSON without full rescan.
- `borders active_color=... width=...` updates running daemon.
- `limelight trigger` renders effect on focused window.
- `limelight popup` renders without stealing focus.
- Config reload applies rules without blocking UI.
- Invalid config keeps previous valid config.
- Repeated resize/move events do not grow unbounded work queues.

### Performance Tests

- Idle state:
  - CPU target: under `1%`
  - physical memory target: under `80 MB`
  - no active `MTKView` draw loop
- Focus switch burst:
  - 100 rapid focus events must not hang the app.
  - main-thread p95 task duration under `8ms`.
- Resize/move burst:
  - redraws are coalesced.
  - no stale border frame after movement stops.
- IPC burst:
  - 100 `status` calls complete without UI stall.
  - malformed requests do not block valid clients.
- Config reload:
  - large config with 500 rules parses off-main.
  - UI remains responsive during reload.

### Manual QA

- Verify active/inactive borders across Finder, Warp, Arc, Cursor, Activity Monitor.
- Verify AeroSpace startup command works.
- Verify AeroSpace workspace-change hook triggers effect.
- Verify window-title rules change effects/borders.
- Verify multi-monitor and Space switching behavior.
- Verify full-screen/minimized windows do not leave stale borders.
- Verify Hammerspoon hotkeys trigger effects/popups.
- Use Activity Monitor and Instruments to check CPU, memory, main-thread hangs, and GPU activity.

## Assumptions / Constraints

- Strict JankyBorders replacement requires private SkyLight/SLS APIs. This is acceptable for this project.
- Because strict parity is chosen, the practical runtime target is macOS 14.0+.
- Development target is Xcode 15.4 / Swift 5.10.
- JSONC is the only config format.
- AeroSpace is supported through hooks but is not required.
- No Sparkle updater in v1.
- No plugin runtime in v1.
- Performance is a release blocker: any implementation that blocks the main thread during event bursts, config reload, IPC, or redraw scheduling is not acceptable.
