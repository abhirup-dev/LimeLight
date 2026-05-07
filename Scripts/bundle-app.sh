#!/usr/bin/env bash
# Bundle the FocusFXDaemon executable into FocusFX.app.
# Usage: ./Scripts/bundle-app.sh [debug|release]
set -euo pipefail

CONFIG="${1:-debug}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN_DIR="$ROOT/.build/$(swift build --show-bin-path -c "$CONFIG")"
# `swift build --show-bin-path` already prints the absolute path; recompute.
BIN_DIR="$(cd "$ROOT" && swift build --show-bin-path -c "$CONFIG")"

APP="$ROOT/.build/FocusFX.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN_DIR/FocusFXDaemon" "$APP/Contents/MacOS/FocusFXDaemon"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"

echo "Bundled $APP"
