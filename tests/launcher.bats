#!/usr/bin/env bats
# Invariants 1 (worker identity: labels, env marker, log), 2 (lane template, fixed model) and the
# secret-redaction part of 8.
load helpers

setup() { setup_overseer; write_basic_config; }

@test "inv1: worker gets lane/role/account labels, OVERSEER_ROLE=worker, and a workers.log line" {
  run launch --lane A --name w-one --role impl --task "do the thing"
  [ "$status" -eq 0 ]
  [ "$(last_label overseer.profile)" = "A" ]
  [ "$(last_label overseer.role)" = "impl" ]
  [ "$(last_label agent.account)" = "acct-a" ]
  [ "$(last_argv | sed -n 1,2p | tr '\n' ' ')" = "env OVERSEER_ROLE=worker " ]
  # log: time, addr, name, lane, role, cwd, task, ro flag
  IFS=$'\t' read -r ts addr name lane role cwd task ro < "$WLOG"
  [[ "$ts" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}$ ]] || false
  [ "$addr" = "f1" ]
  [ "$name" = "w-one" ]
  [ "$lane" = "A" ]
  [ "$role" = "impl" ]
  [ "$cwd" = "$CWD" ]
  [ "$task" = "do the thing" ]
  [ "$ro" = "ro=0" ]
}

@test "inv1: account label defaults to the lane name" {
  run launch --lane C --name w-c --task t
  [ "$status" -eq 0 ]
  [ "$(last_label agent.account)" = "C" ]
}

@test "inv1: --space adds herdr.space label" {
  run launch --lane A --name w-s --task t --space sp123
  [ "$(last_label herdr.space)" = "sp123" ]
}

@test "inv2: write-capable argv = CMD + RW_ARGS + task (positional)" {
  run launch --lane A --name w1 --task "my task"
  [ "$(last_argv | tail -n +3 | tr '\n' '|')" = "agent-a|--model|m-a|--auto|my task|" ]
}

@test "inv2: read-only argv = CMD + RO_ARGS + joined add-dir + task; log says ro=1" {
  mkdir -p "$TEST_ROOT/ref"
  run launch --lane A --name w1 --read-only --add-dir "$TEST_ROOT/ref" --task q
  [ "$status" -eq 0 ]
  [ "$(last_argv | tail -n +3 | tr '\n' '|')" = "agent-a|--model|m-a|--deny=Edit,Write|--add-dir=$TEST_ROOT/ref|q|" ]
  [ "$(cut -f8 "$WLOG")" = "ro=1" ]
}

@test "inv2: separate add-dir flag and TASK_FLAG" {
  mkdir -p "$TEST_ROOT/ref"
  run launch --lane B --name w1 --read-only --add-dir "$TEST_ROOT/ref" --task q
  [ "$(last_argv | grep -v '^SECRET_TOKEN' | tail -n +3 | tr '\n' '|')" = "agent-b|-s|read-only|--add-dir|$TEST_ROOT/ref|-i|q|" ]
}

@test "inv2: env per mode: STATIC_ENV + RW_ENV / RO_ENV" {
  run launch --lane C --name w1 --task t
  [ "$(last_argv | sed -n 3,4p | tr '\n' '|')" = 'SHARED=1|CFG={"agent":"build"}|' ]
  run launch --lane C --name w2 --read-only --task t
  [ "$(last_argv | sed -n 3,4p | tr '\n' '|')" = 'SHARED=1|CFG={"agent":"plan"}|' ]
}

@test "inv2: --model and --effort are rejected" {
  run launch --lane A --name w1 --task t --model x
  [ "$status" -ne 0 ]
  [[ "$output" == *"fixed per lane"* ]] || false
  run launch --lane A --name w1 --task t --effort high
  [ "$status" -ne 0 ]
}

@test "inv2: lane without read-only mode refuses --read-only" {
  sed -i '' '/^LANE_C_RO_ENV/d' "$CONF"
  run launch --lane C --name w1 --read-only --task t
  [ "$status" -ne 0 ]
  [[ "$output" == *"no read-only mode"* ]] || false
}

@test "inv2: lane without ADD_DIR refuses --add-dir" {
  mkdir -p "$TEST_ROOT/ref"
  run launch --lane C --name w1 --add-dir "$TEST_ROOT/ref" --task t
  [ "$status" -ne 0 ]
  [[ "$output" == *"does not support --add-dir"* ]] || false
}

@test "inv2: template field written as a string instead of an array is rejected" {
  sed -i '' '/^LANE_A_CMD=/d' "$CONF"; echo 'LANE_A_CMD="agent-a --model m-a"' >> "$CONF"
  run launch --lane A --name w1 --task t
  [ "$status" -ne 0 ]
  [[ "$output" == *"must be a bash array"* ]] || false
}

@test "inv2: missing agent binary is reported" {
  echo 'LANE_A_CMD=(no-such-agent-xyz)' >> "$CONF"
  run launch --lane A --name w1 --task t
  [ "$status" -ne 0 ]
  [[ "$output" == *"is not installed"* ]] || false
}

@test "inv2: bad lane names and unknown lanes are rejected" {
  run launch --lane Z --name w1 --task t
  [ "$status" -ne 0 ]
  [[ "$output" == *"one of: A B C"* ]] || false
  sed -i '' 's/^LANES=.*/LANES="A b"/' "$CONF"
  run launch --lane A --name w1 --task t
  [ "$status" -ne 0 ]
  [[ "$output" == *"must be A-Z 0-9 _"* ]] || false
}

@test "inv8: ENV_CMD values reach the worker but never --dry-run output or workers.log" {
  run launch --lane B --name w1 --dry-run --task t
  [ "$status" -eq 0 ]
  [[ "$output" == *"SECRET_TOKEN=\\<from-env-cmd\\>"* ]] || false
  [[ "$output" != *"s3cr3t-value"* ]] || false
  run launch --lane B --name w2 --task t
  last_argv | grep -qx "SECRET_TOKEN=s3cr3t-value"
  refute grep -q "s3cr3t-value" "$WLOG"
}

@test "inv8: ENV_CMD that prints nothing usable fails the launch" {
  echo 'LANE_B_ENV_CMD="echo nothing here"' >> "$CONF"
  run launch --lane B --name w1 --task t
  [ "$status" -ne 0 ]
  [[ "$output" == *"produced no KEY=value"* ]] || false
}

@test "dry-run starts nothing and writes no log" {
  run launch --lane A --name w1 --dry-run --task t
  [ "$status" -eq 0 ]
  refute grep -q '^\["run"' "$FAKE_HC_DIR/calls.jsonl"
  [ ! -s "$WLOG" ]
}

@test "duplicate live name is refused" {
  launch --lane A --name w1 --task t
  run launch --lane B --name w1 --task t
  [ "$status" -ne 0 ]
  [[ "$output" == *"already exists"* ]] || false
}

@test "WORKER_ENV_UNSET strips inherited variables from the worker; unset by default" {
  run launch --lane A --name w1 --task t
  [ "$(last_argv | sed -n 1,2p | tr '\n' ' ')" = "env OVERSEER_ROLE=worker " ]
  echo 'WORKER_ENV_UNSET="PARENT_SESSION_MARKER OTHER_ONE bad-name"' >> "$CONF"
  run launch --lane A --name w2 --task t
  [ "$(last_argv | sed -n 1,6p | tr '\n' ' ')" = "env -u PARENT_SESSION_MARKER -u OTHER_ONE OVERSEER_ROLE=worker " ]
}
