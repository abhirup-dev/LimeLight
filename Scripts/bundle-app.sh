#!/usr/bin/env bash
# Bundle the limelightd executable into LimeLight.app.
# Usage: ./Scripts/bundle-app.sh [debug|release]
#        ./Scripts/bundle-app.sh --configuration debug --output ~/Applications/Dev/LimeLight.app
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="debug"
APP="$ROOT/.build/LimeLight.app"

while [[ $# -gt 0 ]]; do
    case "$1" in
        debug|release)
            CONFIG="$1"
            shift
            ;;
        -c|--configuration)
            CONFIG="${2:?missing value for $1}"
            shift 2
            ;;
        -o|--output)
            APP="${2:?missing value for $1}"
            shift 2
            ;;
        -h|--help)
            sed -n '2,3p' "$0"
            exit 0
            ;;
        *)
            echo "bundle-app.sh: unknown argument '$1'" >&2
            exit 1
            ;;
    esac
done

BIN_DIR="$(cd "$ROOT" && swift build --show-bin-path -c "$CONFIG")"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN_DIR/limelightd" "$APP/Contents/MacOS/limelightd"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"

echo "Bundled $APP"
