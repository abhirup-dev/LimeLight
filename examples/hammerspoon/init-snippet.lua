-- Drop into ~/.hammerspoon/init.lua (or `dofile` it from there).
-- Assumes limelight.lua sits next to your init.lua.

local L = require("limelight")

-- Make sure the daemon is up when Hammerspoon loads.
L.daemonOpen()

-- Hotkeys (all idempotent under repeated presses):
hs.hotkey.bind({ "ctrl", "alt" }, "B", function() L.bordersToggle() end)
hs.hotkey.bind({ "ctrl", "alt" }, "R", function() L.reload() end)
hs.hotkey.bind({ "ctrl", "alt" }, "I", function()
    local w = L.currentWindow()
    if w then
        hs.alert.show(string.format("%s — %s", w.appName or "?", w.title or ""))
    else
        hs.alert.show("no focused window")
    end
end)
