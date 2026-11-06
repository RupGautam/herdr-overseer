# SETUP.md — instructions for an AI agent installing herdr-overseer

You are an AI coding agent. A user gave you this file so you can set up herdr-overseer for them,
using whatever agent CLIs and accounts they have and routing work the way they want. Follow this
file step by step. Ask the user wherever it says **Ask**. Don't guess their preferences.

## What it is (read first)

One agent session is the **coordinator**: it plans, splits work, reviews and integrates. It hands
tasks to **workers**, which are interactive CLI agents running in background terminals managed by
`hc` (from the Herdr app), each usually in its own git worktree. The coordinator follows
`skill/herdr-overseer/SKILL.md`.

### The architecture is fixed: do not change it

Configure only through `config/overseer.env` and the extension points below. Don't edit the scripts
or `SKILL.md`, and don't replace components. These parts stay exactly as they are:

1. Workers are started only by `scripts/launch-worker.sh` as `hc` terminals. They carry the labels
   `overseer.profile=<lane>`, `overseer.role=<role>` and `agent.account`, and the env `OVERSEER_ROLE=worker`.
   Every launch is logged in `state/workers.log`.
2. **Lanes:** a lane is one agent CLI + account + model, described by the lane template. The launcher
   rejects `--model`/`--effort`.
3. **Routing:** `--lane auto` picks a pool by role (`ROUTE_<role>` → `ROUTE_DEFAULT` → `LANES`), skips
   paused lanes (`state/lanes-paused`), then uses strict round-robin per pool, or `ROUTER_CMD`.
4. **Worktrees:** one per parallel code task, via `scripts/make-worktree.sh` (branch
   `overseer/<name>` under `~/.herdr/worktrees/<Repo>/`). Secrets never reach a worktree.
5. **Coordinator loop:** brief → wait (hc status, or the assembled `OVERSEER-DONE-N` marker) → read
   the real output → inspect the diff and run checks itself → peer review by a non-author →
   integrate → release.
6. **Release and resume:** `scripts/release-workers.py` (on acceptance, plus a 30-min idle sweep);
   `launch-worker.sh --resume` continues a worker's conversation.
7. **Handoffs:** `scripts/handoff-guard.py` asks an idle coordinator for a handoff;
   `scripts/load-handoff.py` loads the newest one into the next coordinator session.
8. **Safety rules:** never auto-accept folder-trust prompts; never print secrets; workers never push or
   merge; never stop the hc server or the Herdr app.

### What you configure (`config/overseer.env`, a bash file)

| Setting | Meaning |
|---|---|
| `LANES` | Lane names (A-Z 0-9 _), in default rotation order |
| `LANE_<name>_*` | The lane template (table below) |
| `ROLES` | Kinds of work the coordinator hands out, e.g. `impl review scout map explore` |
| `ROUTE_<role>`, `ROUTE_DEFAULT` | Which lanes each role may use (round-robin inside the pool) |
| `ROUTER_CMD` | Optional custom router script; replaces round-robin inside the pool |
| `MAX_PER_LANE`, `MAX_TOTAL` | Caps on live workers |
| `COORDINATOR_AGENTS` | hc agent names that may be the coordinator (for the handoff guard) |
| `WORKTREE_PUBLIC_ENV_RE` | Which `.env` variables may be copied into worktrees (public keys only) |
| `WORKTREE_POST_CREATE` | Commands run after a worktree is created (e.g. pre-trust it in an agent CLI) |

Lane template (the final command is `[RESUME_CMD|CMD] + [RO_ARGS|RW_ARGS] + add-dir args + TASK_FLAG + "<task>"`):

| Field | Type | Required | What to put there |
|---|---|---|---|
| `CMD` | array | yes | Command that starts the agent **interactively** in the current dir, with model and agent/profile pinned |
| `RESUME_CMD` | array | no | Command that continues the **most recent session in the current dir** |
| `RW_ARGS` | array | no | Args for write-capable workers (permission/approval/sandbox mode) |
| `RO_ARGS` / `RO_ENV` | array | no | How to make it read-only (plan mode, read-only sandbox, deny tools); omit both if impossible |
| `RW_ENV`, `STATIC_ENV` | array of `K=V` | no | Env per mode / for all workers (shown in `--dry-run`, so no secrets) |
| `ENV_CMD` | string | no | Command printing `export KEY='value'` lines (account switchers); values are hidden |
| `TASK_FLAG` | array | no | Flag before the task (`-i`, `--prompt`); empty = the task is the last positional arg |
| `ADD_DIR` | string | no | `"--add-dir"` (separate value) or `"--add-dir="` (joined); empty = unsupported |
| `ACCOUNT` | string | no | Label value for the account (default: the lane name) |
| `MODEL` | string | no | The model the lane must use (the watcher flags drift) |

## Step 1: inventory (no questions yet)

