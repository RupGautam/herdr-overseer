# Shared setup for the bats suite: an isolated HOME, a copy of the skill, and the fake hc on PATH.
REPO_ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"

setup_overseer() {
  export TEST_ROOT="$BATS_TEST_TMPDIR"
  export HOME="$TEST_ROOT/home"; mkdir -p "$HOME"
  export FAKE_HC_DIR="$TEST_ROOT/hc"; mkdir -p "$FAKE_HC_DIR"
  export PATH="$REPO_ROOT/tests/bin:$PATH"
  export SK="$TEST_ROOT/skill"
  cp -R "$REPO_ROOT/skill/herdr-overseer" "$SK"
  rm -rf "$SK/state" "$SK/config/overseer.env"
  mkdir -p "$SK/state"
  export CONF="$SK/config/overseer.env"
  export L="$SK/scripts/launch-worker.sh"
  export WLOG="$SK/state/workers.log"
  export CWD="$TEST_ROOT/work"; mkdir -p "$CWD"
  # Stand-in agent binaries: they only need to exist on PATH for the launcher's install check.
  mkdir -p "$TEST_ROOT/agents"
  for a in agent-a agent-b agent-c; do printf '#!/bin/sh\nexit 0\n' > "$TEST_ROOT/agents/$a"; chmod +x "$TEST_ROOT/agents/$a"; done
  export PATH="$TEST_ROOT/agents:$PATH"
}

# Three-lane config with every template field exercised somewhere.
write_basic_config() {
  cat > "$CONF" <<'EOF'
LANES="A B C"
LANE_A_CMD=(agent-a --model m-a)
LANE_A_RESUME_CMD=(agent-a --model m-a --continue)
LANE_A_RO_ARGS=(--deny=Edit,Write)
LANE_A_RW_ARGS=(--auto)
LANE_A_ADD_DIR="--add-dir="
LANE_A_ACCOUNT="acct-a"
LANE_A_MODEL="m-a"
LANE_B_CMD=(agent-b)
LANE_B_RESUME_CMD=(agent-b resume --last)
LANE_B_RO_ARGS=(-s read-only)
LANE_B_ADD_DIR="--add-dir"
LANE_B_TASK_FLAG=(-i)
LANE_B_ENV_CMD="printf \"export SECRET_TOKEN='s3cr3t-value'\n\""
LANE_C_CMD=(agent-c --standalone)
LANE_C_RW_ENV=('CFG={"agent":"build"}')
LANE_C_RO_ENV=('CFG={"agent":"plan"}')
LANE_C_STATIC_ENV=(SHARED=1)
LANE_C_TASK_FLAG=(--prompt)
ROLES="impl review scout"
MAX_PER_LANE=2
MAX_TOTAL=4
EOF
}

# Last `hc run` call recorded by the fake hc, as JSON array.
last_run() { grep '^\["run"' "$FAKE_HC_DIR/calls.jsonl" | tail -1; }
# Argv after `--` of the last run, one element per line.
last_argv() { last_run | python3 -c 'import json,sys;a=json.load(sys.stdin);print("\n".join(a[a.index("--")+1:]))'; }
# Value of a label in the last run.
last_label() { last_run | python3 -c 'import json,sys;a=json.load(sys.stdin);l=[a[i+1] for i in range(len(a)-1) if a[i]=="--label"];print(dict(x.split("=",1) for x in l).get(sys.argv[1],""))' "$1"; }

# fake_set ADDR FIELD JSON_VALUE: edit a fake terminal (status, status_ms, turn, pid, labels, agent).
fake_set() {
  python3 - "$FAKE_HC_DIR/terminals.json" "$1" "$2" "$3" <<'EOF'
import json, sys
p, addr, field, val = sys.argv[1:]
db = json.load(open(p))
for t in db["terminals"]:
    if t["address"] == addr or t.get("name") == addr:
        t[field] = json.loads(val)
json.dump(db, open(p, "w"))
EOF
}

launch() { bash "$L" --cwd "$CWD" "$@"; }

# Assertions: bats on bash 3.2 does not fail a test on a mid-test `! cmd`, `a && b` or `[[ ]]`.
# Use `refute cmd` for negation, one assertion per line, and `[[ ... ]] || false`.
refute() { if "$@"; then echo "refute: '$*' succeeded" >&2; return 1; fi; }
