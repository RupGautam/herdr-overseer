#!/usr/bin/env bash
# launch-worker.sh — start a background coding worker under hc on one of the configured lanes.
#
# Provider-agnostic: the launcher knows no agent CLI. Each lane in config/overseer.env says how to start
# its agent (command template: base command, resume command, read-only / write args, env, how the task
# and extra directories are passed). See config/overseer.env.example and SETUP.md.
# Routing (`--lane auto`, the default) is configurable: each role (ROLES) draws from its pool
# (ROUTE_<role>, else ROUTE_DEFAULT, else LANES), lanes in state/lanes-paused are skipped, and the lane is
# picked by strict round-robin within the pool, or by ROUTER_CMD if set. With no ROUTE_*/ROUTER_CMD
# settings every role rotates across LANES. Caps: MAX_PER_LANE live workers per lane, MAX_TOTAL in total.
#
# Usage:
#   launch-worker.sh --name NAME --cwd DIR --task "TASK" [--lane auto|<LANE>]
#     [--space SPACE_ID] [--read-only] [--role ROLE] [--add-dir DIR]... [--dry-run]
#   launch-worker.sh --resume NAME --task "FOLLOW-UP" [--space SPACE_ID] [--add-dir DIR]... [--dry-run]
#     Reopens a released worker: same lane, same worktree, and its last conversation there (the lane's
#     RESUME_CMD), with FOLLOW-UP as the next message. Lane, cwd, role and read-only come from
#     state/workers.log. It does not use a rotation turn.
set -euo pipefail

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"; readonly SKILL_DIR
readonly CONFIG="${OVERSEER_CONFIG:-$SKILL_DIR/config/overseer.env}"
[ -f "$CONFIG" ] || { echo "launch-worker: no $CONFIG (copy config/overseer.env.example; see SETUP.md)" >&2; exit 2; }
# shellcheck source=/dev/null
source "$CONFIG"
read -r -a LANES <<< "${LANES:?LANES is not set in $CONFIG}"
: "${MAX_PER_LANE:=5}" "${MAX_TOTAL:=10}" "${ROLES:=impl review probe}" "${ROUTER_CMD:=}"
readonly STATE_DIR="$SKILL_DIR/state"
readonly RR_FILE="$STATE_DIR/next-lane-index" PAUSED_FILE="$STATE_DIR/lanes-paused"
readonly LOG_FILE="$STATE_DIR/workers.log" LOCK_DIR="$STATE_DIR/.lock"

NAME="" CWD="" LANE="auto" TASK="" SPACE="" ROLE="impl" READ_ONLY=0 DRY_RUN=0 RESUME=""
ADD_DIRS=()

die() { echo "launch-worker: $*" >&2; exit 2; }
# Lane fields. Lane names are validated to [A-Z0-9_], so the eval'd names are safe.
has() { declare -p "LANE_${LANE}_$1" >/dev/null 2>&1; }
scalar() { local v="LANE_${LANE}_$1"; printf '%s' "${!v:-}"; }
array_into() {  # array_into DEST FIELD: copy the lane's array field (or empty) into DEST
  local v="LANE_${LANE}_$2"
  if ! has "$2"; then eval "$1=()"; return; fi
  [[ "$(declare -p "$v")" == "declare -a"* ]] || die "$v must be a bash array, e.g. $v=(cmd --flag value)"
  # shellcheck disable=SC1087  # builds ${LANE_X_F[@]+"${LANE_X_F[@]}"} for eval (empty-safe on bash 3.2)
  eval "$1=(\${$v[@]+\"\${$v[@]}\"})"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --name) NAME="${2:-}"; shift 2 ;;
    --cwd) CWD="${2:-}"; shift 2 ;;
    --lane|--profile) LANE="${2:-}"; shift 2 ;;
    --task) TASK="${2:-}"; shift 2 ;;
    --space) SPACE="${2:-}"; shift 2 ;;
    --role) ROLE="${2:-}"; shift 2 ;;
    --add-dir) [ -d "${2:-}" ] || die "--add-dir must be an existing directory"; ADD_DIRS+=("$2"); shift 2 ;;
    --read-only) READ_ONLY=1; shift ;;
    --resume) RESUME="${2:-}"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --model|--effort) die "$1 is fixed per lane by policy (config/overseer.env)" ;;
    *) die "unknown argument: $1" ;;
  esac