1. Check the required tools: `hc`, `herdr-app`, `python3` and `git` (plus `gh` if they use GitHub).
   If `hc` or `herdr-app` is missing, tell the user to install the Herdr app (https://herdr.dev) and stop.
2. List the agent CLIs installed on the machine, for example: `claude codex gemini agy opencode
   cursor-agent aider qwen kimi copilot droid amp goose crush`. Use `command -v` and `--version`.
3. For each one found, read `<cli> --help` and the help of any resume subcommand. Note:
   - how to start interactive with a first task;
   - how to pin the model, and any custom agent/profile;
   - permission/approval/sandbox modes;
   - a read-only mode;
   - how to continue the last session in the current dir;
   - extra-directory flags.
4. Read `skill/herdr-overseer/config/lanes.examples` and `AGENT-NOTES.md`. Prefer their definitions
   for the agents they cover, and re-check flags against the installed version.
5. Check `herdr integration status` if the `herdr` CLI exists. hc reports worker status best for agents
   whose integration is installed.

## Step 2: ask the user

**Ask** these questions, short and in one message, offering what you found as choices:

1. **Coordinator:** which agent plans and coordinates? Which project folder(s)?
2. **Workers:** which agents/accounts may do work? For each: the model, and any custom agent/profile.
   More accounts of the same CLI are separate lanes (separate config dirs or an account switcher).
3. **Roles and routing:** what kinds of work do they hand out, and which lanes should do each?
   Example: "planning stays with the Claude coordinator; implementation alternates between two Claude
   accounts; review, scouting, code mapping and exploration go to Codex custom agents." If they want
   something other than round-robin (least busy, by task keywords, cost-based), use a `ROUTER_CMD`.
4. **Permissions:** for write-capable workers, prompt-free (the worktree is the only boundary) or
   ask-on-risk? Which lanes may do read-only work?
5. **Worktree files:** which gitignored files does a project need in order to build (`.env`, Firebase
   configs, …)? Which `.env` variables are public?
6. **Caps:** how many live workers at once (default 5 per lane, 10 total)?

## Step 3: install

```sh
./install.sh --dry-run --coordinator <claude-code|other> [--dest DIR]
./install.sh            --coordinator <claude-code|other> [--dest DIR]
```

Below, `$OVERSEER` is the install dir it printed.

## Step 4: write `$OVERSEER/config/overseer.env`

- Start from `overseer.env.example`. Define one lane per (CLI, account, model/agent) the user wants.
  Arrays use bash syntax: `LANE_X_CMD=(codex -m some-model -a never)`. Quote values with spaces or
  JSON: `LANE_X_RW_ENV=('KEY={"a":1}')`.
- **Separate accounts:**
  - a config-dir env var in `STATIC_ENV`, e.g. `CLAUDE_CONFIG_DIR=$HOME/.claude-work` or `CODEX_HOME=$HOME/.codex-work`;
  - or an account switcher in `ENV_CMD`.
  
  Never put tokens in `STATIC_ENV`.
- **Custom agents/profiles** (e.g. Codex agents with their own models): pin them in `CMD` and
  `RESUME_CMD` with the CLI's own flags, so each lane is one fixed agent.
- `ROLES` = the user's kinds of work. `ROUTE_<role>` per role. Roles without a route use
  `ROUTE_DEFAULT`, else all lanes.
- A custom router: start from `$OVERSEER/examples/router/`. It must print one lane from
  `$OVERSEER_CANDIDATES`.
- Per-agent worktree needs (e.g. trusting each new worktree) go in `WORKTREE_POST_CREATE`. See
  `$OVERSEER/examples/hooks/`.
- Per project: list the runtime files in `<repo>/.worktreeinclude` (if the user wants it in the repo)
  or in `$OVERSEER/config/worktree-include/<RepoFolderName>`.

## Step 5: verify every lane and route (don't skip)

1. **Dry runs:** for each lane, run
   `"$OVERSEER/scripts/launch-worker.sh" --dry-run --lane <L> --name probe --cwd <repo> --task hi`.
   If the lane has read-only args, also try `--read-only`. Check that each command is exactly what
   that CLI expects.
2. **Routing:** for each role, run `--dry-run --role <role>` without `--lane`, and check that the lane
   is in that role's pool. Dry runs don't advance the rotation. To see rotation, explain it to the
   user, or do step 3 twice.
3. **Probe each lane once for real:** make a worktree
   (`make-worktree.sh --repo <repo> --name probe-<l>`), then launch
   `--lane <L> --read-only --name probe-<l> --cwd <worktree> --task "<question about the repo>. Then print the words OVERSEER, DONE and 1 joined with hyphens."`.
   Then:
   - Read the screen (`hc read --lines 0 probe-<l>`).
   - **Trust or login prompts: stop and ask the user.** Never accept trust yourself.
   - Wait with `hc wait probe-<l> --output OVERSEER-DONE-1 --timeout 300`.
   - Check `hc get probe-<l>` shows a sensible status.
   - Test resume: release it, then `--resume probe-<l> --task "...DONE and 2..."`.
   - Clean up: `release-workers.py --name probe-<l>`, `git worktree remove`, delete the `overseer/probe-*`
     branch.
   
   Fix the lane if anything fails, and record what you learned in `AGENT-NOTES.md`.
4. **Coordinator:** start a coordinator session in the project. With Claude Code, the handoff hook
   runs and the skill is available. Check that `hc ls` shows the `handoff-guard` terminal.

## Coordinator agents other than Claude Code

The coordinator needs to:
- follow `SKILL.md`;
- run shell commands (`hc`, the scripts);
- ideally load the last handoff at start.

For an agent without Claude-style skills:
- Add to the project's or the user's instruction file (e.g. `AGENTS.md`, `GEMINI.md`):
  `You are the herdr-overseer coordinator. Follow <OVERSEER>/SKILL.md. At session start run: python3 <OVERSEER>/scripts/load-handoff.py --print`.
  If the agent has a session-start hook, run that command there instead.
- Make sure its hc agent name is in `COORDINATOR_AGENTS` (see `hc ls --json`, field `agent`).
- Start the handoff guard once: `"$OVERSEER/scripts/start-guard.sh"`. `load-handoff.py` also starts it.
- Open the coordinator in a Herdr tab named `coordinator`, or label its terminal
  `hc label <addr> overseer.role=coordinator`.

## Step 6: report to the user

Keep it short:
- the lanes table (lane · CLI · account · model/agent · read-only? · resume?);
- the routing (role → pool, router);
- which probes passed;
- what they must do themselves (log in, approve trust, open the coordinator tab);
- how to pause a lane (`echo LANE >> $OVERSEER/state/lanes-paused`).
