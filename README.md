# herdr-overseer

A coordinator/worker workflow for CLI coding agents on top of [Herdr](https://herdr.dev) and its `hc`
terminal CLI. It works with any provider.

One agent session is the **coordinator**. It plans, splits the work, and hands tasks to **background
workers**. Workers are real interactive agents (Claude Code, Codex, Gemini/Antigravity, opencode, or
anything else that runs in a terminal), each in its own `hc` terminal and git worktree. The
coordinator reviews the diffs, runs the builds and tests itself, integrates, and reports what it
actually verified.

Everything specific to your setup is configuration:

- **Lanes:** each lane is one agent CLI on one account with a fixed model or custom agent. One command
  template covers every CLI: how to start it, resume it, make it read-only, pass the task, inject env.
  The scripts know no providers.
- **Roles and routing:** you name the kinds of work (`impl`, `review`, `scout`, `map`, …) and choose
  which lanes do each. Inside each role's pool, workers rotate in strict round-robin, or your own
  router script picks the lane.

For example: Claude plans and coordinates, two Claude accounts alternate on implementation, and Codex
custom agents take review, scouting, code mapping and exploration.

## Set it up with your agent

**Give [`SETUP.md`](SETUP.md) to your coding agent.** It's written for an LLM: it lists what must not
change, asks you which agents, accounts and routing you want, and maps your CLIs onto lanes from their
`--help`. It then installs everything and runs a real probe of every lane before reporting back.

To do it by hand:

```sh
git clone https://github.com/rupgautam/herdr-overseer && cd herdr-overseer
./install.sh --coordinator claude-code      # or: --coordinator other [--dest DIR]
$EDITOR ~/.claude/skills/herdr-overseer/config/overseer.env
```

Copy-ready lane definitions for Claude Code, Antigravity, opencode and Codex are in
[`config/lanes.examples`](skill/herdr-overseer/config/lanes.examples), and known agent quirks are in
[`AGENT-NOTES.md`](skill/herdr-overseer/AGENT-NOTES.md).

## What you get

| Piece | What it does |
|---|---|
| `SKILL.md` | The coordinator's playbook: briefs, routing by role, waiting, review rules, release, handoffs, and what to show the user |
| `scripts/launch-worker.sh` | Starts a worker from a lane template on the routed lane, with caps, labels, logging and resume |
| `scripts/make-worktree.sh` | One worktree per task: fresh branch from `origin/main`, cloned `node_modules`, gitignored runtime files (secrets filtered), post-create hooks |
| `scripts/wait-worker.sh` | Waits for a worker's turn to start and then end, for any agent; stops on prompts, limits and errors without pressing keys |
| `scripts/release-workers.py` | Frees finished workers (on acceptance, or after 30 idle minutes), keeping each one's final screen and never touching a busy background job; worktrees and conversations stay resumable |
| `scripts/handoff-guard.py` + `start-guard.sh` | Asks an idle coordinator for a detailed handoff before its prompt cache expires, writes a mechanical one if that request is lost, and runs the idle sweep |
| `scripts/load-handoff.py` | Loads the newest handoff into the next coordinator session: a Claude Code hook, or `--print` for other agents |
| `scripts/probe-lane.sh` | Conformance probe for a lane: task delivery, read-only enforcement, status, resume and its directory scope, cleanup, using real workers |
| `scripts/watch.py` | Optional watcher for setup health: prompts, rate limits, stalls, routing and policy breaks |
| `examples/` | Router scripts (least busy, by task keywords) and a worktree hook (agy trust) |

## Tests

`bats tests/` runs the contract suite (81 tests) against a stand-in `hc` (`tests/bin/hc`). It covers
worker identity, the lane template, routing, worktrees and secrets, release and resume, handoffs, and
static safety checks. You need [bats-core](https://github.com/bats-core/bats-core) (`brew install bats-core`).
Real agents are checked by `probe-lane.sh`. Run it inside `eval "$(tests/sandbox.sh)"`, a separate hc
session and Herdr app home, so live tests never touch your running terminals. [`docs/COLD-START-TEST.md`](docs/COLD-START-TEST.md) describes
the end-to-end test by a third party.

## Requirements

- macOS. Worktree dependency cloning uses APFS copy-on-write (`cp -c`).
- The Herdr app (provides `hc` and `herdr-app`), Python 3 and git.
- The agent CLIs you want as lanes, each logged in to its account(s).

## Safety

- Folder-trust prompts are never auto-accepted. The coordinator asks you.
- Workers never push or merge. The coordinator integrates.
- Secrets never reach worktrees (`.env` is filtered to public keys), and `ENV_CMD` values are never printed.
- A lane that runs without permission prompts relies on its worktree as the boundary. Never point one
  at your main checkout.

## License

MIT