done

for l in "${LANES[@]}"; do [[ "$l" =~ ^[A-Z0-9_]+$ ]] || die "lane name '$l' must be A-Z 0-9 _"; done
if [ -n "$RESUME" ]; then
  # Restore name, lane, cwd, role and read-only from this worker's latest launch record.
  [ -f "$LOG_FILE" ] || die "no $LOG_FILE to resume from"
  REC=$(awk -F'\t' -v n="$RESUME" '$3==n && $5!="RELEASED"' "$LOG_FILE" | tail -1)
  [ -n "$REC" ] || die "no launch record for worker '$RESUME' in $LOG_FILE"
  NAME="$RESUME"
  LANE=$(printf '%s' "$REC" | cut -f4); ROLE=$(printf '%s' "$REC" | cut -f5)
  [ -n "$CWD" ] || CWD=$(printf '%s' "$REC" | cut -f6)
  RO=$(printf '%s' "$REC" | cut -f8)
  if [ "$RO" = "ro=1" ] || { [ -z "$RO" ] && [ "$ROLE" != "impl" ]; }; then READ_ONLY=1; fi
fi
[[ "$NAME" =~ ^[a-z0-9_-]{1,32}$ ]] || die "--name must be 1-32 of a-z 0-9 - _"
[ -d "$CWD" ] || die "--cwd must be an existing directory (got '$CWD')"
if [ "$LANE" != "auto" ]; then
  known=0; for l in "${LANES[@]}"; do [ "$l" = "$LANE" ] && known=1; done
  [ "$known" -eq 1 ] || die "--lane must be auto or one of: ${LANES[*]}"
fi
[[ "$ROLE" =~ ^[a-z][a-z0-9_]*$ ]] && [[ " $ROLES " == *" $ROLE "* ]] || die "--role must be one of ROLES: $ROLES"
case "$ROLE" in coordinator|guard) die "role '$ROLE' is reserved" ;; esac
[ -n "$TASK" ] || die "--task is required"
command -v hc >/dev/null || die "hc not installed"
mkdir -p "$STATE_DIR"

is_paused() { [ -f "$PAUSED_FILE" ] && grep -qx "$1" "$PAUSED_FILE"; }
live_count() { hc ls --json ${1:+--label "overseer.profile=$1"} | python3 -c 'import json,sys;print(len(json.load(sys.stdin)["terminals"]))'; }
total_workers() { local n=0; for l in "${LANES[@]}"; do n=$((n + $(live_count "$l"))); done; echo "$n"; }

acquire_lock() {
  local tries=0
  until mkdir "$LOCK_DIR" 2>/dev/null; do
    tries=$((tries + 1)); [ $tries -gt 100 ] && die "state lock busy: $LOCK_DIR (remove if stale)"
    sleep 0.1
  done
  trap 'rmdir "$LOCK_DIR" 2>/dev/null || true' EXIT
}
acquire_lock

