#!/bin/bash
# The build gate's tests (build.sh runs this before anything is compiled, signed or launched).
#
# Two passes, both must pass:
#   1. the full suite: `swift test`
#   2. the timing pass: tests that measure wall-clock behavior and cannot hold up while hundreds of
#      other tests compete for the CPU. They skip themselves in the full suite unless
#      PORT42_TIMING_TESTS=1, and run here alone. Without this pass they never run (#244: an
#      off-screen port's timers).
#
# A new timing suite gates itself on PORT42_TIMING_TESTS and joins TIMING_FILTER below.
#
# Usage: scripts/test-gate.sh   (from anywhere; runs in the repo root). Exit 1 on any failure.
set -u
cd "$(dirname "$0")/.."

TIMING_FILTER="OffscreenTimerTests|HiddenTimerTests|MessageDeliveryTests"

# run <label> <swift test args...>: one pass, its summary line on success, its failures otherwise.
run() {
    local label="$1"; shift
    local log
    log=$(mktemp -t port42-tests)
    if "$@" > "$log" 2>&1; then
        echo "[build] $label: $(grep -E "Test run with" "$log" | tail -1)"
        rm -f "$log"
    else
        echo "[build] TESTS FAILED ($label) — build aborted (nothing built, signed or launched)."
        grep -E "✘ Test |✘ Suite |error:" "$log" | head -20
        echo "[build] Full log: $log"
        exit 1
    fi
}

echo "[build] Tests..."
run "suite" swift test
echo "[build] Timing tests..."
run "timing" env PORT42_TIMING_TESTS=1 swift test --filter "$TIMING_FILTER"
