# LimeLight integration examples

Drop-in snippets for the two automation surfaces LimeLight expects to live
alongside: Hammerspoon (hotkeys + intermittent automation) and AeroSpace
(tiling WM with workspace hooks).

## hammerspoon/

- **limelight.lua** — module wrapping the `limelight` CLI. Each helper is
  a single short-lived shell-out, safe to bind to repeated hotkeys.
- **init-snippet.lua** — example bindings for `~/.hammerspoon/init.lua`.

Drop both files into `~/.hammerspoon/` (the module path is `require("limelight")`)
and reload the Hammerspoon config.

## aerospace/

- **aerospace.toml** — `after-startup-command`, JankyBorders-compatible
  startup path, and `exec-on-workspace-change` hook snippets. Merge with
  your existing `~/.aerospace.toml`.

### Replacing an existing JankyBorders setup

LimeLight ships a `borders` shim that is wire-compatible with the upstream
JankyBorders CLI: arguments like `active_color=0xff... width=5.0 style=round`
forward over IPC to the LimeLight daemon. Migration is a path swap, not a
config rewrite:

1. Install LimeLight; ensure its `bin/` is ahead of any prior JankyBorders
   install on `$PATH` (verify with `which borders`).
2. Leave your existing `after-startup-command = ['exec-and-forget borders …']`
   in place. It now drives LimeLight.
3. Optionally migrate to native: replace the `borders` invocation with
   `limelight daemon open` + a JSONC config under
   `~/Library/Application Support/LimeLight/config.jsonc`. The native path
   gives you the rule engine (per-app overrides, regex matching,
   `aerospaceWorkspace` context).

Do **not** run the upstream `borders` and the LimeLight shim at the same
time — both bind the same overlay layer level and you'll get duplicated
strokes.

## Verification checklist (focusfx-26.3)

Manual smoke test before shipping a release:

- [ ] `limelight daemon open` is idempotent (re-run from AeroSpace reload).
- [ ] `bordersToggle` Hammerspoon hotkey pressed 10×/sec does not stall HS.
- [ ] `reload` Hammerspoon hotkey returns within 100ms with daemon running.
- [ ] AeroSpace `exec-on-workspace-change` does not block workspace swap
      under load (`exec-and-forget` is required).
- [ ] `borders` shim from LimeLight is reachable on PATH; `which borders`
      resolves to LimeLight's bin, not Homebrew's JankyBorders.
- [ ] `currentWindow()` returns `nil` (not an error) when no window is
      focused (Mission Control, locked screen).

### Known caveats

- `limelight trigger` and `limelight popup` CLI verbs are part of
  focusfx-18.x / focusfx-22.x and not yet wired. The `aerospace.toml`
  workspace-change hook is forward-compatible — it'll exit non-zero
  today and start working once those land. `exec-and-forget` swallows
  the error so AeroSpace itself is unaffected.
- Hammerspoon's `hs.execute` with `with_user_env=true` adds ~50–150ms
  per call by loading the user shell. `limelight.lua` deliberately
  passes `false` and resolves `M.cli` itself.
