#!/usr/bin/env bash
# launch-worker.sh — start a background coding worker under hc on one of the configured lanes.
#
# Lanes, their agents (claude / agy / opencode), ccs accounts and models are defined in
# config/overseer.env (copy config/overseer.env.example). `--lane auto` (default) rotates through
# LANES in strict round-robin, skipping lanes listed in state/lanes-paused. Caps: MAX_PER_LANE live
# workers per lane, MAX_TOTAL in total.
#
# Usage:
#   launch-worker.sh --name NAME --cwd DIR --task "TASK" [--lane auto|<LANE>]
#     [--space SPACE_ID] [--read-only] [--role impl|review|probe] [--add-dir DIR]... [--dry-run]
#   launch-worker.sh --resume NAME --task "FOLLOW-UP" [--space SPACE_ID] [--add-dir DIR]... [--dry-run]
#     Reopens a released worker: same lane, same worktree, and its last conversation there
#     (claude --continue / agy -c / opencode -c), with FOLLOW-UP as the next message. Lane, cwd, role
#     and read-only come from state/workers.log. It does not use a rotation turn.
set -euo pipefail

readonly SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
readonly CONFIG="${OVERSEER_CONFIG:-$SKILL_DIR/config/overseer.env}"
[ -f "$CONFIG" ] || { echo "launch-worker: no $CONFIG (copy config/overseer.env.example)" >&2; exit 2; }
# shellcheck source=/dev/null
source "$CONFIG"
read -r -a LANES <<< "${LANES:?LANES is not set in $CONFIG}"
: "${CLAUDE_MODEL:?}" "${CLAUDE_EFFORT:?}" "${MAX_PER_LANE:=5}" "${MAX_TOTAL:=10}" "${AGY_SKIP_PERMISSIONS:=1}"
readonly CLAUDE_READ_ONLY_DENY="Edit,Write,NotebookEdit,Bash"
readonly STATE_DIR="$SKILL_DIR/state"
readonly RR_FILE="$STATE_DIR/next-lane-index" PAUSED_FILE="$STATE_DIR/lanes-paused"
readonly LOG_FILE="$STATE_DIR/workers.log" LOCK_DIR="$STATE_DIR/.lock"

NAME="" CWD="" LANE="auto" TASK="" SPACE="" ROLE="impl" READ_ONLY=0 DRY_RUN=0 RESUME=""
ADD_DIRS=()

die() { echo "launch-worker: $*" >&2; exit 2; }
lane_var() { local v="LANE_${1}_$2"; printf '%s' "${!v:-}"; }

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
case "$ROLE" in impl|review|probe) ;; *) die "--role must be impl, review or probe" ;; esac
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

