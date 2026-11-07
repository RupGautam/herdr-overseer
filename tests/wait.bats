#!/usr/bin/env bats
# F3: wait-worker.sh waits for a turn to START, then to END; prompts, limits, errors and gone workers end it.
load helpers

setup() {
  setup_overseer; write_basic_config
  export W="$SK/scripts/wait-worker.sh" OVERSEER_WAIT_POLL=0.2 OVERSEER_WAIT_GRACE=1
  launch --lane A --name w1 --task t >/dev/null 2>&1
}
later() { ( sleep "$1"; shift; "$@" ) >/dev/null 2>&1 3>&- & }

@test "F3: an agent that reports idle before its first turn is not mistaken for finished" {
  fake_set w1 status '{"state":"idle"}'                 # idle before the turn starts (agy pattern)
  later 1 fake_set w1 status '{"state":"working"}'
  later 2 fake_set w1 status '{"state":"done"}'
  t0=$SECONDS
  run "$W" w1 --timeout 20
  [ "$status" -eq 0 ]
  [[ "$output" == "done w1 status=done"* ]] || false
  [ $((SECONDS - t0)) -ge 2 ]
}

@test "F3: a turn counter increase counts as started even if 'working' was never seen" {
  fake_set w1 status '{"state":"idle"}'
  later 1 fake_set w1 turn 1
  run "$W" w1 --timeout 20
  [ "$status" -eq 0 ]
  [[ "$output" == *"turn=1"* ]] || false
}

@test "F3: the marker ends the wait at once" {
  fake_set w1 status '{"state":"working"}'
  later 1 fake_set w1 screen '"all good\nOVERSEER-DONE-7"'
  run "$W" w1 --marker OVERSEER-DONE-7 --timeout 20
  [ "$status" -eq 0 ]
}

@test "F3: finished without the marker -> done-no-marker after the grace, screen saved" {
  fake_set w1 status '{"state":"done"}'; fake_set w1 turn 1
  run "$W" w1 --marker OVERSEER-DONE-9 --after-turn 0 --timeout 20
  [ "$status" -eq 0 ]
  [[ "$output" == "done-no-marker w1"*"screen="* ]] || false
}

@test "F3: a turn that finished before the wait started is caught by --after-turn or by the marker" {
  fake_set w1 status '{"state":"done"}'; fake_set w1 turn 1; fake_set w1 screen '"OVERSEER-DONE-3"'
  run "$W" w1 --after-turn 0 --timeout 5
  [ "$status" -eq 0 ]
  run "$W" w1 --marker OVERSEER-DONE-3 --timeout 5
  [ "$status" -eq 0 ]
  fake_set w1 screen '""'
  run "$W" w1 --timeout 1          # neither given: cannot tell, so it times out rather than guess
  [ "$status" -eq 6 ]
}

@test "F3: a trust or permission prompt -> blocked (exit 2), nothing pressed, screen saved" {
  fake_set w1 status '{"state":"working"}'
  fake_set w1 screen '"Do you trust the contents of this project?\n> 1. Yes\n  2. No"'
  run "$W" w1 --timeout 20
  [ "$status" -eq 2 ]
  [[ "$output" == "blocked w1"*"screen="* ]] || false
  refute grep -q '"keys"' "$FAKE_HC_DIR/calls.jsonl"
}

@test "F3: usage limit -> limit (exit 3); status error -> error (exit 4)" {
  fake_set w1 status '{"state":"working"}'
  fake_set w1 screen '"You have hit your 5-hour limit"'
  run "$W" w1 --timeout 20
  [ "$status" -eq 3 ]
  fake_set w1 screen '"Traceback"'; fake_set w1 status '{"state":"error"}'
  run "$W" w1 --timeout 20
  [ "$status" -eq 4 ]
}

@test "F3: a worker that disappears -> gone (exit 5); no result -> timeout (exit 6)" {
  fake_set w1 status '{"state":"working"}'
  run "$W" w1 --timeout 1
  [ "$status" -eq 6 ]
  later 1 hc kill w1
  run "$W" w1 --timeout 20
  [ "$status" -eq 5 ]
}
