# LimeLight

> Focus borders for macOS 14+. JankyBorders-compatible, AeroSpace-friendly,
> Hammerspoon-scriptable.

LimeLight draws a coloured border around your focused window so you always
know where your typing is going. Per-app rules (gradients, glows,
different widths) live in a small JSONC config. It runs as a single
background daemon talking to a `limelight` CLI over a per-user Unix
socket.

If you're coming from [JankyBorders](https://github.com/FelixKratz/JankyBorders),
LimeLight understands the same `active_color=… width=…` arguments — most
setups can switch with a one-line change. See **Migrating from
JankyBorders** below.

## Requirements

- macOS 14 (Sonoma) or newer.
- Accessibility permission for the daemon (granted via System Settings —
  the daemon prompts on first launch).
- A Swift 5.10+ toolchain to build (Xcode 15+ ships one; or `xcode-select --install`).

## Install

There's no Homebrew tap yet. Build and install three small binaries:

```bash
git clone https://github.com/<your-fork>/LimeLight.git
cd LimeLight
swift build -c release

# Install the binaries somewhere on PATH. ~/.local/bin is a good default;
# add it to your shell init if it isn't already:
#   echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc
install -d ~/.local/bin
install .build/release/limelight   ~/.local/bin/
install .build/release/limelightd  ~/.local/bin/
install .build/release/borders     ~/.local/bin/limelight-borders
```

> **Why rename `borders` → `limelight-borders`?** If you have JankyBorders
> installed via Homebrew, both binaries answer to `borders` and `$PATH`
> order decides which one wins. Renaming the LimeLight shim avoids the
> ambiguity. If you don't have JankyBorders installed, you can skip the
> rename and ship it as plain `borders`.

Start the daemon:

```bash
limelightd &
```

The first launch opens the macOS Accessibility prompt — grant access in
System Settings → Privacy & Security → Accessibility, then re-run
`limelightd`. After that you should see borders around your focused
windows. Verify:

```bash
limelight perf
```

You're looking for:
- `accessibility: granted`
- `skylight: streaming=yes frontWindowResolution=yes` (private SLS APIs
  resolved — you get JankyBorders-equivalent focus tracking)
- `render: bordersOn=1 desired=N` (some N > 0)

## Configure

Default config path:

```
~/.config/limelight/config.jsonc
```

Override with `$LIME_CONFIG` if you want it elsewhere. JSONC means JSON
plus comments and trailing commas. Minimal example:

```jsonc
{
  "borders": {
    "enabled": true,
    "style": "round",        // round | square | uniform
    "width": 5.0,
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
    },
    {
      "name": "Slack gradient",
      "match": { "appName": "Slack" },
      "borders": {
        "active": { "color": "gradient(top_left=0xff00ddff, bottom_right=0xffff00aa)" }
      }
    }
  ],

  "exclude": [
    { "appName": "System Settings" },
    { "windowTitleRegex": "^Picture in Picture$" }
  ]
}
```

Colour formats accepted in `"color"`:

| Form | Looks like |
|---|---|
| `0xAARRGGBB` | flat solid colour with alpha |
| `glow(0xAARRGGBB)` | solid stroke + outer halo |
| `gradient(top_left=…, bottom_right=…)` | two-stop linear gradient |
| `gradient(top_right=…, bottom_left=…)` | other diagonal |

Match clauses (any combination is AND-ed):

- `appName` — exact app name (e.g. `"Slack"`).
- `bundleIdentifier` — e.g. `"com.tinyspeck.slackmacgap"`.
- `windowTitle` — exact title string.
- `windowTitleRegex` — regex against the title.
- `windowID` — pin to a specific CGWindowID (rare).
- `aerospaceWorkspace` — workspace name (requires the AeroSpace hook below).

After editing the file:

```bash
limelight reload                # apply
limelight config validate       # check syntax without applying
```

## AeroSpace

Edit `~/.config/aerospace/aerospace.toml`. If you currently have a
`borders …` startup command, replace it with `limelightd`:

```toml
# after-startup-command = [
#     'exec-and-forget borders style=round active_color=0xffff0000 ...'
# ]
after-startup-command = [
    'exec-and-forget /Users/YOU/.local/bin/limelightd'
]
```

Use the absolute path so AeroSpace doesn't depend on your shell's PATH.
Border style and colours come from `~/.config/limelight/config.jsonc`,
not from this line — keep all visual tuning in the JSONC config.

Optional — fire a focus effect when you change workspaces:

```toml
exec-on-workspace-change = ['/bin/bash', '-c',
    'exec-and-forget /Users/YOU/.local/bin/limelight trigger --aerospace-workspace=$AEROSPACE_FOCUSED_WORKSPACE']
```

You can then match rules against the workspace:

```jsonc
"rules": [
  {
    "name": "Workspace 1 cyan",
    "match": { "aerospaceWorkspace": "1" },
    "borders": { "active": { "color": "glow(0xff00d1ff)" } }
  }
]
```

Reload AeroSpace (`aerospace reload-config` or quit/relaunch) to pick
up the changes.

## Hammerspoon

