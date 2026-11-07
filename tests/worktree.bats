#!/usr/bin/env bats
# Invariant 4: one worktree per task, secrets never reach it, post-create hooks.
load helpers

setup() {
  setup_overseer; write_basic_config
  export MW="$SK/scripts/make-worktree.sh"
  export REPO="$TEST_ROOT/proj"
  git init -q --bare "$TEST_ROOT/origin.git"
  git clone -q "$TEST_ROOT/origin.git" "$REPO" 2>/dev/null
  printf 'node_modules\n.env\nsecret.json\n' > "$REPO/.gitignore"
  echo '{"lockfileVersion":3}' > "$REPO/package-lock.json"
  git -C "$REPO" add -A
  git -C "$REPO" -c user.email=t@t -c user.name=t commit -qm init
  git -C "$REPO" push -q origin HEAD:main
  mkdir -p "$REPO/node_modules/dep"; echo x > "$REPO/node_modules/dep/index.js"
  printf 'VITE_PUBLIC_URL=https://x\nexport VITE_FLAG=1\nDB_PASSWORD=hunter2\nAPI_SECRET=abc\n' > "$REPO/.env"
  echo '{"k":"v"}' > "$REPO/secret.json"
  echo 'WORKTREE_PUBLIC_ENV_RE="^VITE_"' >> "$CONF"
}

@test "inv4: worktree on overseer/<name> from origin/main under ~/.herdr/worktrees/<Repo>/" {
  run bash "$MW" --repo "$REPO" --name t1
  [ "$status" -eq 0 ]
  WT="$HOME/.herdr/worktrees/proj/t1"
  [ "$(git -C "$WT" rev-parse --abbrev-ref HEAD)" = "overseer/t1" ]
  [ -e "$HOME/.herdr/worktrees/.metadata_never_index" ]
}

@test "inv4: .env keeps only public keys; secrets never reach the worktree" {
  echo .env > "$REPO/.worktreeinclude"
  run bash "$MW" --repo "$REPO" --name t1
  WT="$HOME/.herdr/worktrees/proj/t1"
  [ "$(cat "$WT/.env")" = "$(printf 'VITE_PUBLIC_URL=https://x\nexport VITE_FLAG=1')" ]
  refute grep -q "hunter2" "$WT/.env"
  refute grep -q "API_SECRET" "$WT/.env"
  [ "$(stat -f %Lp "$WT/.env")" = "600" ]
  [[ "$output" != *"hunter2"* ]] || false
}

@test "inv4: empty WORKTREE_PUBLIC_ENV_RE never copies .env" {
  sed -i '' 's/^WORKTREE_PUBLIC_ENV_RE=.*/WORKTREE_PUBLIC_ENV_RE=""/' "$CONF"
  echo .env > "$REPO/.worktreeinclude"
  run bash "$MW" --repo "$REPO" --name t1
  [ ! -e "$HOME/.herdr/worktrees/proj/t1/.env" ]
  [[ "$output" == *".env: skipped"* ]] || false
}

@test "inv4: listed files that are not gitignored are removed again; ../ paths are refused" {
  printf 'secret.json\nnotes.txt\n../outside\n' > "$REPO/.worktreeinclude"; echo hi > "$REPO/notes.txt"
  run bash "$MW" --repo "$REPO" --name t1
  WT="$HOME/.herdr/worktrees/proj/t1"
  [ -e "$WT/secret.json" ]
  [ ! -e "$WT/notes.txt" ]
  [[ "$output" == *"WARNING removed notes.txt"* ]] || false
  [[ "$output" == *"skip ../outside"* ]] || false
  [[ "$output" != *"config:   notes.txt"* ]] || false
  [ -z "$(git -C "$WT" status --porcelain)" ]
}

@test "inv4: include list falls back to config/worktree-include/<Repo>" {
  echo secret.json > "$SK/config/worktree-include/proj"
  run bash "$MW" --repo "$REPO" --name t1
  [ -e "$HOME/.herdr/worktrees/proj/t1/secret.json" ]
}

@test "inv4: node_modules cloned from a checkout with the identical lockfile" {
  run bash "$MW" --repo "$REPO" --name t1
  [ -e "$HOME/.herdr/worktrees/proj/t1/node_modules/dep/index.js" ]
}

@test "inv4: post-create hooks get repo, worktree, root; a failing hook is reported, worktree kept" {
  printf '#!/bin/sh\necho "$1|$2|$3" > "%s/hook-args"\necho trusted\n' "$TEST_ROOT" > "$TEST_ROOT/hook.sh"
  echo "WORKTREE_POST_CREATE=(\"sh $TEST_ROOT/hook.sh\" \"sh -c 'echo nope; exit 3'\")" >> "$CONF"
  run bash "$MW" --repo "$REPO" --name t1
  [ "$status" -eq 0 ]
  REPO_REAL="$(cd "$REPO" && pwd)"
  [ "$(cat "$TEST_ROOT/hook-args")" = "$REPO_REAL|$HOME/.herdr/worktrees/proj/t1|$HOME/.herdr/worktrees" ]
  [[ "$output" == *"hook.sh: trusted"* ]] || false
  [[ "$output" == *"FAILED nope"* ]] || false
  [ -d "$HOME/.herdr/worktrees/proj/t1" ]
}

@test "inv4: a plain-string WORKTREE_POST_CREATE is one command, never split on ';'" {
  echo "WORKTREE_POST_CREATE=\"sh -c 'echo one; echo two'\"" >> "$CONF"
  run bash "$MW" --repo "$REPO" --name t1
  [ "$status" -eq 0 ]
  [[ "$output" != *"FAILED"* ]] || false
  [[ "$output" == *"one"* ]] || false
}

@test "inv4: parallel worktree creation on one repo does not race on .git/config" {
  for i in 1 2 3 4 5 6; do bash "$MW" --repo "$REPO" --name "par$i" >"$TEST_ROOT/par$i.out" 2>&1 & done
  wait
  for i in 1 2 3 4 5 6; do
    [ "$(git -C "$HOME/.herdr/worktrees/proj/par$i" rev-parse --abbrev-ref HEAD)" = "overseer/par$i" ]
  done
  refute grep -l "could not lock" "$TEST_ROOT"/par*.out
  [ ! -e "$REPO/.git/overseer-worktree.lock" ]
}

@test "inv4: existing worktree name and bad names are refused" {
  bash "$MW" --repo "$REPO" --name t1 >/dev/null
  run bash "$MW" --repo "$REPO" --name t1
  [ "$status" -ne 0 ]
  [[ "$output" == *"already exists"* ]] || false
  run bash "$MW" --repo "$REPO" --name "Bad Name"
  [ "$status" -ne 0 ]
}
