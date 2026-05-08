# LimeLight

> macOS 14+ menu-bar daemon that draws focus borders and runs transient
> Metal effects. JankyBorders-compatible CLI, AeroSpace-friendly,
> Hammerspoon-scriptable.

LimeLight runs as a single short-lived daemon (`LimeLight.app`) plus three
small binaries (`limelight`, `limelightd`, `borders`) that talk to it over
a per-user Unix socket. The shipping focus surface today is the border
engine; effects and popups are scaffolded behind feature flags.

## Status

- Borders engine: shipping. SLS-driven focus resolution
  (JankyBorders-equivalent) with AX fallback. Multi-monitor, AeroSpace
  tile UX, Arc multi-surface, fullscreen Spaces.
- Effects / popup: scaffolded — CLI verbs land with `focusfx-18` and
  `focusfx-22`.
- Hammerspoon helper, AeroSpace snippets: `examples/`.
- Sparkle updater, plugin runtime: explicitly out of scope for v0.

## Install

```bash
git clone https://github.com/<your-fork>/LimeLight.git
cd LimeLight
swift build -c release

# 1. Install the daemon executable as a .app so it can hold a status item.
#    Replace LIME_PREFIX with where you want the binaries to live.
LIME_PREFIX="$HOME/.local"
install -d "$LIME_PREFIX/bin"
install .build/release/limelight        "$LIME_PREFIX/bin/"
install .build/release/borders          "$LIME_PREFIX/bin/"
install .build/release/limelightd       "$LIME_PREFIX/bin/"

# 2. Start the daemon (or relaunch after upgrade).
limelight daemon open

# 3. Grant Accessibility permission when prompted (System Settings →
#    Privacy & Security → Accessibility). Required: AX is the
#    fallback path when SLS private symbols are unavailable, and is
#    used to enrich window titles even on the SLS path.
```

`swift build -c release` produces optimized binaries in `.build/release/`.
Debug builds (`swift build`) are fine for local hacking but slower.

## Configure

Default config path (override with `$LIME_CONFIG`):

```
$XDG_CONFIG_HOME/limelight/config.jsonc
# or, on macOS without XDG set:
~/Library/Application Support/LimeLight/config.jsonc
```

JSONC (JSON with comments and trailing commas) is supported. The full
schema is the `RawConfig` struct in `Sources/LimeCore/Config/ConfigSchema.swift`.
Minimal config:

```jsonc
{
  "borders": {
    "enabled": true,
    "style": "round",        // round | square | uniform
    "order": "below",        // above | below
    "width": 5.0,
    "hidpi": false,
    "active":   { "color": "0xffe1e3e4" },
    "inactive": { "color": "0xff494d64" }
  },

  "rules": [
    {
      "name": "Warp glow",
      "match": { "appName": "Warp" },
      "borders": {
        "active":   { "color": "glow(0xff00d1ff)" },
        "inactive": { "color": "0x88494d64" },
        "width": 6.0
      }
    }
  ],

  "exclude": [
    { "appName": "System Settings" },
    { "windowTitleRegex": "^Picture in Picture$" }
  ]
}
```