# 1. Pick the lane: strict rotation, skipping paused lanes.
ADVANCE=0
if [ "$LANE" = "auto" ]; then
  idx=$(cat "$RR_FILE" 2>/dev/null || echo 0)
  { [[ "$idx" =~ ^[0-9]+$ ]] && [ "$idx" -lt ${#LANES[@]} ]; } || idx=0
  for _ in "${LANES[@]}"; do
    is_paused "${LANES[$idx]}" || break
    idx=$(( (idx + 1) % ${#LANES[@]} ))
  done
  LANE="${LANES[$idx]}"; is_paused "$LANE" && die "all lanes are paused"
  ADVANCE=1
elif is_paused "$LANE"; then
  die "lane $LANE is paused (remove it from $PAUSED_FILE to resume)"
fi

count=$(live_count "$LANE")
[ "$count" -lt "$MAX_PER_LANE" ] || die "$LANE already has $count live workers (max $MAX_PER_LANE)"
[ "$(total_workers)" -lt "$MAX_TOTAL" ] || die "already $MAX_TOTAL live workers in total"
if [ "$(hc get "$NAME" 2>/dev/null | python3 -c 'import json,sys;print(json.load(sys.stdin)["state"])' 2>/dev/null)" = "live" ]; then
  die "a live terminal named '$NAME' already exists"
fi

# 2. Build the worker argv for the lane's agent type.
TYPE=$(lane_var "$LANE" TYPE); ACCOUNT=$(lane_var "$LANE" ACCOUNT); ACCOUNT="${ACCOUNT:-$LANE}"
ENV_ARGS=() WORKER=() SHOWN_ENV=()
case "$TYPE" in
  claude)
    command -v claude >/dev/null || die "claude not installed"
    PROFILE=$(lane_var "$LANE" CCS)
    if [ -n "$PROFILE" ]; then
      command -v ccs >/dev/null || die "ccs not installed (lane $LANE uses ccs profile $PROFILE)"
      while IFS= read -r line; do   # ccs prints: export KEY='value'
        if [[ "$line" =~ ^export\ ([A-Za-z_][A-Za-z0-9_]*)=\'(.*)\'$ ]]; then
          ENV_ARGS+=("${BASH_REMATCH[1]}=${BASH_REMATCH[2]}"); SHOWN_ENV+=("${BASH_REMATCH[1]}=<from-ccs>")
        fi
      done < <(ccs env "$PROFILE" --format raw --shell bash)
      [ ${#ENV_ARGS[@]} -gt 0 ] || die "ccs env $PROFILE --format raw produced no variables"
    fi
    # --disallowedTools is variadic: the `=` form stops it from swallowing the task.
    WORKER=(claude --model "$CLAUDE_MODEL" --effort "$CLAUDE_EFFORT")
    [ -n "$RESUME" ] && WORKER+=(--continue)
    [ "$READ_ONLY" -eq 1 ] && WORKER+=("--disallowedTools=$CLAUDE_READ_ONLY_DENY")
    for d in ${ADD_DIRS[@]+"${ADD_DIRS[@]}"}; do WORKER+=("--add-dir=$d"); done
    WORKER+=("$TASK") ;;
  agy)
    command -v agy >/dev/null || die "agy (Antigravity CLI) not installed"
    WORKER=(agy --model "${AGY_MODEL:?AGY_MODEL is not set}")
    [ -n "$RESUME" ] && WORKER+=(-c)
    # Read-only: plan mode. Otherwise AGY_SKIP_PERMISSIONS decides; workers run in their own worktrees.
    if [ "$READ_ONLY" -eq 1 ]; then WORKER+=(--mode plan)
    elif [ "$AGY_SKIP_PERMISSIONS" = 1 ]; then WORKER+=(--dangerously-skip-permissions)
    else WORKER+=(--mode accept-edits); fi
    for d in ${ADD_DIRS[@]+"${ADD_DIRS[@]}"}; do WORKER+=(--add-dir "$d"); done
    WORKER+=(-i "$TASK") ;;
  opencode)
    command -v opencode >/dev/null || die "opencode not installed"
    [ ${#ADD_DIRS[@]} -eq 0 ] || die "--add-dir is not supported on opencode lanes; quote the content into the brief"
    agent=build; [ "$READ_ONLY" -eq 1 ] && agent=plan
    # --standalone keeps tool execution inside this hc terminal (not the shared background service).
    # default_agent avoids orchestrator agents from opencode plugins that delegate to sub-agents.
    cfg=$(printf '{"model":"%s","default_agent":"%s"}' "${OPENCODE_MODEL:?OPENCODE_MODEL is not set}" "$agent")
    ENV_ARGS=("OPENCODE_CONFIG_CONTENT=$cfg"); SHOWN_ENV=("${ENV_ARGS[@]}")
    WORKER=(opencode --standalone)
    [ -n "$RESUME" ] && WORKER+=(-c)
    WORKER+=(--prompt "$TASK") ;;
  *) die "lane $LANE: LANE_${LANE}_TYPE must be claude, agy or opencode (got '$TYPE')" ;;
esac

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
[ "$ADVANCE" -eq 1 ] && echo $(( (idx + 1) % ${#LANES[@]} )) > "$RR_FILE"
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
