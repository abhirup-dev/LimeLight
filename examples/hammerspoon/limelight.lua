-- limelight.lua — Hammerspoon helper for the LimeLight daemon.
--
-- All helpers shell out to the `limelight` CLI, which speaks IPC to a
-- single running daemon (LimeLight.app). Calls are short-lived and
-- non-interactive so they're safe to bind to repeated hotkeys.
--
-- Install:
--   1. Build LimeLight (Package.swift) and copy `limelight` onto $PATH,
--      OR set `M.cli` below to its absolute path.
--   2. In ~/.hammerspoon/init.lua:
--        local L = require("limelight")
--        hs.hotkey.bind({"ctrl","alt"}, "B", function() L.bordersToggle() end)
--        hs.hotkey.bind({"ctrl","alt"}, "R", function() L.reload() end)
--
-- Notes:
--   - Hammerspoon hotkeys must return quickly; every call here uses
--     hs.execute (synchronous, but the CLI itself returns in <50ms once
--     the daemon is running). Long-running operations are not exposed.
--   - hs.execute with `with_user_env=false` skips loading the user's
--     login shell, shaving ~50–150ms per call. We rely on absolute path
--     resolution via M.cli instead.

local M = {}

-- Resolve `limelight` once. Override by setting `M.cli` before calling
-- helpers, e.g. `require("limelight").cli = "/opt/limelight/bin/limelight"`.
M.cli = "limelight"

-- Run the CLI with the given args and return (stdout, ok, rc). Never
-- raises — failures are logged to the Hammerspoon console and surfaced
-- via the boolean. `with_user_env=false` because we resolve absolute
-- paths ourselves; loading the login shell on every hotkey would stall.
local function run(args)
    local cmd = M.cli
    for _, a in ipairs(args) do
        cmd = cmd .. " " .. a
    end
    local out, ok, _, rc = hs.execute(cmd, false)
    if not ok then
        hs.printf("[limelight] %s failed rc=%s out=%s", cmd, tostring(rc), tostring(out))
    end
    return out or "", ok == true, rc
end

-- Daemon liveness check. Returns true iff `limelight status` exits 0.
function M.isRunning()
    local _, ok = run({ "status" })
    return ok
end

-- Re-read config from disk and apply if valid.
function M.reload()
    return run({ "reload" })
end

-- Validate config without publishing. Returns the diagnostic JSON string.
function M.configValidate()
    local out, ok = run({ "config", "validate" })
    return out, ok
end

-- Border runtime controls. Each returns (stdout, ok).
function M.bordersEnable()  return run({ "borders", "enable" })  end
function M.bordersDisable() return run({ "borders", "disable" }) end
function M.bordersRedraw()  return run({ "borders", "redraw" })  end
function M.bordersReset()   return run({ "borders", "reset" })   end

-- Toggle: query `borders desired` count and flip. Cheap because the CLI
-- short-circuits to the cached daemon snapshot — no enumeration tick.
function M.bordersToggle()
    local out, ok = run({ "borders", "desired" })
    if not ok then return out, ok end
    -- "desired count=0" means borders are off (or no targets); enable.
    if out:find("count=0") then
        return M.bordersEnable()
    end
    return M.bordersDisable()
end

-- Return the focused window as a Lua table, or nil if nothing focused
-- or the daemon is unreachable. Schema mirrors `current-window --json`:
--   { windowID = number, ownerPID = number, appName = string|nil, title = string|nil }
function M.currentWindow()
    local out, ok = run({ "current-window", "--json" })
    if not ok then return nil end
    local trimmed = (out or ""):gsub("^%s*(.-)%s*$", "%1")
    if trimmed == "" or trimmed == "null" then return nil end
    local decoded = hs.json.decode(trimmed)
    if type(decoded) ~= "table" then return nil end
    return decoded
end

-- Launch the daemon if not already running. Wraps `daemon open` which
-- is itself a guarded `open -b dev.abhirup.LimeLight`, so calling this
-- repeatedly is safe.
function M.daemonOpen()
    return run({ "daemon", "open" })
end

-- Ask the daemon to terminate. Use sparingly — most workflows only need
-- `reload`. Returns once the IPC reply is received; the actual exit is
-- async on the daemon side.
function M.daemonQuit()
    return run({ "daemon", "quit" })
end

-- Forward arbitrary args. Useful for one-off subcommands the helper
-- doesn't wrap yet — e.g. trigger/popup once those CLI verbs land
-- (focusfx-18.x / focusfx-22.x). Always returns (stdout, ok, rc).
function M.cliRaw(args)
    return run(args)
end

return M