Validate without applying (won't swap the live snapshot):

```bash
limelight config validate
```

Apply changes after editing:

```bash
limelight reload
```

## CLI

```
limelight daemon open                 Launch / front the daemon.
limelight daemon quit                 Ask the daemon to terminate.
limelight status [--json]             Cached health snapshot.
limelight perf   [--json]             Diagnostics dump (AX/SLS/render/perf).
limelight reload                      Re-read config from disk.
limelight config validate             Validate without publishing.
limelight config path                 Print active config path.
limelight windows [--json]            Cached window list.
limelight current-window [--json]     Focused window.
limelight borders enable|disable|redraw-all|reset
limelight borders desired             Diagnostic: dump the engine's desired set.
```

`borders` (the JankyBorders-compatible shim) accepts upstream-style args:

```bash
borders active_color=0xffe1e3e4 inactive_color=0xff494d64 width=5.0 style=round order=below
```

`order`, `hidpi`, `ax_focus`, `blacklist`, `whitelist`, `apply-to`,
`background_color` all map onto the same `borders.style` IPC the daemon
exposes. `ax_focus=on` is the JB-equivalent escape hatch when SLS-based
focus misbehaves; it forces AX-only resolution.

## Hammerspoon

`examples/hammerspoon/limelight.lua` is a small module wrapping the
`limelight` CLI. Drop it into `~/.hammerspoon/` next to `init.lua`:

```lua
local L = require("limelight")
L.daemonOpen()
hs.hotkey.bind({"ctrl","alt"}, "B", function() L.bordersToggle() end)
hs.hotkey.bind({"ctrl","alt"}, "R", function() L.reload() end)
```

See `examples/hammerspoon/init-snippet.lua` for the full example.
Hotkeys are safe under repetition because each helper is a single
short-lived shell-out.

## AeroSpace

`examples/aerospace/aerospace.toml` ships drop-in snippets:

```toml
after-startup-command = ['exec-and-forget limelight daemon open']

# Per-workspace effect (forward-compat — wires fully when focusfx-18.2 lands):
exec-on-workspace-change = ['/bin/bash', '-c',
    'exec-and-forget limelight trigger --aerospace-workspace=$AEROSPACE_FOCUSED_WORKSPACE']
```

Rules can match by AeroSpace workspace once the hook supplies it:

```jsonc
"rules": [
  {
    "name": "focus mode on workspace 1",
    "match": { "aerospaceWorkspace": "1" },
    "borders": { "active": { "color": "glow(0xff00d1ff)" } }
  }
]
```

## Replacing JankyBorders

The bundled `borders` shim is wire-compatible with the upstream JB CLI.
Migration is a path swap — leave your existing
`after-startup-command = ['exec-and-forget borders ...']` line in place
and ensure LimeLight's `bin/` is ahead of any prior JB install on
`$PATH` (verify with `which borders`). Don't run both at the same time:
they bind the same overlay layer level and you'll get duplicated
strokes.

See `examples/README.md` for the full replacement guide and the
verification matrix.

## Known limitations

- **Private SLS symbols** are dlopen'd from
  `/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight`. If a
  future macOS removes them, the daemon degrades to AX-only focus —
  visible as `sls_resolver_off` in `limelight perf`. v0 has no Sparkle
  auto-update; you'd need to install a build that's been ported.
- **No plugin runtime in v1.** Effects/popups are static.
- **No background fill window** behind the active app yet — that needs
  `SLSReorderWindow` (tracked in `focusfx-007`).
- **`canJoinAllSpaces` was the v0 default; per-Space attachment now uses
  `.moveToActiveSpace`** — borders live on the user's current Space.
  Engine recomputes on SLS spaceChange events. Truly per-Space SLS
  attachment (using `SLSMoveWindowsToManagedSpace`) is a follow-up.
- **Screenshots don't capture borders.** Overlay NSWindows use
  `sharingType = .none` so they're invisible to `CGWindowListCopyWindowInfo`
  — the same enumeration we use to find target windows. This avoids
  bordering our own borders.

## Diagnostics

`limelight perf` is the first stop:

```
LimeLight 0.1.0  pid=8412  uptime=12m
  socket:        /tmp/limelight.sock
  accessibility: granted
  skylight:      streaming=yes frontWindowResolution=yes
  config:        /Users/me/Library/Application Support/LimeLight/config.jsonc
                 rules=4 diagnostics=0 bordersEnabled=true
  tracker:       trackedWindows=27 focused=33251
  render:        bordersOn=true desired=3
  mainThread:    calls=1842 slow=0 maxMs=4.32
```

`limelight perf --json` returns the same structure for scripting. The
`warnings` array surfaces stable diagnostic codes:

| Code | Meaning |
|---|---|
| `ax_denied` | Accessibility permission missing — focus falls back to title-only AX guesses. |
| `ax_undetermined` | TCC prompt unanswered. |
| `sls_streaming_off` | SLS event-stream symbols unavailable; window updates rely on AX/NSWorkspace. |
| `sls_resolver_off` | SLS front-window query unavailable; focus is AX-only. |
| `config_invalid` | Last parse produced diagnostics — see `limelight config validate`. |
| `borders_disabled` | Engine globally off (config or runtime override). |

## Uninstall

```bash
limelight daemon quit                # ask the daemon to exit cleanly
rm "$LIME_PREFIX/bin/limelight" "$LIME_PREFIX/bin/limelightd" "$LIME_PREFIX/bin/borders"
rm -rf "$HOME/Library/Application Support/LimeLight"
rm -f /tmp/limelight.sock            # safe — daemon already stopped
```

To revoke Accessibility permission: System Settings → Privacy & Security
→ Accessibility → remove `LimeLight`.

## Development

```bash
swift test                           # full suite (fast — runs in <2s)
swift build -c release
```

Issue tracking is via [beads](https://github.com/jeffrey-x/beads). Run
`bd ready` for the current work queue.

For agent-authored changes, see `AGENTS.md` for the session-completion
protocol.
