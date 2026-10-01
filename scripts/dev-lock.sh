#!/bin/bash
# Hold a dev instance so nobody else's build relaunches it under you (docs/dev-instances.md).
#
#   scripts/dev-lock.sh dev5 gordon "testing the rail"   # take it
#   scripts/dev-lock.sh dev5 --release                   # give it back
#   scripts/dev-lock.sh                                   # who holds what
#
# build.sh refuses to build a locked instance unless PORT42_DEV_OWNER names the holder.
#
# Taking a lock also enrols a client named after the holder on that instance (#222): the instance
# writes its token to ~/.port42/port42<inst>/tokens/<name>, so every call made while testing is
# attributed to its holder, and nobody mints a token by hand or borrows another tool's. The instance
# does it the next time it runs, or at once if it is running. --release revokes that client.
#
# A lock is refused while the instance's gateway port is held by an app from another build folder (or
# by anything else): two apps would fight over one gateway. Stop it, or ask whoever built it.
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
case "$inst" in dev|dev[2-9]|dev11) ;; *) echo "not a dev instance: $1 (dev, dev2 to dev9, dev11)"; exit 2 ;; esac

# The instance's app and data names, as build.sh gives them: dev8 -> Port42Dev8, data port42dev8.
app="Port42$(echo "${inst:0:1}" | tr '[:lower:]' '[:upper:]')${inst:1}"
data="$HOME/.port42/$(echo "$app" | tr '[:upper:]' '[:lower:]')"
enrol="$data/enrol"

# The client id the instance gives a name (ClientRegistry.slug): lowercase, runs of anything but a
# letter or digit become one dash, no dash at either end.
slug() { echo "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//'; }

request() {   # request <file name>: a private file the instance acts on and then deletes
    mkdir -p "$enrol" && chmod 700 "$enrol"
    ( umask 077; : > "$enrol/$1" )
}

if [ "${2:-}" = "--release" ]; then
    if [ -f "$DIR/$inst" ]; then
        holder=$(head -1 "$DIR/$inst")
        [ -n "$holder" ] && request "$holder.revoke" && echo "$holder's client on $inst will be revoked"
    fi
    rm -f "$DIR/$inst" && echo "$inst released"
    exit 0
fi
[ -n "${2:-}" ] || { echo "who holds it? scripts/dev-lock.sh $inst <owner> \"why\""; exit 2; }
if [ -f "$DIR/$inst" ] && [ "$(head -1 "$DIR/$inst")" != "$2" ]; then
    echo "$inst is held by $(head -1 "$DIR/$inst"): $(sed -n 2p "$DIR/$inst")"; exit 1
fi

# Another build's app on this instance? Whatever listens on the instance's gateway port is its app (its
# port42-gateway); if that is not in this checkout's build folder, two apps would fight over one
# gateway. This checkout's build folder, resolved through its symlink, unless a test names one.
case "$inst" in dev) port=4243 ;; dev2) port=4244 ;; dev3) port=4245 ;; dev4) port=4246 ;; dev5) port=4247 ;;
    dev6) port=4248 ;; dev7) port=4249 ;; dev8) port=4250 ;; dev9) port=4251 ;; dev11) port=4253 ;; esac
port="${PORT42_DEVLOCK_PORT:-$port}"
root="$(cd "$(dirname "$0")/.." && pwd)"
own="${PORT42_DEVLOCK_BUILD_DIR:-$root/.build}"
own=$(cd "$own" 2>/dev/null && pwd -P || true)
for pid in $(lsof -nP -t -iTCP:"$port" -sTCP:LISTEN 2>/dev/null); do
    exe=$(lsof -nP -p "$pid" -a -d txt -Fn 2>/dev/null | sed -n 's/^n//p' | head -1)
    [ -n "$exe" ] || continue
    case "$exe" in
        */"$app".app/*) folder="${exe%%/$app.app/*}" ;;   # a built app: its build folder
        *) folder="$(dirname "$exe")" ;;                   # anything else on the port
    esac
    real=$(cd "$folder" 2>/dev/null && pwd -P || echo "$folder")
    if [ -z "$own" ] || [ "$real" != "$own" ]; then
        echo "$inst's gateway port $port is held by $exe (pid $pid), not this checkout's build."
        echo "Stop it, or ask whoever built it, before taking $inst; two apps would fight over one gateway."
        exit 1
    fi
done

printf '%s\n%s\n%s\n' "$2" "${3:-}" "$(date '+%Y-%m-%d %H:%M')" > "$DIR/$inst"
request "$2"
echo "$inst held by $2"
echo "your token on $inst: $data/tokens/$(slug "$2") (written when $app runs)"