Drop `examples/hammerspoon/limelight.lua` next to your `~/.hammerspoon/init.lua`.
In `init.lua`:

```lua
local L = require("limelight")
hs.hotkey.bind({"ctrl", "alt"}, "B", function() L.bordersToggle() end)
hs.hotkey.bind({"ctrl", "alt"}, "R", function() L.reload() end)
hs.hotkey.bind({"ctrl", "alt"}, "I", function()
    local w = L.currentWindow()
    if w then hs.alert.show(w.appName .. " — " .. (w.title or "")) end
end)
```

Each helper is a single short-lived shell-out, so it's safe to bind to
hotkeys you mash repeatedly.

## CLI reference

```
limelight status [--json]             Cached health snapshot.
limelight perf   [--json]             Diagnostics dump (AX, SkyLight, render, perf).
limelight reload                      Re-read config.jsonc.
limelight config validate             Validate without applying.
limelight config path                 Print active config path.
limelight windows [--json]            Cached window list.
limelight current-window [--json]     Focused window.
limelight borders enable              Borders on (runtime override).
limelight borders disable             Borders off.
limelight borders redraw-all          Force-recreate every overlay.
limelight borders reset               Drop runtime overrides.
limelight borders desired             Diagnostic: dump engine state.
limelight trigger [--effect=cometRing]  Transient effect on focused window.
limelight popup --title=T --message=M   Transient banner.
limelight daemon quit                 Ask daemon to terminate.
```

The `limelight-borders` shim accepts upstream JankyBorders args and
forwards them to the daemon:

```bash
limelight-borders active_color=0xffe1e3e4 inactive_color=0xff494d64 width=5.0 style=round
```

`order=above|below`, `hidpi=on|off`, `ax_focus=on|off` (escape hatch when
SLS focus misbehaves), `blacklist=App,App`, `whitelist=App,App` are all
honoured at runtime.

## Migrating from JankyBorders

LimeLight's `limelight-borders` shim speaks the same wire format as
`brew install borders`. To switch:

1. Make sure the LimeLight daemon is running (`limelightd &`).
2. Comment out your existing `borders …` startup command in
   `~/.config/aerospace/aerospace.toml` (or wherever you launch it from).
3. Replace it with `'exec-and-forget /Users/YOU/.local/bin/limelightd'`.
4. (Optional) `brew uninstall borders` once you're happy with LimeLight.

**Don't run both at the same time** — they bind the same overlay layer
level and you'll get duplicated strokes.

## Diagnostics

`limelight perf` is the first stop when something looks off:

```
LimeLight 0.0.1  pid=36085  uptime=12m9s
  socket:        /Users/me/Library/Application Support/LimeLight/limelight.sock
  accessibility: granted
  skylight:      streaming=yes frontWindowResolution=yes
  config:        /Users/me/.config/limelight/config.jsonc
                 rules=2 diagnostics=0 bordersEnabled=1
  tracker:       trackedWindows=21 focused=33251
  render:        bordersOn=1 desired=2
  mainThread:    calls=37 slow=3 maxMs=66.22
```

`limelight perf --json` returns the same structure for scripting. The
JSON form also includes a `warnings` array with stable codes:

| Code | Meaning | Fix |
|---|---|---|
| `ax_denied` | Accessibility permission missing | Grant in System Settings → Privacy & Security → Accessibility, then restart `limelightd` |
| `ax_undetermined` | TCC prompt unanswered | Same as above |
| `sls_streaming_off` | SLS event-stream symbols unavailable | macOS may have moved the private symbols — file an issue |
| `sls_resolver_off` | SLS front-window query unavailable | Same — focus falls back to AX-only |
| `config_invalid` | Config has parse errors | Run `limelight config validate` to see them |
| `borders_disabled` | Engine globally off | `limelight borders enable`, or set `borders.enabled: true` in config |

## Limitations to know about

- **Screenshots don't capture borders.** Overlay windows mark themselves
  as `sharingType = .none` so they're invisible to the same window
  enumeration we use to find target windows — otherwise we'd border our
  own borders. There's no opt-out.
- **Borders live on the active Space.** When you switch Spaces the
  border re-emerges on the next focused window. They don't ghost onto
  every Space.
- **Effects (`limelight trigger`):** only `cometRing` is fully
  implemented today. `neon`, `shockwave`, and `line` parse but return
  `effect_not_implemented` until their renderers land.
- **Idle-return popups** are not yet wired (popup CLI works, the idle
  detector is a follow-up).
- **Background fill** behind the active window (the JankyBorders
  `background_color` feature) is parsed but inert — needs a private API
  we haven't wired yet.
- **No auto-update.** No Sparkle, no plugin runtime in v1. Pull and
  rebuild for new versions.

## Uninstall

```bash
limelight daemon quit
rm ~/.local/bin/limelight ~/.local/bin/limelightd ~/.local/bin/limelight-borders
rm -rf ~/.config/limelight
rm -f "$HOME/Library/Application Support/LimeLight/limelight.sock"
```

Then revoke Accessibility: System Settings → Privacy & Security →
Accessibility → remove `limelightd`.
