#!/usr/bin/env bash
# probe-lane.sh — conformance probe: does a lane's agent behave the way the overseer needs?
#
#   probe-lane.sh --lane LANE --repo /abs/repo [--timeout 300] [--no-scope-check] [--keep]
#
# Starts real workers (they use the lane's account; each turn is a tiny task) in throwaway worktrees of
# --repo and checks:
#   C1 task delivered    the agent got the task from the command line and answered it
#   C2 read-only holds   a --read-only worker asked to create a file does not create it (SKIP if the lane
#                        has no read-only mode). WARN if it only holds because the probe denied a
#                        permission prompt (Escape): a real read-only worker would stall there.
#   C3 status            hc reported `working` during the turn and `done`/`idle` after it, turn >= 1
#   C4 resume            after release, --resume continues the same conversation: the agent returns the
#                        digits of turn 1's code word reversed (a replayed history can't fake that)
#   C5 resume scope      with a decoy session of the same lane in another directory, --resume still picks
#                        this directory's session (skipped with --no-scope-check or if C4 is skipped)
#   C6 cleanup           workers released, worktrees and probe branches removed, nothing left in hc
# A trust/login prompt stops the probe as BLOCKED (nothing is ever accepted). During the read-only write test
# only, a write-permission prompt is DENIED with Escape and reported as C2 WARN. A usage/rate-limit
# message ends the probe as LIMIT (the lane's account, not its template; counts as not passing). Screens of every
# failing check are saved under state/probes/. Exit 0 only if no check FAILED or was BLOCKED.
set -uo pipefail

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
S="$SKILL_DIR/scripts"
LANE="" REPO="" TIMEOUT=300 SCOPE=1 KEEP=0
while [ $# -gt 0 ]; do
  case "$1" in
    --lane) LANE="$2"; shift 2 ;;
    --repo) REPO="$2"; shift 2 ;;
    --timeout) TIMEOUT="$2"; shift 2 ;;
    --no-scope-check) SCOPE=0; shift ;;
    --keep) KEEP=1; shift ;;
    -h|--help) sed -n 2,22p "$0"; exit 0 ;;
    *) echo "probe-lane: unknown argument $1" >&2; exit 2 ;;
  esac
done
[ -n "$LANE" ] && { [ -d "$REPO/.git" ] || [ -f "$REPO/.git" ]; } || { echo "usage: probe-lane.sh --lane LANE --repo /abs/repo" >&2; exit 2; }
CONFIG="${OVERSEER_CONFIG:-$SKILL_DIR/config/overseer.env}"
# shellcheck source=/dev/null
source "$CONFIG"
has() { declare -p "LANE_${LANE}_$1" >/dev/null 2>&1; }
has CMD || { echo "probe-lane: lane $LANE is not defined in $CONFIG" >&2; exit 2; }

# Code words carry a 4-digit number. Recall is checked on the number's digits reversed: language models
# reverse digits reliably (letters less so), and the reversed digits never appear in a replayed history.
rand4() { local x; while :; do x=$(( RANDOM % 9000 + 1000 )); [ "$x" != "$(printf '%s' "$x" | rev)" ] && { echo "$x"; return; }; done; }
N=$(rand4); D=$(rand4); while [ "$D" = "$N" ] || [ "$D" = "$(printf '%s' "$N" | rev)" ]; do D=$(rand4); done
lc=$(echo "$LANE" | tr 'A-Z_' 'a-z-')
WORD="HERON-$N"; DECOY="OTTER-$D"; REV=$(printf '%s' "$N" | rev); DREV=$(printf '%s' "$D" | rev)
NAME="probe-$lc-$N"; DNAME="decoy-$lc-$N"
OUT="$SKILL_DIR/state/probes/$NAME"; mkdir -p "$OUT"
WTS=() NAMES=()
RES=""
res() { RES="$RES$1|$2|$3"$'\n'; }   # res CHECK STATUS DETAIL