# 1. Pick the lane. Pool = ROUTE_<role> | ROUTE_DEFAULT | LANES. Paused lanes are skipped.
#    ROUTER_CMD (if set) chooses from the pool; otherwise strict round-robin within the pool, with one
#    counter per pool (state/next-lane-index for the shared default pool).
ADVANCE=0
if [ "$LANE" = "auto" ]; then
  pool_var="ROUTE_$ROLE"; POOL_SRC="${!pool_var:-}"; RR_POOL_FILE="$RR_FILE.$ROLE"
  if [ -z "$POOL_SRC" ]; then POOL_SRC="${ROUTE_DEFAULT:-${LANES[*]}}"; RR_POOL_FILE="$RR_FILE"; fi
  read -r -a POOL <<< "$POOL_SRC"
  for l in "${POOL[@]}"; do
    [[ " ${LANES[*]} " == *" $l "* ]] || die "routing for role $ROLE names lane '$l', which is not in LANES"
  done
  [ ${#POOL[@]} -gt 0 ] || die "no lanes to route role $ROLE to"
  if [ -n "$ROUTER_CMD" ]; then
    ELIGIBLE=(); for l in "${POOL[@]}"; do is_paused "$l" || ELIGIBLE+=("$l"); done
    [ ${#ELIGIBLE[@]} -gt 0 ] || die "all lanes for role $ROLE are paused"
    LANE=$(OVERSEER_ROUTE_ROLE="$ROLE" OVERSEER_NAME="$NAME" OVERSEER_TASK="$TASK" OVERSEER_READ_ONLY="$READ_ONLY" \
      OVERSEER_CANDIDATES="${ELIGIBLE[*]}" OVERSEER_STATE_DIR="$STATE_DIR" bash -c "$ROUTER_CMD") \
      || die "ROUTER_CMD failed (exit $?): $ROUTER_CMD"
    LANE=$(printf '%s\n' "$LANE" | head -1 | tr -d '[:space:]')
    [[ " ${ELIGIBLE[*]} " == *" $LANE "* ]] || die "ROUTER_CMD returned '$LANE', not one of: ${ELIGIBLE[*]}"
  else
    idx=$(cat "$RR_POOL_FILE" 2>/dev/null || echo 0)
    { [[ "$idx" =~ ^[0-9]+$ ]] && [ "$idx" -lt ${#POOL[@]} ]; } || idx=0
    for _ in "${POOL[@]}"; do
      is_paused "${POOL[$idx]}" || break
      idx=$(( (idx + 1) % ${#POOL[@]} ))
    done
    LANE="${POOL[$idx]}"; is_paused "$LANE" && die "all lanes for role $ROLE are paused"
    ADVANCE=1
  fi
elif is_paused "$LANE"; then
  die "lane $LANE is paused (remove it from $PAUSED_FILE to resume)"
fi

count=$(live_count "$LANE")
[ "$count" -lt "$MAX_PER_LANE" ] || die "$LANE already has $count live workers (max $MAX_PER_LANE)"
[ "$(total_workers)" -lt "$MAX_TOTAL" ] || die "already $MAX_TOTAL live workers in total"
if [ "$(hc get "$NAME" 2>/dev/null | python3 -c 'import json,sys;print(json.load(sys.stdin)["state"])' 2>/dev/null)" = "live" ]; then
  die "a live terminal named '$NAME' already exists"
fi

# 2. Build the worker argv from the lane's template:
#    [RESUME_CMD | CMD] + [RO_ARGS | RW_ARGS] + add-dir args + TASK_FLAG + "TASK"
#    env: ENV_CMD output (export K='v' lines; values never shown) + STATIC_ENV + [RO_ENV | RW_ENV]
has CMD || die "lane $LANE: LANE_${LANE}_CMD is not set in $CONFIG"
if [ -n "$RESUME" ]; then
  has RESUME_CMD || die "lane $LANE has no LANE_${LANE}_RESUME_CMD; start a fresh worker instead"
  array_into WORKER RESUME_CMD
else
  array_into WORKER CMD
fi
[ ${#WORKER[@]} -gt 0 ] || die "lane $LANE: empty command"
command -v "${WORKER[0]}" >/dev/null || die "lane $LANE: '${WORKER[0]}' is not installed"

ENV_ARGS=() SHOWN_ENV=()
if [ "$READ_ONLY" -eq 1 ]; then
  has RO_ARGS || has RO_ENV || die "lane $LANE has no read-only mode (LANE_${LANE}_RO_ARGS / RO_ENV); use another lane"
  array_into MODE_ARGS RO_ARGS; array_into MODE_ENV RO_ENV
else
  array_into MODE_ARGS RW_ARGS; array_into MODE_ENV RW_ENV
fi
WORKER+=(${MODE_ARGS[@]+"${MODE_ARGS[@]}"})

ADD_DIR_FLAG=$(scalar ADD_DIR)
if [ ${#ADD_DIRS[@]} -gt 0 ]; then
  [ -n "$ADD_DIR_FLAG" ] || die "lane $LANE does not support --add-dir (LANE_${LANE}_ADD_DIR); quote the content into the brief"
  for d in "${ADD_DIRS[@]}"; do
    case "$ADD_DIR_FLAG" in *=) WORKER+=("${ADD_DIR_FLAG}$d") ;; *) WORKER+=("$ADD_DIR_FLAG" "$d") ;; esac
  done
fi
array_into TASK_FLAG TASK_FLAG
WORKER+=(${TASK_FLAG[@]+"${TASK_FLAG[@]}"} "$TASK")

ENV_CMD=$(scalar ENV_CMD)
if [ -n "$ENV_CMD" ]; then
  while IFS= read -r line; do
    if [[ "$line" =~ ^(export\ )?([A-Za-z_][A-Za-z0-9_]*)=\'(.*)\'$ ]] || [[ "$line" =~ ^(export\ )?([A-Za-z_][A-Za-z0-9_]*)=\"(.*)\"$ ]] \
       || [[ "$line" =~ ^(export\ )?([A-Za-z_][A-Za-z0-9_]*)=([^\'\"]*)$ ]]; then
      ENV_ARGS+=("${BASH_REMATCH[2]}=${BASH_REMATCH[3]}"); SHOWN_ENV+=("${BASH_REMATCH[2]}=<from-env-cmd>")
    fi
  done < <(bash -c "$ENV_CMD")
  [ ${#ENV_ARGS[@]} -gt 0 ] || die "lane $LANE: ENV_CMD produced no KEY=value lines: $ENV_CMD"
fi
array_into STATIC_ENV STATIC_ENV
for e in ${STATIC_ENV[@]+"${STATIC_ENV[@]}"} ${MODE_ENV[@]+"${MODE_ENV[@]}"}; do
  [[ "$e" == *=* ]] || die "lane $LANE: env entry '$e' is not KEY=value"
  ENV_ARGS+=("$e"); SHOWN_ENV+=("$e")
done

ACCOUNT=$(scalar ACCOUNT); ACCOUNT="${ACCOUNT:-$LANE}"
# agent.account: lets Herdr mods show which account a worker runs on.
HC_ARGS=(run --bg --json --name "$NAME" --cwd "$CWD" --label "overseer.profile=$LANE" --label "agent.account=$ACCOUNT" --label "overseer.role=$ROLE")
[ -n "$SPACE" ] && HC_ARGS+=(--label "herdr.space=$SPACE")
# OVERSEER_ROLE=worker tells hooks (e.g. the handoff loader) this session is a worker, not the coordinator.
CMD=(env OVERSEER_ROLE=worker ${ENV_ARGS[@]+"${ENV_ARGS[@]}"} "${WORKER[@]}")

if [ "$DRY_RUN" -eq 1 ]; then
  echo "lane: $LANE (live on it: $count/$MAX_PER_LANE; dry-run does not advance the rotation)"
  SHOWN=(env OVERSEER_ROLE=worker ${SHOWN_ENV[@]+"${SHOWN_ENV[@]}"} "${WORKER[@]}")
  printf 'hc'; printf ' %q' "${HC_ARGS[@]}" -- "${SHOWN[@]}"; echo
  exit 0
fi

OUT=$(hc "${HC_ARGS[@]}" -- "${CMD[@]}")
[ "$ADVANCE" -eq 1 ] && echo $(( (idx + 1) % ${#POOL[@]} )) > "$RR_POOL_FILE"
ADDR=$(printf '%s' "$OUT" | python3 -c 'import json,sys;print(json.load(sys.stdin)["address"])')
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\tro=%s%s\n' "$(date '+%Y-%m-%dT%H:%M:%S')" "$ADDR" "$NAME" "$LANE" "$ROLE" "$CWD" \
  "$(printf '%s' "$TASK" | tr '\n\t' '  ' | cut -c1-160)" "$READ_ONLY" "${RESUME:+$'\t'resumed}" >> "$LOG_FILE"
# Name the worker's Herdr tab "<name> · <lane>". Otherwise Herdr numbers it, and the sidebar's
# status groups show "Space · 3" next to the named entry under the coordinator. The tab appears 1-2 s
# after launch; give up quietly after ~6 s (cosmetic only).
if [ -n "$SPACE" ] && command -v herdr-app >/dev/null; then
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12; do
    TAB=$(herdr-app ls 2>/dev/null | python3 -c '
import json,sys
addr=sys.argv[1]
for s in json.load(sys.stdin)["spaces"]:
  for t in s["tabs"]:
    if any(x["terminal"]==addr for x in t["terminals"]): print(t["id"]); sys.exit()' "$ADDR" 2>/dev/null)
    [ -n "$TAB" ] && { herdr-app do tab.rename --id "$TAB" --name "$NAME · $LANE" >/dev/null 2>&1 || true; break; }
    sleep 0.5
  done
fi

printf '%s\n' "$OUT"
echo "lane: $LANE" >&2
