#!/usr/bin/env bash
# ROUTER_CMD example: route by words in the task text, falling back to the first candidate.
# Edit the patterns and lane names. The launcher sets OVERSEER_CANDIDATES, OVERSEER_ROUTE_ROLE,
# OVERSEER_NAME, OVERSEER_TASK, OVERSEER_READ_ONLY, OVERSEER_STATE_DIR. Print one lane name; it must be
# one of OVERSEER_CANDIDATES.
set -euo pipefail
pick() { for c in $OVERSEER_CANDIDATES; do if [ "$c" = "$1" ]; then echo "$1"; exit 0; fi; done; return 0; }
task=$(printf '%s' "$OVERSEER_TASK" | tr '[:upper:]' '[:lower:]')
case "$task" in
  *ui*|*css*|*design*|*screen*) pick FRONTEND_LANE ;;
  *migration*|*schema*|*sql*)   pick BACKEND_LANE ;;
esac
set -- $OVERSEER_CANDIDATES; echo "$1"