ro_ok=0; { has RO_ARGS || has RO_ENV; } && ro_ok=1
resume_ok=0; has RESUME_CMD && resume_ok=1
RO_FLAG=(); [ "$ro_ok" = 1 ] && RO_FLAG=(--read-only)
ROLE="${ROLES%% *}"   # any configured role; explicit --lane bypasses routing anyway

state_of() { hc get "$1" 2>/dev/null | python3 -c 'import json,sys
d=json.load(sys.stdin); s=d.get("status") or {}
print((s.get("state") if isinstance(s,dict) else s) or "-", d.get("turn") or 0, d.get("state"))' 2>/dev/null || echo "gone 0 gone"; }
screen() { hc read --lines 0 "$1" 2>/dev/null; }
TRUST_RE='trust (this|the) (folder|directory|project|contents)|Do you trust|log ?in to|sign in|please run /login|authenticate'
PERM_RE='Do you want to (proceed|allow|run|make this edit|create)|Allow (once|always)|Allow (creation|this|edit)|\(y/n\)|deny'
LIMIT_RE='usage limit|rate.?limit|limit reached|hit your [^ ]* ?limit|quota exceeded|API Error: 429|out of credits'
DENY=0 DENIED=0   # DENY=1: answer permission prompts with Escape (deny). Trust/login prompts are never touched.

# wait_turn NAME MARKER -> sets SEEN (states seen), TURN, OUTCOME (ok|timeout|blocked|gone)
wait_turn() {
  local name="$1" marker="$2" t0=$SECONDS st turn live scr settled=0
  SEEN="" OUTCOME=timeout TURN=0
  while [ $((SECONDS - t0)) -lt "$TIMEOUT" ]; do
    read -r st turn live <<< "$(state_of "$name")"
    [ "$live" = live ] || { OUTCOME=gone; return; }
    [[ " $SEEN " == *" $st "* ]] || SEEN="$SEEN $st"
    TURN="$turn"
    scr="$(screen "$name")"
    if printf '%s' "$scr" | tail -40 | grep -qiE "$LIMIT_RE" && ! printf '%s' "$scr" | grep -q -- "$marker"; then
      OUTCOME=limit; printf '%s' "$scr" > "$OUT/limit-$name.txt"; return
    fi
    if [ "$st" = error ] && ! printf '%s' "$scr" | grep -q -- "$marker"; then
      OUTCOME=error; printf '%s' "$scr" > "$OUT/error-$name.txt"; return
    fi
    if printf '%s' "$scr" | grep -q -- "$marker"; then
      # marker printed; give status up to 60 s to settle to done/idle
      if [ "$st" = done ] || [ "$st" = idle ]; then OUTCOME=ok; return; fi
      settled=$((settled + 1)); [ "$settled" -gt 30 ] && { OUTCOME=ok; return; }
    elif [ "$st" = blocked ] || printf '%s' "$scr" | tail -25 | grep -qiE "$TRUST_RE|$PERM_RE"; then
      sleep 3; scr="$(screen "$name")"
      if ! printf '%s' "$scr" | grep -q -- "$marker"; then
        if [ "$DENY" = 1 ] && [ "$DENIED" -lt 3 ] && ! printf '%s' "$scr" | tail -25 | grep -qiE "$TRUST_RE" \
           && printf '%s' "$scr" | tail -25 | grep -qiE "$PERM_RE"; then
          printf '%s' "$scr" > "$OUT/denied-$DENIED-$name.txt"
          hc keys "$name" escape >/dev/null 2>&1   # deny the write; never approve anything
          DENIED=$((DENIED + 1)); sleep 3
          # Some agents treat Escape as "interrupt the turn" and then wait for input; tell them how to go on.
          read -r st _ _ <<< "$(state_of "$name")"
          if [ "$st" != working ]; then
            hc send "$name" "Writing files is not allowed in this session, so skip that step. Continue with the remaining steps of my previous message." >/dev/null 2>&1
            sleep 3
          fi
          continue
        fi
        OUTCOME=blocked; printf '%s' "$scr" > "$OUT/blocked-$name.txt"; return
      fi
    fi
    sleep 2
  done
  screen "$name" > "$OUT/timeout-$name.txt"
}

new_wt() {  # new_wt NAME -> path
  local r; r=$("$S/make-worktree.sh" --repo "$REPO" --name "$1" 2>&1) || { echo "make-worktree failed: $r" >&2; return 1; }
  WTS+=("$1"); printf '%s' "$r" | sed -n 's/^worktree: //p'
}
launch() { "$S/launch-worker.sh" "$@" >/dev/null 2>"$OUT/launch.err"; }
release() { python3 "$S/release-workers.py" --name "$1" >>"$OUT/release.log" 2>&1; ! hc get "$1" >/dev/null 2>&1 || { hc kill "$1" >/dev/null 2>&1; hc rm "$1" >/dev/null 2>&1; return 1; }; }

cleanup() {
  [ "$KEEP" = 1 ] && return
  for n in ${NAMES[@]+"${NAMES[@]}"}; do hc get "$n" >/dev/null 2>&1 && { hc kill "$n" >/dev/null 2>&1; hc rm "$n" >/dev/null 2>&1; }; done
  local repo_name; repo_name=$(basename "$(cd "$REPO" && pwd)")
  for w in ${WTS[@]+"${WTS[@]}"}; do
    git -C "$REPO" worktree remove --force "$HOME/.herdr/worktrees/$repo_name/$w" >/dev/null 2>&1
    git -C "$REPO" branch -D "overseer/$w" >/dev/null 2>&1
  done
}
finish() {
  local left=0 repo_name; repo_name=$(basename "$(cd "$REPO" && pwd)")
  cleanup
  if [ "$KEEP" = 0 ]; then
    for n in ${NAMES[@]+"${NAMES[@]}"}; do hc get "$n" >/dev/null 2>&1 && left=1; done
    for w in ${WTS[@]+"${WTS[@]}"}; do [ -e "$HOME/.herdr/worktrees/$repo_name/$w" ] && left=1; git -C "$REPO" rev-parse -q --verify "overseer/$w" >/dev/null && left=1; done
    [ "$left" = 0 ] && res C6 PASS "workers, worktrees and branches removed" || res C6 FAIL "leftovers (see hc ls / git worktree list)"
  else res C6 SKIP "--keep"; fi
  echo "lane $LANE  (code word $WORD; screens in ${OUT/#$HOME/~})"
  printf '%s' "$RES" | awk -F'|' '{printf "  %-3s %-8s %s\n", $1, $2, $3}'
  ! printf '%s' "$RES" | grep -qE '\|(FAIL|BLOCKED|LIMIT)\|'
  exit $?
}
trap 'res ABORT FAIL "interrupted"; finish' INT TERM

# ---- turn 1: delivery, read-only, status ----------------------------------------------------------
WT=$(new_wt "$NAME") || { res C1 FAIL "could not create worktree"; finish; }
FILE="probe-write-$N.txt"
TASK1="Automated conformance probe; this is not real work. Do not use subagents or start other agents. \
(1) Remember this code word for later: $WORD. \
(2) Try to create a file named $FILE in the current directory containing the word hello. If you are not allowed to, just say so. \
(3) Finally print, on its own line, the words PROBE, ONE and $N joined with hyphens."
NAMES+=("$NAME")
if ! launch --lane "$LANE" --name "$NAME" --cwd "$WT" --role "$ROLE" ${RO_FLAG[@]+"${RO_FLAG[@]}"} --task "$TASK1"; then
  res C1 FAIL "launch failed: $(head -c 200 "$OUT/launch.err")"; finish
fi
[ "$ro_ok" = 1 ] && DENY=1
wait_turn "$NAME" "PROBE-ONE-$N"
DENY=0
case "$OUTCOME" in
  ok) res C1 PASS "answered (states:$SEEN)" ;;
  blocked) res C1 BLOCKED "prompt on screen; not accepted. See blocked-$NAME.txt"; finish ;;
  limit) res C1 LIMIT "the account hit a usage/rate limit (see limit-$NAME.txt); pause the lane and re-probe after the reset"; finish ;;
  error) res C1 FAIL "agent went to status error (see error-$NAME.txt; states:$SEEN)"; finish ;;
  *) res C1 FAIL "$OUTCOME after ${TIMEOUT}s (states:$SEEN)"; finish ;;
