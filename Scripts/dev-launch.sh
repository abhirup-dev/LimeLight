#!/usr/bin/env bash
# Build, install to a stable dev path, optionally codesign, then launch LimeLight.
# Usage:
#   DEV_SIGN_IDENTITY="Apple Development: Your Name (...)" ./Scripts/dev-launch.sh
#   ./Scripts/dev-launch.sh --configuration debug --output ~/Applications/Dev/LimeLight.app
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="debug"
APP="${LIMELIGHT_DEV_APP_PATH:-$HOME/Applications/Dev/LimeLight.app}"
SIGN_IDENTITY="${DEV_SIGN_IDENTITY:-${LIMELIGHT_DEV_SIGN_IDENTITY:-}}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        -c|--configuration)
            CONFIG="${2:?missing value for $1}"
            shift 2
            ;;
        -o|--output)
            APP="${2:?missing value for $1}"
            shift 2
            ;;
        -s|--sign-identity)
            SIGN_IDENTITY="${2:?missing value for $1}"
            shift 2
            ;;
        -h|--help)
            sed -n '2,5p' "$0"
            exit 0
            ;;
        *)
            echo "dev-launch.sh: unknown argument '$1'" >&2
            exit 1
            ;;
    esac
done

swift build -c "$CONFIG"
"$ROOT/Scripts/bundle-app.sh" --configuration "$CONFIG" --output "$APP"

if [[ -n "$SIGN_IDENTITY" ]]; then
    codesign --force --deep --sign "$SIGN_IDENTITY" "$APP"
    codesign --verify --deep --strict "$APP"
    echo "Signed $APP with $SIGN_IDENTITY"
else
    echo "DEV_SIGN_IDENTITY not set; leaving $APP unsigned/ad-hoc." >&2
    echo "Set DEV_SIGN_IDENTITY to an Apple Development identity for stable TCC grants." >&2
fi

open "$APP"
