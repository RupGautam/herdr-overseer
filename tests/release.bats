#!/usr/bin/env bats
# Invariant 6 (release): only launcher workers, never working/blocked, hold, busy background jobs.
load helpers

setup() {
  setup_overseer; write_basic_config
  sed -i '' 's/^MAX_PER_LANE=.*/MAX_PER_LANE=9/; s/^MAX_TOTAL=.*/MAX_TOTAL=30/' "$CONF"
  export R="$SK/scripts/release-workers.py"
  OLD=$(( ($(date +%s) - 3600) * 1000 ))   # status changed an hour ago
}

teardown() { for p in ${BG_PIDS:-}; do pkill -P "$p" 2>/dev/null; kill "$p" 2>/dev/null; done; true; }

mk() {  # mk NAME STATE: a launcher worker in STATE for an hour
  launch --lane A --name "$1" --task t >/dev/null 2>&1
  fake_set "$1" status "{\"state\":\"$2\"}"; fake_set "$1" status_ms "$OLD"
}
alive() { hc get "$1" >/dev/null 2>&1; }

@test "inv6: sweep releases done/idle, never working or blocked, and logs RELEASED" {
  mk w-done done; mk w-idle idle; mk w-work working; mk w-block blocked
  run python3 "$R" --idle-min 30
  [ "$status" -eq 0 ]
  refute alive w-done
  refute alive w-idle
  alive w-work
  alive w-block
  [ "$(grep -c $'\tRELEASED\t' "$WLOG")" = "2" ]
}

@test "inv6: sweep respects overseer.hold=1 and the idle threshold" {
  mk w-hold done; hc label w-hold overseer.hold=1
  mk w-fresh done; fake_set w-fresh status_ms "$(( $(date +%s) * 1000 ))"
  run python3 "$R" --idle-min 30
  alive w-hold
  alive w-fresh
  [[ "$output" == *"kept w-hold: on hold"* ]] || false
}

@test "inv6: terminals without launcher labels are never touched" {
  hc run --bg --json --name stranger --cwd "$CWD" -- sh >/dev/null
  fake_set stranger status '{"state":"done"}'; fake_set stranger status_ms "$OLD"
  python3 "$R" --idle-min 30
  alive stranger
}

@test "inv6: --name refuses working workers" {
  mk w-work working
  run python3 "$R" --name w-work
  alive w-work
  [[ "$output" == *"only done/idle"* ]] || false
}

@test "known failure 1: a 'done' worker whose background job burns CPU is kept by the sweep" {
  bash -c 'yes >/dev/null & sleep 600' >/dev/null 2>&1 3>&- & ROOT=$!; BG_PIDS="$ROOT"
  sleep 0.5; BG_PIDS="$BG_PIDS $(pgrep -P "$ROOT" | tr '\n' ' ')"
  mk w-job done; fake_set w-job pid "$ROOT"; fake_set w-job foreground "{\"pid\": $ROOT}"
  run python3 "$R" --idle-min 30
  alive w-job
  [[ "$output" == *"kept w-job: done but background processes busy"* ]] || false
  run python3 "$R" --name w-job
  alive w-job
  [[ "$output" == *"use --force"* ]] || false
  run python3 "$R" --name w-job --force
  refute alive w-job
}

@test "known failure 1: idle helper processes (MCP-server-like sleepers) do not block release" {
  bash -c 'sleep 600 & sleep 600 & wait' >/dev/null 2>&1 3>&- & ROOT=$!; BG_PIDS="$ROOT"
  sleep 0.5; BG_PIDS="$BG_PIDS $(pgrep -P "$ROOT" | tr '\n' ' ')"
  mk w-quiet done; fake_set w-quiet pid "$ROOT"; fake_set w-quiet foreground "{\"pid\": $ROOT}"
  run python3 "$R" --idle-min 30
  refute alive w-quiet
}

@test "known failure 1: the agent process itself is excluded from the busy measure" {
  yes >/dev/null 2>&1 3>&- & AGENT=$!; BG_PIDS="$AGENT"
  mk w-agent done; fake_set w-agent pid "$$"; fake_set w-agent foreground "{\"pid\": $AGENT}"
  # root = this test shell; the busy process is the agent itself -> not counted.
  OVERSEER_BUSY_CPU=0.2 run python3 "$R" --name w-agent
  refute alive w-agent
}
