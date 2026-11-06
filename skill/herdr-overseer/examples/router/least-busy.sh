#!/usr/bin/env bash
# ROUTER_CMD example: pick the candidate lane with the fewest live workers (ties: first in the pool).
# The launcher sets: OVERSEER_CANDIDATES (eligible lanes, paused ones removed), OVERSEER_ROUTE_ROLE,
# OVERSEER_NAME, OVERSEER_TASK, OVERSEER_READ_ONLY, OVERSEER_STATE_DIR. Print one lane name.
# Use in config/overseer.env:  ROUTER_CMD="bash /abs/path/least-busy.sh"
set -euo pipefail
best="" best_n=999999
for lane in $OVERSEER_CANDIDATES; do
  n=$(hc ls --json --label "overseer.profile=$lane" | python3 -c 'import json,sys;print(len(json.load(sys.stdin)["terminals"]))')
  if [ "$n" -lt "$best_n" ]; then best="$lane"; best_n="$n"; fi
done
echo "$best"
