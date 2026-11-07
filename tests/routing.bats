#!/usr/bin/env bats
# Invariant 3 (routing), plus caps and resume (invariant 6, launcher side).
load helpers

setup() { setup_overseer; write_basic_config; sed -i '' 's/^MAX_PER_LANE=.*/MAX_PER_LANE=9/; s/^MAX_TOTAL=.*/MAX_TOTAL=30/' "$CONF"; }

lanes_of() { awk -F'\t' '$5!="RELEASED"{print $4}' "$WLOG" | tr '\n' ' '; }

@test "inv3: no routes -> every role rotates across LANES with one shared counter" {
  for i in 1 2 3 4; do launch --name "i$i" --role impl --task t >/dev/null 2>&1; done
  launch --name r1 --role review --task t >/dev/null 2>&1
  [ "$(lanes_of)" = "A B C A B " ]
  [ "$(cat "$SK/state/next-lane-index")" = "2" ]
}

@test "inv3: per-role pools have independent counters" {
  echo 'ROUTE_impl="A B"' >> "$CONF"; echo 'ROUTE_review="C"' >> "$CONF"
  launch --name i1 --role impl --task t >/dev/null 2>&1
  launch --name r1 --role review --task t >/dev/null 2>&1
  launch --name i2 --role impl --task t >/dev/null 2>&1
  launch --name r2 --role review --task t >/dev/null 2>&1
  launch --name i3 --role impl --task t >/dev/null 2>&1
  [ "$(lanes_of)" = "A C B C A " ]
  [ "$(cat "$SK/state/next-lane-index.impl")" = "1" ]
  [ "$(cat "$SK/state/next-lane-index.review")" = "0" ]
  [ ! -e "$SK/state/next-lane-index" ]
}

@test "inv3: ROUTE_DEFAULT applies to roles without their own route" {
  echo 'ROUTE_DEFAULT="B C"' >> "$CONF"; echo 'ROUTE_impl="A"' >> "$CONF"
  launch --name s1 --role scout --task t >/dev/null 2>&1
  launch --name s2 --role scout --task t >/dev/null 2>&1
  launch --name i1 --role impl --task t >/dev/null 2>&1
  [ "$(lanes_of)" = "B C A " ]
}

@test "inv3: paused lanes are skipped and the counter moves past them" {
  echo B > "$SK/state/lanes-paused"
  for i in 1 2 3; do launch --name "i$i" --task t >/dev/null 2>&1; done
  [ "$(lanes_of)" = "A C A " ]
}

@test "inv3: all lanes of a pool paused -> clear error, nothing launched" {
  echo 'ROUTE_review="C"' >> "$CONF"; echo C > "$SK/state/lanes-paused"
  run launch --name r1 --role review --task t
  [ "$status" -ne 0 ]
  [[ "$output" == *"all lanes for role review are paused"* ]] || false
  [ ! -s "$WLOG" ]
}

@test "inv3: explicit --lane on a paused lane is refused" {
  echo A > "$SK/state/lanes-paused"
  run launch --lane A --name w1 --task t
  [ "$status" -ne 0 ]
  [[ "$output" == *"is paused"* ]] || false
}

@test "inv3: explicit --lane does not advance the rotation" {
  launch --lane C --name x1 --task t >/dev/null 2>&1
  launch --name a1 --task t >/dev/null 2>&1
  [ "$(lanes_of)" = "C A " ]
}

@test "inv3: dry-run does not advance the rotation" {
  launch --name d1 --dry-run --task t >/dev/null 2>&1
  launch --name a1 --task t >/dev/null 2>&1
  [ "$(lanes_of)" = "A " ]
}

@test "inv3: a route naming a lane not in LANES is an error" {
  echo 'ROUTE_impl="A NOPE"' >> "$CONF"
  run launch --name i1 --role impl --task t
  [ "$status" -ne 0 ]
  [[ "$output" == *"not in LANES"* ]] || false
}

@test "inv3: roles outside ROLES and reserved roles are rejected" {
  run launch --name i1 --role deploy --task t
  [ "$status" -ne 0 ]
  [[ "$output" == *"one of ROLES"* ]] || false
  echo 'ROLES="impl coordinator"' >> "$CONF"
  run launch --name i1 --role coordinator --task t
  [ "$status" -ne 0 ]
  [[ "$output" == *"reserved"* ]] || false
}

