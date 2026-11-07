#!/usr/bin/env bats
# Invariant 7: handoff guard asks idle coordinators once per idle stretch; loader picks the newest.
load helpers

setup() {
  setup_overseer; write_basic_config
  export G="$SK/scripts/handoff-guard.py" LH="$SK/scripts/load-handoff.py"
  export PROJ="$TEST_ROOT/Proj"; mkdir -p "$PROJ"; git -C "$PROJ" init -q
  OLD=$(( ($(date +%s) - 3600) * 1000 ))
}

coordinator() {  # coordinator NAME AGENT [label|tab]
  hc run --bg --json --name "$1" --cwd "$PROJ" -- "$2" >/dev/null
  if [ "${3:-label}" = label ]; then hc label "$1" overseer.role=coordinator; else hc label "$1" "where=Proj / coordinator"; fi
  fake_set "$1" agent "\"$2\""; fake_set "$1" cwd "\"$PROJ\""
  fake_set "$1" status '{"state":"done"}'; fake_set "$1" status_ms "$OLD"; fake_set "$1" turn 5
}
sends() { [ -f "$FAKE_HC_DIR/sends.jsonl" ] && wc -l < "$FAKE_HC_DIR/sends.jsonl" | xargs || echo 0; }

@test "inv7: idle coordinator gets exactly one handoff request per idle stretch" {
  coordinator c1 claude-code
  python3 "$G" --once --only c1 >/dev/null
  [ "$(sends)" = "1" ]
  grep -q '\[handoff-guard\].*state/handoffs/Proj/' "$FAKE_HC_DIR/sends.jsonl"
  python3 "$G" --once --only c1 >/dev/null
  fake_set c1 turn 6            # the handoff turn itself
  python3 "$G" --once --only c1 >/dev/null
  [ "$(sends)" = "1" ]
  fake_set c1 turn 8            # real work happened, idle again
  python3 "$G" --once --only c1 >/dev/null
  [ "$(sends)" = "2" ]
}

@test "inv7: coordinator found by Herdr tab name; agents outside COORDINATOR_AGENTS ignored" {
  coordinator c1 claude-code tab
  coordinator c2 some-other-agent label
  python3 "$G" --once >/dev/null
  [ "$(sends)" = "1" ]
  grep -q '"to": "f1"' "$FAKE_HC_DIR/sends.jsonl"
  echo 'COORDINATOR_AGENTS="claude-code some-other-agent"' >> "$CONF"
  python3 "$G" --once >/dev/null
  [ "$(sends)" = "2" ]
}

@test "inv7: not idle long enough -> no request" {
  coordinator c1 claude-code
  fake_set c1 status_ms "$(( $(date +%s) * 1000 ))"
  python3 "$G" --once --only c1 >/dev/null
  [ "$(sends)" = "0" ]
}

@test "inv7: a handoff the coordinator already wrote to its memory folder suppresses the request" {
  coordinator c1 claude-code
  MEM="$HOME/.claude/projects/$(printf '%s' "$PROJ" | sed 's/[^A-Za-z0-9]/-/g')/memory"
  mkdir -p "$MEM"; echo "# mine" > "$MEM/handoff-today.md"
  run python3 "$G" --once --only c1
  [ "$(sends)" = "0" ]
  [[ "$output" == *"already wrote"* ]] || false
}

@test "known failure 2: request lost to an error state is reported once, not retried" {
  coordinator c1 claude-code
  python3 "$G" --once --only c1 >/dev/null
  fake_set c1 status '{"state":"error"}'
  run python3 "$G" --once --only c1
  [[ "$output" == *"handoff request FAILED"* ]] || false
  run python3 "$G" --once --only c1
  [[ "$output" != *"FAILED"* ]] || false
  [ "$(sends)" = "1" ]
}

@test "F2: when the request is lost, the guard writes a mechanical handoff that the loader then serves" {
  coordinator c1 claude-code
  launch --lane A --name w-busy --task "some task" >/dev/null 2>&1
  python3 "$G" --once --only c1 >/dev/null
  fake_set c1 status '{"state":"error"}'
  run python3 "$G" --once --only c1
  [[ "$output" == *"Wrote a mechanical handoff instead"* ]] || false
  f=$(ls "$SK"/state/handoffs/Proj/*-auto.md)
  grep -q "MECHANICAL" "$f"
  grep -q "| w-busy | f2 | A | impl |" "$f"
  grep -q "some task" "$f"
  run python3 "$LH" --print "$PROJ"
  [[ "$output" == *"MECHANICAL"* ]] || false
}

@test "inv7: loader prints the newest handoff (state dir or memory), skips workers, worktrees, stale files" {
  mkdir -p "$SK/state/handoffs/Proj"
  echo "# older" > "$SK/state/handoffs/Proj/a.md"; touch -t 202601010000 "$SK/state/handoffs/Proj/a.md"
  echo "# newest" > "$SK/state/handoffs/Proj/b.md"
  run python3 "$LH" --print "$PROJ"
  [[ "$output" == *"# newest"* ]] || false
  [[ "$output" != *"# older"* ]] || false
  run env OVERSEER_ROLE=worker python3 "$LH" --print "$PROJ"
  [ -z "$output" ]
  mkdir -p "$HOME/.herdr/worktrees/Proj/x"
  run python3 "$LH" --print "$HOME/.herdr/worktrees/Proj/x"
  [ -z "$output" ]
  touch -t 202601010000 "$SK/state/handoffs/Proj/b.md"
  run python3 "$LH" --print "$PROJ"
  [ -z "$output" ]
}

@test "inv7: loader hook mode emits SessionStart JSON with additionalContext" {
  mkdir -p "$SK/state/handoffs/Proj"; echo "# H1" > "$SK/state/handoffs/Proj/b.md"
  run bash -c "echo '{\"cwd\":\"$PROJ\"}' | python3 '$LH'"
  echo "$output" | python3 -c 'import json,sys;d=json.load(sys.stdin);assert d["hookSpecificOutput"]["hookEventName"]=="SessionStart";assert "# H1" in d["hookSpecificOutput"]["additionalContext"];assert d["systemMessage"].startswith("Loaded coordinator handoff")'
}
