#!/usr/bin/env bash
# Build, install to a stable dev path, optionally codesign, then launch LimeLight.
# Usage:
#   DEV_SIGN_IDENTITY="Apple Development: Your Name (...)" ./Scripts/dev-launch.sh
#   ./Scripts/dev-launch.sh --configuration debug --output ~/Applications/Dev/LimeLight.app
#   ./Scripts/dev-launch.sh --no-sign
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="debug"
APP="${LIMELIGHT_DEV_APP_PATH:-$HOME/Applications/Dev/LimeLight.app}"
SIGN_IDENTITY="${DEV_SIGN_IDENTITY:-${LIMELIGHT_DEV_SIGN_IDENTITY:-}}"
SIGN_APP=1

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
        --no-sign)
            SIGN_APP=0
            shift
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

if [[ "$SIGN_APP" == "1" && -z "$SIGN_IDENTITY" ]]; then
    SIGN_IDENTITY="$(
        security find-identity -p codesigning -v 2>/dev/null |
            sed -n 's/.*"\(Apple Development:.*\)"/\1/p' |
            head -1
    )"
fi

if [[ "$SIGN_APP" == "1" && -n "$SIGN_IDENTITY" ]]; then
    codesign --force --deep --sign "$SIGN_IDENTITY" "$APP"
    codesign --verify --deep --strict "$APP"
    echo "Signed $APP with $SIGN_IDENTITY"
elif [[ "$SIGN_APP" == "0" ]]; then
    echo "Skipping codesign for $APP."
else
    echo "No valid Apple Development identity found; leaving $APP unsigned/ad-hoc." >&2
    echo "Set DEV_SIGN_IDENTITY or run with --no-sign to make this explicit." >&2
fi

open "$APP"