@test "inv3: ROUTER_CMD chooses, sees only eligible pool lanes and the task" {
  echo 'ROUTE_impl="A B C"' >> "$CONF"; echo B > "$SK/state/lanes-paused"
  cat > "$TEST_ROOT/router.sh" <<'EOF'
echo "$OVERSEER_CANDIDATES|$OVERSEER_ROUTE_ROLE|$OVERSEER_TASK|$OVERSEER_READ_ONLY" > "$OVERSEER_STATE_DIR/router-saw"
echo C
EOF
  echo "ROUTER_CMD=\"bash $TEST_ROOT/router.sh\"" >> "$CONF"
  run launch --name i1 --role impl --task "fix css"
  [ "$status" -eq 0 ]
  [ "$(lanes_of)" = "C " ]
  [ "$(cat "$SK/state/router-saw")" = "A C|impl|fix css|0" ]
  [ ! -e "$SK/state/next-lane-index.impl" ]
}

@test "inv3: ROUTER_CMD answer outside the eligible lanes is refused" {
  echo B > "$SK/state/lanes-paused"; echo 'ROUTER_CMD="echo B"' >> "$CONF"
  run launch --name i1 --task t
  [ "$status" -ne 0 ]
  [[ "$output" == *"returned 'B'"* ]] || false
}

@test "inv3: failing ROUTER_CMD is reported, not silent" {
  echo 'ROUTER_CMD="exit 7"' >> "$CONF"
  run launch --name i1 --task t
  [ "$status" -ne 0 ]
  [[ "$output" == *"ROUTER_CMD failed (exit 7)"* ]] || false
}

@test "example routers: least-busy and by-task-keywords" {
  echo "ROUTER_CMD=\"bash $SK/examples/router/least-busy.sh\"" >> "$CONF"
  launch --lane A --name busy1 --task t >/dev/null 2>&1
  launch --name lb1 --task t >/dev/null 2>&1
  [ "$(lanes_of)" = "A B " ]
  sed 's/FRONTEND_LANE/C/; s/BACKEND_LANE/B/' "$SK/examples/router/by-task-keywords.sh" > "$TEST_ROOT/kw.sh"
  echo "ROUTER_CMD=\"bash $TEST_ROOT/kw.sh\"" >> "$CONF"
  launch --name k1 --task "polish the UI" >/dev/null 2>&1
  launch --name k2 --task "write sql migration" >/dev/null 2>&1
  launch --name k3 --task "refactor" >/dev/null 2>&1
  [ "$(lanes_of)" = "A B C B A " ]
}

@test "caps: per-lane and total caps are enforced" {
  sed -i '' 's/^MAX_PER_LANE=.*/MAX_PER_LANE=1/; s/^MAX_TOTAL=.*/MAX_TOTAL=2/' "$CONF"
  launch --lane A --name a1 --task t >/dev/null 2>&1
  run launch --lane A --name a2 --task t
  [ "$status" -ne 0 ]
  [[ "$output" == *"already has 1 live workers"* ]] || false
  launch --lane B --name b1 --task t >/dev/null 2>&1
  run launch --lane C --name c1 --task t
  [ "$status" -ne 0 ]
  [[ "$output" == *"already 2 live workers in total"* ]] || false
}

@test "inv6: resume restores lane, cwd and read-only, uses RESUME_CMD, keeps the rotation" {
  launch --name w1 --role review --read-only --task first >/dev/null 2>&1   # auto -> A, counter 1
  hc kill w1; hc rm w1
  run bash "$L" --resume w1 --task "follow up"
  [ "$status" -eq 0 ]
  [ "$(last_argv | tail -n +3 | tr '\n' '|')" = "agent-a|--model|m-a|--continue|--deny=Edit,Write|follow up|" ]
  [ "$(last_run | python3 -c 'import json,sys;a=json.load(sys.stdin);print(a[a.index("--cwd")+1])')" = "$CWD" ]
  [ "$(tail -1 "$WLOG" | cut -f4,5,8,9)" = "A	review	ro=1	resumed" ]
  [ "$(cat "$SK/state/next-lane-index")" = "1" ]
}

@test "inv6: resume on a lane without RESUME_CMD is refused" {
  launch --lane C --name w1 --task t >/dev/null 2>&1; hc kill w1; hc rm w1
  run bash "$L" --resume w1 --task again
  [ "$status" -ne 0 ]
  [[ "$output" == *"has no LANE_C_RESUME_CMD"* ]] || false
}
