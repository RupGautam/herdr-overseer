#!/usr/bin/env bash
# start-guard.sh — make sure the handoff guard is running as hc terminal "handoff-guard". Safe to call often:
# the SessionStart hook calls it for every coordinator session. Does nothing if the guard is already live.
set -euo pipefail
SCRIPTS="$(cd "$(dirname "$0")" && pwd)"
command -v hc >/dev/null || exit 0
state=$(hc get handoff-guard 2>/dev/null | python3 -c 'import json,sys;print(json.load(sys.stdin).get("state",""))' 2>/dev/null || true)
[ "$state" = "live" ] && exit 0
hc rm handoff-guard >/dev/null 2>&1 || true   # clear a finished one so the name is free
hc run --bg --json --name handoff-guard --cwd "$HOME" --no-parent \
  --label overseer.role=guard -- python3 "$SCRIPTS/handoff-guard.py" "$@" >/dev/null
echo "handoff-guard started"
