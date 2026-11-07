#!/usr/bin/env bats
# Static checks for invariants that are about what the code never does, plus provider-agnosticism.
load helpers

S="$REPO_ROOT/skill/herdr-overseer"

@test "inv8: no script stops or restarts the hc server or the Herdr app" {
  [ -z "$(grep -nE 'hc +(server|shutdown|stop|quit)|herdr-app +(quit|stop)|pkill|killall' "$S"/scripts/* "$REPO_ROOT/install.sh" | grep -vE '^[^:]+:[0-9]+:\s*#')" ]
}

@test "inv8: no script approves anything in an agent: the only key ever sent is Escape (deny), by the probe" {
  [ -z "$(grep -nE 'hc +keys' "$S"/scripts/* | grep -vE 'probe-lane\.sh:.*hc keys "\$name" escape')" ]
  [ "$(grep -cE 'hc +keys' "$S/scripts/probe-lane.sh")" = 1 ]
}

@test "inv8: no script pushes or merges" {
  [ -z "$(grep -nE 'git[^|;]* (push|merge)\b' "$S"/scripts/*)" ]
}

@test "inv8: the brief template forbids pushing and merging; the reviewer rule is present" {
  grep -q "don't push or merge" "$S/SKILL.md"
  grep -q "Focus exclusively on blocking logic errors" "$S/SKILL.md"
}

@test "agnostic: launcher, worktree and release scripts name no agent CLI" {
  [ -z "$(grep -niE '\b(claude|codex|agy|antigravity|opencode|gemini|ccs)\b' \
    "$S/scripts/launch-worker.sh" "$S/scripts/make-worktree.sh" "$S/scripts/release-workers.py" "$S/scripts/probe-lane.sh" "$S/scripts/wait-worker.sh")" ]
}

@test "agnostic: every lane in lanes.examples sources and has a CMD array" {
  run bash -c "source '$S/config/lanes.examples'; for v in \$(compgen -A variable | grep -E '^LANE_[A-Z0-9_]+_CMD\$' | grep -v '_ENV_CMD\$'); do [[ \"\$(declare -p \$v)\" == 'declare -a'* ]] || { echo \"not array: \$v\"; exit 1; }; done; compgen -A variable | grep -E '^LANE_[A-Z0-9_]+_CMD\$' | grep -vc '_ENV_CMD\$'"
  [ "$status" -eq 0 ]
  [ "$output" -ge 4 ]
}

@test "config example sources cleanly and defines a lane for every LANES entry" {
  run bash -c "source '$S/config/overseer.env.example'; for l in \$LANES; do v=LANE_\${l}_CMD; declare -p \$v >/dev/null || exit 1; done"
  [ "$status" -eq 0 ]
}

@test "suite hygiene: no unenforced assertions (mid-test '! cmd', 'a && b', bare [[ ]]) in any test file" {
  bad=$(grep -nE '^\s+(!\s|\[\[.*\]\]\s*$)|^\s+\[.*\]\s*&&|^\s+(alive|refute)\b.*&&' "$REPO_ROOT"/tests/*.bats | grep -v '|| false' || true)
  [ -z "$bad" ] || { echo "$bad"; false; }
}

@test "suite hygiene: a failing refute/[[ ]] assertion really fails a test on this bash" {
  d="$BATS_TEST_TMPDIR/meta"; mkdir -p "$d"
  printf 'load %s/tests/helpers\n@test x { refute true; true; }\n@test y { [[ a == b ]] || false; true; }\n' "$REPO_ROOT" > "$d/m.bats"
  run bats "$d/m.bats"
  [ "$(grep -c '^not ok' <<< "$output")" = 2 ]
}
