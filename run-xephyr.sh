#!/usr/bin/env bash
# Launch tile inside Xephyr in fullscreen for testing.
# Usage: ./run-xephyr.sh [display_num]    (default :9)

set -e

DPY="${1:-:9}"
HERE="$(cd "$(dirname "$0")" && pwd)"
TILE="$HERE/tile"

if [ ! -x "$TILE" ]; then
    echo "tile not built — run 'make' in $HERE first" >&2
    exit 1
fi

# Pick the host's screen size so fullscreen actually fills it. Falls
# back to 1920x1200 if xrandr isn't available.
SIZE=$(xrandr 2>/dev/null | awk '/\*/ {print $1; exit}')
SIZE="${SIZE:-1920x1200}"

# Refuse to clobber an existing Xephyr on the same display.
if [ -e "/tmp/.X${DPY#:}-lock" ]; then
    echo "Display $DPY already in use (lockfile /tmp/.X${DPY#:}-lock exists)." >&2
    echo "Pick another display or kill the existing server." >&2
    exit 1
fi

# Start Xephyr fullscreen with Xinerama so tile sees a single output.
# -resizeable lets the nested screen track host resolution changes.
Xephyr -fullscreen -resizeable +xinerama -screen "$SIZE" "$DPY" >/tmp/xephyr-${DPY#:}.log 2>&1 &
XEPHYR_PID=$!

# Wait until Xephyr's socket is listening (max ~5s).
for _ in $(seq 1 50); do
    [ -S "/tmp/.X11-unix/X${DPY#:}" ] && break
    sleep 0.1
done

if ! kill -0 "$XEPHYR_PID" 2>/dev/null; then
    echo "Xephyr failed to start. See /tmp/xephyr-${DPY#:}.log" >&2
    exit 1
fi

# Make sure we tear Xephyr down even if tile crashes / exits cleanly.
trap 'kill "$XEPHYR_PID" 2>/dev/null || true; wait "$XEPHYR_PID" 2>/dev/null || true' EXIT

DISPLAY="$DPY" "$TILE"
