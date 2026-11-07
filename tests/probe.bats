#!/usr/bin/env bats
# probe-lane.sh bookkeeping: whatever it creates (workers, worktrees, branches) is gone afterwards, and C6
# checks that against git and hc, not against its own lists.
load helpers

setup() {
  setup_overseer; write_basic_config
  export P="$SK/scripts/probe-lane.sh" FAKE_HC_ECHO_AGENT=1
  export REPO="$TEST_ROOT/proj"
  git init -q --bare "$TEST_ROOT/origin.git"; git clone -q "$TEST_ROOT/origin.git" "$REPO" 2>/dev/null
  echo x > "$REPO/f"; git -C "$REPO" add -A; git -C "$REPO" -c user.email=t@t -c user.name=t commit -qm i
  git -C "$REPO" push -q origin HEAD:main
}
leftovers() {
  { git -C "$REPO" worktree list | grep -E 'probe-|decoy-'
    git -C "$REPO" branch --list 'overseer/probe-*' 'overseer/decoy-*'
    ls -d "$HOME/.herdr/worktrees/proj/"* 2>/dev/null
    hc ls --json | grep -E '"(probe|decoy)-'; } || true
}

@test "probe: full flow with decoy and resume leaves no worktree, branch or terminal behind" {
  run "$P" --lane A --repo "$REPO" --timeout 10
  echo "$output"
  [[ "$output" == *"C6  PASS"* ]] || false
  [ -z "$(leftovers)" ] || { leftovers; false; }
}

@test "probe: a lane that never answers is cleaned up too" {
  export FAKE_HC_ECHO_AGENT=0
  run "$P" --lane C --repo "$REPO" --timeout 2
  [[ "$output" == *"C1  FAIL"* ]] || false
  [[ "$output" == *"C6  PASS"* ]] || false
  [ -z "$(leftovers)" ] || { leftovers; false; }
}

@test "probe: --keep leaves its worktree and says C6 SKIP" {
  run "$P" --lane C --repo "$REPO" --timeout 2 --keep
  [[ "$output" == *"C6  SKIP"* ]] || false
  [ -n "$(git -C "$REPO" branch --list 'overseer/probe-*')" ]
}
