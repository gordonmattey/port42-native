#!/bin/bash
# Kill Port42 and rebuild+relaunch
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"

echo "[rebuild] Killing Port42..."
pkill -x Port42 2>/dev/null || true

# Wait for it to actually die
for i in {1..10}; do
    pgrep -x Port42 >/dev/null 2>&1 || break
    sleep 0.5
done

# Force kill if still alive
pkill -9 -x Port42 2>/dev/null || true
sleep 0.5

echo "[rebuild] Building and launching..."
exec "$DIR/build.sh" --run