esac
if [ "$ro_ok" = 1 ]; then
  if [ -e "$WT/$FILE" ]; then res C2 FAIL "read-only worker created $FILE"
  elif [ "$DENIED" -gt 0 ]; then res C2 WARN "not written, but the agent asked permission instead of refusing ($DENIED prompt(s) denied with Escape); a read-only worker of this lane stalls on that prompt until the coordinator answers"
  else res C2 PASS "no file written; git status: $(git -C "$WT" status --porcelain | wc -l | xargs) changes"; fi
else res C2 SKIP "lane has no read-only mode"; fi
read -r st turn live <<< "$(state_of "$NAME")"
if [[ "$SEEN" == *working* ]] && { [ "$st" = done ] || [ "$st" = idle ]; } && [ "$turn" -ge 1 ]; then
  res C3 PASS "working -> $st, turn $turn"
else
  screen "$NAME" > "$OUT/status-$NAME.txt"; res C3 FAIL "states seen:$SEEN, now $st, turn $turn"
fi

# ---- decoy session (same lane, other directory) for the resume-scope check -----------------------
if [ "$resume_ok" = 1 ] && [ "$SCOPE" = 1 ]; then
  DWT=$(new_wt "$DNAME") && NAMES+=("$DNAME") && \
  launch --lane "$LANE" --name "$DNAME" --cwd "$DWT" --role "$ROLE" ${RO_FLAG[@]+"${RO_FLAG[@]}"} \
    --task "Automated probe decoy. Remember this code word: $DECOY. Then print, on its own line, the words PROBE, DECOY and $N joined with hyphens." \
  && wait_turn "$DNAME" "PROBE-DECOY-$N"
  release "$DNAME" || true
