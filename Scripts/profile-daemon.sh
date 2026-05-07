#!/usr/bin/env bash
# Periodically samples the limelightd process and writes a CSV row per tick:
#   epoch,rss_kb,cpu_pct,thread_count,window_count
#
# Usage:
#   Scripts/profile-daemon.sh [interval_seconds] [out_path]
#
# Defaults:
#   interval_seconds = 1
#   out_path         = /tmp/limelightd-profile-<epoch>.csv
#
# Stop with Ctrl-C; the file remains for analysis (e.g. `column -t -s, < file`,
# or load it into anything that reads CSV).
#
# For deeper profiling (stack samples, call trees) use Instruments instead:
#   xctrace record --template "Time Profiler" --attach limelightd --output trace.trace
#   open trace.trace

set -euo pipefail

INTERVAL="${1:-1}"
OUT="${2:-/tmp/limelightd-profile-$(date +%s).csv}"

LIMELIGHT_BIN="$(cd "$(dirname "$0")/.." && pwd)/.build/debug/limelight"

echo "epoch,rss_kb,cpu_pct,thread_count,window_count" > "$OUT"
echo "writing → $OUT (Ctrl-C to stop)"

while true; do
    pid=$(pgrep -x limelightd | head -1 || true)
    if [[ -z "$pid" ]]; then
        echo "$(date +%s),,,,daemon_not_running" >> "$OUT"
    else
        # ps gives RSS (kb), %CPU, thread count
        line=$(ps -o rss=,pcpu=,thcount= -p "$pid" 2>/dev/null | tr -s ' ' || true)
        rss=$(echo "$line" | awk '{print $1}')
        cpu=$(echo "$line" | awk '{print $2}')
        thr=$(echo "$line" | awk '{print $3}')

        # Cached window count via IPC (cheap; daemon does no rescan).
        wc=$("$LIMELIGHT_BIN" status 2>/dev/null | awk -F'[ :,]+' '/windowCount/ {print $3}' || echo "")

        echo "$(date +%s),$rss,$cpu,$thr,$wc" >> "$OUT"
    fi
    sleep "$INTERVAL"
done
