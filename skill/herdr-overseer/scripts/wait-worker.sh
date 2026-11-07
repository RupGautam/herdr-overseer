#!/usr/bin/env bash
# wait-worker.sh — wait for a worker's current turn to finish, for any agent.
#
#   wait-worker.sh NAME [--marker TEXT] [--after-turn N] [--timeout SECONDS]
#
# Use it right after launch-worker.sh or `hc send` instead of a bare `hc wait`: some agents report `idle`
# (or `done`) before their turn has even started, which makes `hc wait` return at once. This first waits for
# the turn to start (status `working`, a higher turn number, or the marker on screen), then for it to end
# (`done`/`idle`, or the marker). It never presses a key.
# A turn that ends before this script starts polling is only caught by --marker, or by --after-turn N (the
# worker's `turn` from `hc get` before you sent; 0 right after launch-worker.sh). Use one of them.
#
# Prints one line: `<outcome> <name> status=<s> turn=<n> [screen=<file>]` and exits with:
#   0 done      the turn ended (status done/idle after it started, or the marker printed)
#   0 done-no-marker  it ended but never printed --marker (after a 20 s grace); screen saved
#   2 blocked   a prompt is waiting (trust, login, permission): show the user; screen saved
#   3 limit     the account hit a usage/rate limit; pause the lane; screen saved
#   4 error     the agent's status is error; screen saved
#   5 gone      the worker no longer exists
#   6 timeout   no result within --timeout (default 900 s); screen saved
set -uo pipefail

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
NAME="" MARKER="" TIMEOUT=900 AFTER=""
POLL="${OVERSEER_WAIT_POLL:-2}"
while [ $# -gt 0 ]; do
  case "$1" in
    --marker) MARKER="$2"; shift 2 ;;
    --timeout) TIMEOUT="$2"; shift 2 ;;
    --after-turn) AFTER="$2"; shift 2 ;;
    -h|--help) sed -n 2,21p "$0"; exit 0 ;;
    -*) echo "wait-worker: unknown option $1" >&2; exit 64 ;;
    *) NAME="$1"; shift ;;
  esac
done
[ -n "$NAME" ] || { echo "usage: wait-worker.sh NAME [--marker TEXT] [--timeout SECONDS]" >&2; exit 64; }

TRUST_RE='trust (this|the) (folder|directory|project|contents)|Do you trust|log ?in to|sign in|please run /login|authenticate'
PERM_RE='Do you want to (proceed|allow|run|make this edit|create)|Allow (once|always)|Allow (creation|this|edit)|\(y/n\)'
LIMIT_RE='usage limit|rate.?limit|limit reached|hit your [^ ]* ?limit|quota exceeded|API Error: 429|out of credits'

state_of() { hc get "$NAME" 2>/dev/null | python3 -c 'import json,sys
d=json.load(sys.stdin); s=d.get("status") or {}
print((s.get("state") if isinstance(s,dict) else s) or "-", d.get("turn") or 0, d.get("state"))' 2>/dev/null || echo "gone 0 gone"; }
save() {
  local dir="$SKILL_DIR/state/screens"; mkdir -p "$dir"
  local f="$dir/$NAME-$1-$(date +%Y-%m-%dT%H-%M-%S).txt"
  hc read --lines 0 "$NAME" > "$f" 2>/dev/null; printf '%s' "$f"
}
report() {  # report OUTCOME CODE [save]
  local extra=""; [ "${3:-}" = save ] && extra=" screen=$(save "$1")"
  echo "$1 $NAME status=$st turn=$turn$extra"; exit "$2"
}

read -r st turn live <<< "$(state_of)"
[ "$live" = live ] || { st=gone; report gone 5; }
turn0=${AFTER:-$turn} started=0 t0=$SECONDS
while :; do
  read -r st turn live <<< "$(state_of)"
  [ "$live" = live ] || report gone 5
  scr=$(hc read --lines 0 "$NAME" 2>/dev/null)
  marked=0; [ -n "$MARKER" ] && printf '%s' "$scr" | grep -qF -- "$MARKER" && marked=1
  { [ "$st" = working ] || [ "$turn" -gt "$turn0" ] || [ "$marked" = 1 ]; } && started=1
  tail=$(printf '%s' "$scr" | tail -40)
  if [ "$marked" = 1 ]; then report done 0; fi
  if [ "$st" = error ]; then report error 4 save; fi
  if printf '%s' "$tail" | grep -qiE "$LIMIT_RE"; then report limit 3 save; fi
  if [ "$st" = blocked ] || printf '%s' "$tail" | grep -qiE "$TRUST_RE|$PERM_RE"; then report blocked 2 save; fi
  if [ "$started" = 1 ] && { [ "$st" = done ] || [ "$st" = idle ]; }; then
    [ -z "$MARKER" ] && report done 0
    # finished but the marker never came: allow a short grace for slow screens, then say so
    : "${ended_at:=$SECONDS}"; [ $((SECONDS - ended_at)) -ge "${OVERSEER_WAIT_GRACE:-20}" ] && report done-no-marker 0 save
  else unset ended_at; fi
  [ $((SECONDS - t0)) -ge "$TIMEOUT" ] && report timeout 6 save
  sleep "$POLL"
done
