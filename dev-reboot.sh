#!/bin/bash
# dev-reboot.sh — rebuild Port42, kill the running instance, relaunch the fresh debug bundle.
#
# Designed to be kicked off DETACHED (see the launcher at the bottom of this file, or run:
#   nohup bash dev-reboot.sh >/dev/null 2>&1 & disown
# so it survives Port42 — and any `claude` companion running inside it — being killed mid-run.
# That's the whole point: a companion inside Port42 can call this to reboot itself without a
# human switching windows. The script reparents to launchd, finishes the build after its own
# host dies, and relaunches the app (which respawns the companion with fresh context).
set -u

REPO="/Users/gordon/Dropbox/Work/Hacking/workspace/portal-42/port42-native"
LOG="$REPO/.build/dev-reboot.log"
APP="$REPO/.build/Port42.app"

cd "$REPO" || exit 1

# Re-exec ourselves detached if not already (nohup + own session) so killing Port42
# (our potential parent) can't take the build down with it.
if [ "${DEV_REBOOT_DETACHED:-}" != "1" ]; then
  mkdir -p "$REPO/.build"
  DEV_REBOOT_DETACHED=1 nohup bash "$REPO/dev-reboot.sh" >>"$LOG" 2>&1 &
  disown
  echo "dev-reboot kicked off (detached). Tail: $LOG"
  exit 0
fi

# ---- detached body ----
{
  echo ""
  echo "=== dev-reboot $(date '+%Y-%m-%d %H:%M:%S') ==="

  # 1. Build + sign the debug bundle (no --run; we relaunch ourselves below).
  echo "--- build ---"
  ./build.sh
  build_rc=$?
  if [ $build_rc -ne 0 ]; then
    echo "!!! build failed (rc=$build_rc) — NOT killing/relaunching. Fix and rerun."
    exit $build_rc
  fi

  # 2. Let the companion that triggered this reboot finish its turn and flush its Claude Code
  #    transcript before we kill its host. Otherwise the SIGHUP (PTY teardown when Port42 dies)
  #    kills `claude` mid-turn and `claude --continue` resumes from a pre-reboot checkpoint —
  #    the chat "jumps back in time". The window must NOT depend on build speed: a fast cached
  #    build would otherwise reach the kill within ~2s, too soon to flush. Tunable via env.
  echo "--- settle ${DEV_REBOOT_SETTLE:-8}s (let companion flush transcript) ---"
  sleep "${DEV_REBOOT_SETTLE:-8}"

  # 3. Kill every running Port42 + bundled gateway, whatever bundle path (installed or debug).
  echo "--- kill running Port42 ---"
  pkill -f 'Port42\.app/Contents/MacOS/Port42'        2>/dev/null
  pkill -f 'Port42\.app/Contents/MacOS/port42-gateway' 2>/dev/null
  sleep 1
  # Clear a stale gateway still holding :4242, if any.
  lsof -ti tcp:4242 2>/dev/null | xargs -r kill -9 2>/dev/null
  sleep 1

  # 3. Relaunch the freshly built debug bundle.
  echo "--- relaunch $APP ---"
  open "$APP"

  # 4. Wait for the gateway to answer, so the log records a clean comeback.
  for i in $(seq 1 20); do
    if curl -s --max-time 1 http://127.0.0.1:4242/call -d '{"method":"help"}' >/dev/null 2>&1; then
      echo "=== back up after ${i}s ($(date '+%H:%M:%S')) ==="
      exit 0
    fi
    sleep 1
  done
  echo "!!! gateway did not answer within 20s — check the app manually."
} >>"$LOG" 2>&1
