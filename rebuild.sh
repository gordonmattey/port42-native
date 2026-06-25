#!/bin/bash
# Convenience alias: build + relaunch. The kill-before-rebuild cleanup (app +
# gateway) now lives in build.sh, so this just delegates to `build.sh --run`.
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
exec "$DIR/build.sh" --run "$@"
