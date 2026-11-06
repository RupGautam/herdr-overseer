# herdr-overseer

A coordinator/worker workflow for [Claude Code](https://claude.com/claude-code) on top of
[Herdr](https://herdr.dev) and its `hc` terminal CLI.

One Claude Code session is the **coordinator**. It plans, splits the work, and hands substantial
tasks to **background workers**. Each worker is a real interactive agent in its own `hc` terminal
and git worktree. The coordinator then reviews the diffs, runs the builds and tests itself,
integrates, and reports what it actually verified.

Workers rotate across **lanes** in strict round-robin. A lane is one agent on one account:

- `claude`: Claude Code. Optionally a separate account through [ccs](https://github.com/kaitranntt/ccs) profiles.
- `agy`: Google's Antigravity CLI.
- `opencode`: [opencode](https://opencode.ai).

Spreading work across lanes keeps any single account under its usage limits.

## What you get

| Piece | What it does |
|---|---|
| `SKILL.md` | The workflow the coordinator follows: briefs, waiting, review rules, release, handoffs, and what to show the user |
| `scripts/launch-worker.sh` | Starts a worker on the next lane, with a fixed model per lane, caps, labels and resume |
| `scripts/make-worktree.sh` | One worktree per task: fresh branch from `origin/main`, cloned `node_modules`, gitignored runtime files (secrets filtered out), agy trust |
| `scripts/release-workers.py` | Frees finished workers (on acceptance, or after 30 idle minutes); worktrees and conversations stay resumable |
| `scripts/handoff-guard.py` + `start-guard.sh` | Asks an idle coordinator to write a detailed handoff before its 1 h prompt cache expires, and runs the idle sweep |
| `scripts/load-handoff.py` | SessionStart hook: loads the newest handoff on startup, resume, `/clear` and compaction |
| `scripts/watch.py` | Optional watcher for setup health: prompts, rate limits, stalls, policy breaks |

## Requirements

- macOS. Worktree dependency cloning uses APFS copy-on-write (`cp -c`).
- Claude Code, the Herdr app (provides `herdr-app` and `hc`), Python 3 and git.
- For the lanes you enable: `ccs` (extra Claude accounts), `agy`, `opencode`.
- Optional: `gh`, and the `herdr` CLI for agent status (`herdr integration install claude`).

## Install

```sh
git clone https://github.com/rupgautam/herdr-overseer && cd herdr-overseer
./install.sh            # or --link to symlink while developing, --dry-run to preview
```

This installs `~/.claude/skills/herdr-overseer`, creates `config/overseer.env` from the example and
adds one SessionStart hook to `~/.claude/settings.json`. Your other hooks are kept, and the old file
is saved as `settings.json.bak-herdr-overseer`.

## Configure

Edit `~/.claude/skills/herdr-overseer/config/overseer.env`:

```sh
LANES="CLAUDE_A CLAUDE_B AGY OPENCODE"      # rotation order
LANE_CLAUDE_A_TYPE=claude
LANE_CLAUDE_A_CCS=work                       # ccs profile; empty = your default claude login
LANE_CLAUDE_A_ACCOUNT=work                   # agent.account label
...
CLAUDE_MODEL="claude-sonnet-5-5"; CLAUDE_EFFORT="high"
AGY_MODEL="gemini-3.8-flash-high"; OPENCODE_MODEL="opencode-go/kimi-k3.1-pro"
MAX_PER_LANE=5; MAX_TOTAL=10
```

To use fewer lanes, list fewer in `LANES`. To skip a lane temporarily (for example when its quota
runs out), add its name to `state/lanes-paused`.

For each repo, list the gitignored files a worktree needs (`.env`, Firebase configs and so on) in
`<repo>/.worktreeinclude` or in `config/worktree-include/<RepoFolderName>`. `.env*` files keep only
the variables matching `WORKTREE_PUBLIC_ENV_RE`.

## Set up accounts

Each account logs in once. No credentials are stored in this repo.

```sh
ccs auth create work        # one per claude lane with LANE_<name>_CCS set
agy                         # sign in once and pick the model
opencode auth login
```

Folder trust is your call. Open each repo once with each Claude profile and agy, and accept trust
yourself. After that, new worktrees inherit Claude's trust from the main checkout, and
`make-worktree.sh` adds them to agy's trusted list.

## Use

1. In Herdr, create a space for the project and open a tab named **`coordinator`** running `claude`
   in the main checkout. Alternatively, label any coordinator terminal `overseer.role=coordinator`.
2. Ask for work as usual. The skill loads automatically for substantial tasks. Before it launches
   anything, it shows a launch table (worker · lane · task · branch).
3. You're interrupted only for `ACTION:` lines (a trust prompt, a decision). Otherwise you see the
   round results: what changed, what was verified, what's open.

Check the launcher without starting anything:

```sh
~/.claude/skills/herdr-overseer/scripts/launch-worker.sh --dry-run --name test --cwd ~/some/repo --task hello
```

## Safety notes

- Write-capable agy workers run with `--dangerously-skip-permissions` by default
  (`AGY_SKIP_PERMISSIONS=1`). Their worktree is the only boundary, so never point one at your main
  checkout.
- Read-only workers (`--read-only`) get Claude's `Edit`, `Write`, `NotebookEdit` and `Bash` hard-blocked,
  agy's plan mode, or opencode's plan agent.
- Workers never push or merge. The coordinator integrates.

## License

MIT