fi

# ---- turn 2: release, resume, recall --------------------------------------------------------------
if [ "$resume_ok" = 1 ]; then
  release "$NAME" || echo "note: release refused or failed; killed directly" >> "$OUT/release.log"
  if ! "$S/launch-worker.sh" --resume "$NAME" --task "Automated probe, part 2. Take the number in the code word I gave you at the start of this conversation and write its digits in reverse order. Reply with only those reversed digits, then print on its own line the words PROBE, TWO and $N joined with hyphens." >/dev/null 2>"$OUT/launch.err"; then
    res C4 FAIL "resume launch failed: $(head -c 200 "$OUT/launch.err")"
  else
    wait_turn "$NAME" "PROBE-TWO-$N"
    scr="$(screen "$NAME")"
    if [ "$OUTCOME" = blocked ]; then res C4 BLOCKED "prompt after resume; see blocked-$NAME.txt"
    elif [ "$OUTCOME" != ok ]; then res C4 FAIL "$OUTCOME after resume"; printf '%s' "$scr" > "$OUT/resume-$NAME.txt"
    elif printf '%s' "$scr" | grep -q -- "$REV"; then res C4 PASS "recalled $WORD (answered $REV)"
    else res C4 FAIL "no $REV on screen"; printf '%s' "$scr" > "$OUT/resume-$NAME.txt"; fi
    if [ "$SCOPE" = 1 ] && [ "$OUTCOME" = ok ]; then
      if printf '%s' "$scr" | grep -q -- "$DREV"; then res C5 FAIL "resumed the decoy session from another directory"
      elif printf '%s' "$scr" | grep -q -- "$REV"; then res C5 PASS "picked this directory's session over a newer decoy"
      else res C5 FAIL "neither session recalled"; fi
    elif [ "$SCOPE" = 0 ]; then res C5 SKIP "--no-scope-check"; fi
  fi
  release "$NAME" || true
else
  res C4 SKIP "lane has no RESUME_CMD"; res C5 SKIP "lane has no RESUME_CMD"
  release "$NAME" || true
fi
finish
