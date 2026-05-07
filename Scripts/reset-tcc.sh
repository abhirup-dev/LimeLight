#!/usr/bin/env bash
# Reset macOS TCC accessibility permission for LimeLight so the next launch
# re-prompts cleanly. Useful during development since each `swift build`
# changes the binary's cdhash for ad-hoc / unsigned builds.
#
# Usage: ./Scripts/reset-tcc.sh
set -euo pipefail

BUNDLE_ID="dev.abhirup.lime"

echo "Resetting Accessibility permission for $BUNDLE_ID …"
tccutil reset Accessibility "$BUNDLE_ID"

# Also kill any running daemon so the next launch is fresh.
pkill -TERM -f LimeLight.app/Contents/MacOS/limelightd 2>/dev/null || true

echo "Done. Launch the daemon again to re-prompt."
