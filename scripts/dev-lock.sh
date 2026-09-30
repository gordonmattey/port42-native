#!/bin/bash
# Hold a dev instance so nobody else's build relaunches it under you (docs/dev-instances.md).
#
#   scripts/dev-lock.sh dev5 gordon "testing the rail"   # take it
#   scripts/dev-lock.sh dev5 --release                   # give it back
#   scripts/dev-lock.sh                                   # who holds what
#
# build.sh refuses to build a locked instance unless PORT42_DEV_OWNER names the holder.
set -u
DIR="$HOME/.port42/dev-locks"
mkdir -p "$DIR"
if [ $# -eq 0 ]; then
    shopt -s nullglob
    locks=("$DIR"/*)
    [ ${#locks[@]} -eq 0 ] && { echo "no dev instance is locked"; exit 0; }
    for f in "${locks[@]}"; do echo "$(basename "$f"): $(head -1 "$f") ($(sed -n 2p "$f"), since $(sed -n 3p "$f"))"; done
    exit 0
fi
inst=$(echo "$1" | tr '[:upper:]' '[:lower:]')
case "$inst" in dev|dev[2-9]) ;; *) echo "not a dev instance: $1 (dev, dev2 to dev9)"; exit 2 ;; esac
if [ "${2:-}" = "--release" ]; then
    rm -f "$DIR/$inst" && echo "$inst released"
    exit 0
fi
[ -n "${2:-}" ] || { echo "who holds it? scripts/dev-lock.sh $inst <owner> \"why\""; exit 2; }
if [ -f "$DIR/$inst" ] && [ "$(head -1 "$DIR/$inst")" != "$2" ]; then
    echo "$inst is held by $(head -1 "$DIR/$inst"): $(sed -n 2p "$DIR/$inst")"; exit 1
fi
printf '%s\n%s\n%s\n' "$2" "${3:-}" "$(date '+%Y-%m-%d %H:%M')" > "$DIR/$inst"
echo "$inst held by $2"
