# Fixes for real failures

Each of these came from a failure seen in real runs.

## F1. The idle sweep killed a job that was still running: FIXED (no design change)

**Evidence:**
- The sweep released a worker as "done for 31 min" while its end-to-end test suite was still running.
- The coordinator had to resume the worker and restart the job.

**Fix (implemented, `release-workers.py`):** a worker isn't released if its descendant processes, not
counting the agent process itself, use ≥ 20% of a core over a 2-second sample. `--name` refuses too,
unless you pass `--force`.

Idle MCP-server children (about 10 per Claude worker, 0% CPU) don't count. This enforces the existing rule
"working workers are never released"; the worker *was* working, its status just didn't say so.

**Tests:** `tests/release.bats`, "known failure 1" ×3.

**Limit:** a job that's paused waiting on I/O (e.g. a simulator booting at 0% CPU for longer than 2 s)
still looks idle.

## F1b. The sweep released a worker the coordinator was still reviewing (found while doing F1)

**Evidence:**
- The sweep released a worker after "done for 30 min".
- A minute later the coordinator's `hc read` on it returned `no terminal`.
- No work was lost (it was committed), but the coordinator lost the worker's final screen.

**Implemented: option B** (`release-workers.py` saves `state/screens/<name>-<time>.txt`; test `release.bats` F1b). Options considered:
- **A.** The launcher sets `overseer.hold=1` when the worker's turn ends, and the coordinator's own
  `release-workers.py --name` removes it. The sweep then only catches workers the coordinator forgot.
  But "forgot" is exactly the case the sweep exists for, so this needs a second, longer threshold
  (e.g. 120 min) for held workers.
- **B.** Before releasing, the sweep saves the worker's final screen to
  `state/screens/<name>-<ts>.txt`. The coordinator reads that file when `hc read` fails.
  Cheap, no behaviour change for the worker. **Recommended.**

## F2. A handoff request was lost to a usage limit

**Evidence:**
- The guard asked a coordinator for a handoff while it was at its 5-hour limit.
- About an hour later the guard logged `FAILED (status error)`.
- The next session started without a handoff for that stretch.

Today the guard logs it once and doesn't retry, which is right, because the cache is cold by then.

**Implemented** (test `handoff.bats` F2): on that failure, the guard writes a **mechanical** handoff itself (no LLM) to
`state/handoffs/<Repo>/<ts>-auto.md`. Its header says "mechanical, not written by the coordinator". It
contains:
- `hc ls` (workers, lanes, status);
- the last 30 lines of `workers.log`;
- `git worktree list` and `git branch -vv` for `overseer/*`;
- `gh pr list` (if `gh` exists).

The loader already picks the newest file. **Adds:** about 60 lines to `handoff-guard.py` and one test.

## F3. agy reports `idle` before its first turn

**Evidence:**
- In a release/resume test, `hc wait` returned at once, right after launch and after
  `--resume`.
- The coordinator had to learn to wait for `working` first. `SKILL.md` documents it, but it's a manual
  rule the coordinator can forget.

**Implemented** (`tests/wait.bats`, 8 tests): `scripts/wait-worker.sh NAME [--marker M] [--after-turn N] [--timeout S]`, the waiting logic
`probe-lane.sh` already uses:
- wait until the worker has been `working`, or has printed output after the launch;
- then wait for `done`/`idle` or the marker;
- return `blocked` (with the screen) on a prompt.

`SKILL.md` section 5 would point to it instead of raw `hc wait`. **Adds:** one script, about 60 lines,
plus tests. It isn't agent-specific: it covers any agent with an initial idle state.

## Bugs found and fixed by this test work

| Bug | How it was found | Fix | Guarded by |
|---|---|---|---|
| Parallel `make-worktree.sh` on one repo raced on `.git/config` ("could not lock config file") | Two live probes created worktrees at the same time | Per-repo lock (`<git-common-dir>/overseer-worktree.lock`) | `worktree.bats`: parallel creation (fails without the fix) |
| `WORKTREE_POST_CREATE` split on `;`, so a hook containing `;` broke | Only surfaced once the test assertions were really enforced | It's a bash array now; a plain string is one command | `worktree.bats` ×2 |
| Include list and hooks were trimmed with `xargs`, which breaks on quotes | Same | Pure-bash trim | `worktree.bats` |
| Workers inherit agent-session markers from whatever started the hc server (Claude Code: transcripts off, so `--resume` breaks) | Live probe in the sandbox showed "Transcript saving is off — inherited CLAUDE_CODE_CHILD_SESSION marker" | `WORKER_ENV_UNSET` (config); `tests/sandbox.sh` clears the markers | `launcher.bats` |
| A router script that failed made the launcher exit silently (`pipefail`) | Router tests | Explicit error message | `routing.bats` |
| `handoff-guard.py --only` accepted an address only | Tests | Accepts a name too | `handoff.bats` |
| Test-suite flaw: on bash 3.2, bats ignores mid-test `! cmd`, `a && b` and `[[ ]]`, so many assertions never ran | A minimal bats experiment | `refute` helper, one assertion per line, `[[ ]] \|\| false` | Two suite-hygiene tests: a lint, and a self-test that a failing assertion fails |
| `probe-lane.sh` cleanup never ran, and C6 reported PASS anyway: worktrees were created in a `$(...)` subshell, so the cleanup list stayed empty and C6 checked that same empty list | Moving the live setup over: a smoke test cloned `node_modules` from a "removed" probe worktree | No subshell; C6 checks git and hc by the run's derived names | `probe.bats` ×3 (the full-flow test fails on the old probe) |
