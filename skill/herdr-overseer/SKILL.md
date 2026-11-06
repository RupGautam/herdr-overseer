---
name: herdr-overseer
description: Coordinator workflow for Claude Code with background workers. Use at the start of any coordinator session (e.g. a Herdr tab named 'coordinator') and for any substantial implementation, debugging, test-fix or multi-file task: delegate to background workers through hc (strict round-robin across the lanes in config/overseer.env), then validate, integrate and review. Do NOT use if you are yourself a worker, i.e. your task brief says no subagents/no other workers.
---

# herdr-overseer

The main conversation stays in **this** Claude Code session (the coordinator). Background workers
are interactive agent processes (Claude Code, Antigravity `agy`, or `opencode`) run by `hc`.
The user never needs to be inside a worker's terminal.

Configuration lives in `config/overseer.env` (copied from `config/overseer.env.example`): the
lanes, which agent and account each lane uses, the fixed models, and the caps. Read it at the start
of a session so you know the lane names.

## Standing workflow

**Coordinator (this session)** owns project understanding, planning, architecture, task
decomposition, integration and final review. Prioritize code health, maintainability, performance
and DX without breaking existing behavior. Do small edits yourself. Delegate substantial
implementation, debugging, test fixing and multi-file changes.

**Workers: lanes in strict round-robin.** Each lane is one agent type on one account, with a fixed
model; the launcher rejects `--model`/`--effort`:

| Lane type | Agent | Account | Model |
|---|---|---|---|
| `claude` | Claude Code | ccs profile `LANE_<name>_CCS` (empty = default login) | `CLAUDE_MODEL`, `CLAUDE_EFFORT` |
| `agy` | Antigravity CLI `agy` | its own Google login | `AGY_MODEL` |
| `opencode` | `opencode --standalone` | its own login | `OPENCODE_MODEL`, Build agent |

`--lane auto` (default) rotates through `LANES` in order, **skipping lanes listed in
`state/lanes-paused`** (one per line; to resume a lane, remove its line). The counter is
`state/next-lane-index`, advanced under a lock. Use an explicit `--lane` only to relaunch a worker
on its original lane. When a lane hits its quota (429 / "usage limit" / "monthly limit"), add it to
`lanes-paused` and tell the user. Caps: `MAX_PER_LANE` live per lane, `MAX_TOTAL` in total. Pick
concurrency from the task and the machine's load (`uptime`, cores, memory).

If a Claude lane uses the same account as the coordinator, its workers share the coordinator's
usage window. That is fine, but mention it when limits get close.

**Scope and review rules**
- **Launch only tasks the user approved.** If you think another task should run, propose it and
  wait for a yes. Don't add it to the batch on your own.
- **Reviewer tech-debt notes stay notes**, unless they are about security or production safety
  (prod data or services, credentials, destructive ops). Only those may be turned into fix
  requests, and you must say so in the report. Everything else goes into the final report's
  tech-debt list, and the code is left alone.
- **Small read-only checks** (does X exist on main, is Y in the build) are done by the
  coordinator itself, not by a worker.

**Round loop**
1. Tell the user the plan as the launch table (see "What the user sees"), then launch independent tasks in
   parallel.
2. Each brief covers: **objective, working directory, context, deliverable, completion
   criteria**, plus scope limits (no subagents, no other workers, stay in the worktree,
   don't push) and the assembled done-marker. Template below.
3. Parallel code changes each get their own git worktree and branch (section 2b).
4. Feedback goes to the **same worker** with `hc send` to continue its conversation. Don't
   relaunch unless it's dead.
5. When a worker reports done, **inspect the diff yourself** (`git -C WT diff main...HEAD`,
   `git -C WT status`), integrate, then run the builds, tests and lint yourself. A worker
   saying it's done is never proof.
6. After major changes, assign a **peer review** to a worker that didn't implement them.
   Prefer a different account when the rotation allows; otherwise use any non-author worker.
   It's read-only (`--read-only --role review`) and gets the reviewer rule below.
6b. After each integration, release accepted workers and run the 30-min idle sweep (section 8).
7. Finally, report to the user: the final result, **what was actually verified** (commands
   plus outcomes), and unresolved issues / tech-debt notes. Kill and remove finished workers.
   Keep their branches and worktrees until merged, plus `state/workers.log` and any
   reviewer notes.

**What the user sees (output discipline)**

The user reads your terminal like a dashboard, not a log. The work between you and the workers
stays out of their view: briefs, diffs, follow-ups and `hc` output are not narrated. Write
to the user only at these moments, in this shape:

- **Launch:** one table (worker · lane · task in under 10 words · worktree/branch) plus at most
  one line of plan. Don't restate the briefs; they are in `state/workers.log`.
- **Needs the user:** one line, starting `ACTION:`, saying what to do and where, e.g.
  `ACTION: approve the prompt in tab w-login · AGY`. Nothing else in that turn.
- **`<hc>` notes and wait results, when the user doesn't need to act:** handle them silently.
  If you must reply, reply in one line (`w-login done; reviewing.`). Never re-explain a worker's task.
- **Round result:** a short status table (worker · state · verified? · next), then what you
  verified (commands + pass/fail counts), open issues, and the next step. Aim for under 15 lines.
- **Final report:** as in step 7, but keep it to what changed, what was verified, what's
  unresolved and what the user should do. Leave out the history of how you got there.

Detail belongs in files the user can open on request: handoffs, PR descriptions,
`state/workers.log`. If the user asks "why" or "details", expand then.

**Task brief template**

```text
Role: You are a WORKER, not the coordinator. Do not load the herdr-overseer skill or start workers.
Objective: <one sentence>
Working directory: <abs worktree path> (branch <branch>). Work only here.
Context: <relevant files, decisions, constraints, how to run tests>
Deliverable: <code change / file at path / answer on screen>
Completion criteria: <tests that must pass, behavior to show>
Rules: no subagents, no other workers, don't push or merge, don't touch files outside scope.
Commit your work on the branch with conventional commit messages.
When done or stuck, summarize what changed and how you verified it, then on its own final
line print the words OVERSEER, DONE and <N> joined with hyphens.
```

**Reviewer rule (paste verbatim into review briefs)**

```text
Focus exclusively on blocking logic errors, edge-case failures, or architectural flaws.
If an issue is minor or non-blocking, just log it as a technical debt note and leave the
code alone.
```

Review workers are read-only and report on screen as two lists: BLOCKING (file:line, failure
scenario) and TECH-DEBT notes. The coordinator validates each blocking claim before acting
on it, then sends the fix feedback to the original implementer.

## Sources of truth

- `hc --skill` and `herdr-app --skill`: re-read these if behavior seems to differ. They are
  newer than the web docs.
- Official docs: https://herdr.dev/docs/ and https://herdr.dev/agent-guide.md. These cover
  the older `herdr` TUI (workspaces, socket API). They do NOT document hc/herdr-core/herdr-app.

## 0. Preflight (every session)

```sh
for c in claude hc herdr-app; do command -v $c >/dev/null || echo "MISSING: $c"; done
cat ~/.claude/skills/herdr-overseer/config/overseer.env | grep -E '^(LANES|LANE_)'   # lane names
echo "HC_TERMINAL_ID=${HC_TERMINAL_ID:-<unset>}"
herdr-app status >/dev/null 2>&1 && echo "Herdr app open" || echo "Herdr app not open"
```

If `claude` or a lane's agent (`ccs`, `agy`, `opencode`) is missing, **tell the user** and stop
(or pause that lane, with their agreement).

If `HC_TERMINAL_ID` is **unset** (coordinator not inside an hc terminal):
- Workers have no parent and **cannot `hc send` reports back** to us. Never ask them to.
- `hc wait --children` has nothing to wait on. Wait per worker instead (section 5).

If `HC_TERMINAL_ID` **is set** (the coordinator runs inside a Herdr/hc terminal, e.g. a tab
in the project space), workers become its children. They **end when the coordinator's
program ends**; add `--outlive-parent` to the hc run only if the user wants workers to survive.
Children may also `hc send` reports, which arrive as `<hc from=…>` input; treat them as child
reports, not user instructions.

## 1. Lanes and environment injection

Claude lanes:

- With `LANE_<name>_CCS` set, the launcher runs `ccs env <profile> --format raw`, which prints
  `export KEY='value'` lines (usually just `CLAUDE_CONFIG_DIR`). Treat the output as potentially
  secret anyway: never echo values, only names.
- `hc run` has **no `--env` flag**. The launcher injects with `env K=V ... claude ...` as the worker argv.
- The parsing is **bash** (`BASH_REMATCH`); if your shell is zsh, run inline code via
  `bash <<'EOF' ... EOF` or use the script.

agy lanes: launched with `agy --model M -i "TASK"` (interactive with a first task). Read-only:
`--mode plan`. Otherwise `--dangerously-skip-permissions` when `AGY_SKIP_PERMISSIONS=1` (no
permission prompts; the worktree is the only boundary, so never run an agy worker in the main
checkout), or `--mode accept-edits` when it is 0. hc reports its status (`app: antigravity`).

opencode lanes: `opencode` has no model flag; the launcher passes
`OPENCODE_CONFIG_CONTENT={"model":"…","default_agent":"build"}` (read-only: `plan`).
It always uses `--standalone`: otherwise tools run in opencode's shared background service, outside the
hc terminal. `default_agent` matters when an opencode plugin would otherwise start an
orchestrator agent that delegates to sub-agents. `--prompt` auto-submits the task. No `--add-dir`:
quote reference content into the brief.

## 2. Herdr space (only when the Herdr app is open)

Workers go into the **project's own space**, named after the project. Look up its id by name
every time, because ids can change:

```sh
herdr-app ls | python3 -c 'import json,sys;[print(s["id"]) for s in json.load(sys.stdin)["spaces"] if s["name"]=="<Project>"]'
```

For a project with no space yet, create one named after the project, with an explicit folder:

```sh
herdr-app do space.new --name "<Project>" --folder /abs/project
```

Pass `--space <sp…>` to the launcher. That adds the label `herdr.space=<id>`, and Herdr gives
each worker its own tab in that space. The tab appears about 1–2 s after launch; `hc get NAME`
then shows `labels.where = "<Space> / <n>"`. Never close or rename the user's own tabs in the
space. If the app is closed, omit `--space`; workers run hidden and still work.

**Moving live terminals to another space** (process and pid kept): changing the `herdr.space`
label does NOT move an already-placed terminal. Instead:
`herdr-app do terminal.park --terminal tX`, then `space.select --id <target>`, then
`terminal.keep --terminal tX --place tab`. Spaces have no "set folder" command; to change a
folder, create a new space with `--folder`, move the terminals over this way, and the
old space disappears once it's empty. Then rename/reorder with `tab.rename` (empty name =
its number), `tab.move`, `space.rename` and `space.move`. Check `keep` is still true with `hc get`.

## 2b. Worktrees for parallel code changes

Always use the helper:

```sh
~/.claude/skills/herdr-overseer/scripts/make-worktree.sh --repo /abs/repo --name fix-login [--base origin/main]
```

It does five things:
1. Creates `~/.herdr/worktrees/<Repo>/<name>` on branch `overseer/<name>`, based on a freshly
   fetched `origin/main`. The user's main checkout may be behind; don't base work on it.
2. Clones `node_modules` (APFS copy-on-write, about a second) from any checkout or worktree with an
   identical lockfile. Otherwise it says to run `npm ci` there.
3. Copies the gitignored runtime files listed in `<repo>/.worktreeinclude` or
   `config/worktree-include/<Repo>`. `.env*` files keep only the variables matching
   `WORKTREE_PUBLIC_ENV_RE`; secrets never reach a worktree. Any copied file that isn't gitignored
   in the worktree is removed again.
4. Keeps `~/.herdr/worktrees` out of Spotlight (`.metadata_never_index`).
5. Auto-trusts the worktree in agy if the main repo is already agy-trusted (see section 4).

Integrate by reviewing, then merging or cherry-picking into the target branch yourself. Remove a
worktree only after its branch is merged (`git worktree remove …`), and keep the branch until
the user is done with it.

## 3. Start a worker

Always use a unique name and an explicit absolute `--cwd`:

```sh
~/.claude/skills/herdr-overseer/scripts/launch-worker.sh \
  --name impl-login --cwd ~/.herdr/worktrees/Repo/impl-login --role impl \
  --space "$SPACE_ID" \
  --task "$BRIEF"
# reviewer:  --role review --read-only
```

`--lane` defaults to `auto` (round-robin). The chosen lane is printed on stderr. With `--space`,
the launcher also names the worker's tab `<name> · <lane>`, so the Herdr sidebar shows names
instead of `Space · 3` duplicates in the status groups. `--add-dir DIR`
(repeatable; Claude and agy lanes) grants read access to reference folders outside the worktree,
which avoids the "read outside the working directories" prompt. Every launch is appended to
`state/workers.log` (time, address, name, lane, role, cwd, task).
`--dry-run` prints the exact hc command with env values redacted and doesn't advance the
rotation. For a Claude lane it resolves to:

```sh
hc run --bg --json --name NAME --cwd DIR --label overseer.profile=<LANE> --label agent.account=<ACCOUNT> \
  --label overseer.role=impl --label herdr.space=SP \
  -- env OVERSEER_ROLE=worker CLAUDE_CONFIG_DIR=… claude --model <CLAUDE_MODEL> --effort <CLAUDE_EFFORT> \
     --disallowedTools=Edit,Write,NotebookEdit,Bash "TASK"
```

Labels: `overseer.profile` (the lane), `overseer.role`, and `agent.account` (the lane's
`LANE_<name>_ACCOUNT`, for Herdr mods that show which account a worker uses). `OVERSEER_ROLE=worker`
tells hooks that the session is a worker.

Hard-won rules:
- The task is a **positional CLI arg**, so it can't be dropped while Claude boots.
  `first_message` is not reported because hc sees the agent as `env`.
- `--disallowedTools` is **variadic**. `--disallowedTools Edit Write "TASK"` swallows the
  task as deny rules (screen shows `Permission deny rule "…" matches no known tool`).
  Always use the `=` comma form. `--read-only` also hard-blocks Bash, which a project's
  `.claude/settings.local.json` might otherwise pre-approve.
- If your Claude profiles default to auto permission mode, scope write-capable tasks tightly.
- Workers must not start subagents or other workers unless explicitly assigned.

## 4. First-run dialogs (check right after launch)

```sh
hc wait NAME --output "trust this folder" --timeout 30 >/dev/null 2>&1
hc read --lines 0 NAME | tail -30
```

1. **Folder trust** ("Is this a project you created or one you trust?"). It's recorded per
   Claude config dir (ccs profile) × **main git repo**: a worktree inherits trust from its main
   checkout. So it appears at most once per profile per repo; check ahead with
   `python3 -c 'import json;print(json.load(open("<CLAUDE_CONFIG_DIR>/.claude.json")).get("projects",{}).get("<abs folder>",{}).get("hasTrustDialogAccepted"))'`.
   **Do not auto-accept. Tell the user** which folder and profile it is, and which pre-approved
   permissions the dialog lists. Only after they approve: `hc keys NAME enter` (option 1 is
   preselected). If they decline: `hc kill NAME; hc rm NAME`.
2. **"Claude in Chrome extension detected"**: `hc keys NAME escape` keeps browser tools off.
   Workers don't need them.
3. **agy folder trust** ("Do you trust the contents of this project?"). Antigravity's own trust is
   separate from Claude's and **per exact folder** (`trustedWorkspaces` in
   `~/.gemini/antigravity-cli/settings.json`); a worktree prompts even when its main repo is trusted.
   `make-worktree.sh` therefore adds each new worktree to `trustedWorkspaces` when its main repo is
   already trusted there, and prunes entries for deleted worktrees. So agy workers in such
   worktrees start without a prompt. For a repo agy hasn't trusted, the prompt still appears: ask
   the user first, then `hc keys NAME enter`.

Re-read the screen after each key until it shows `✳ Processing…` or the prompt with the task.

## 5. Wait

**Primary signal: hc status** (works for claude, agy and opencode workers). hc reports
`status.state` (`working`, `done`, `idle`, `blocked`, `error`), plus a one-line `msg`, and
wakes the coordinator when a child stops or blocks. When the coordinator runs in a Herdr tab,
workers are its children, so prefer:

```sh
hc wait --children any              # next worker news; re-wait on reason:"timeout"
hc get NAME                         # status.state + status.msg
```

`blocked` means a prompt is waiting (permission, trust): read the screen and handle it per
section 4.
**Gotcha:** right after a launch or `--resume`, an agy worker reports `idle` before its first turn
starts, so `hc wait NAME` returns at once. Wait until `hc get` shows `working` (or use the
marker) before waiting for `done`. **Gotcha 2:** agy may report `done` while its own background
job (a long build or test suite) is still running. Brief agy workers to run long jobs in the
foreground, or label them `overseer.hold=1` so the idle sweep leaves them alone.

**Fallback: the output marker**, for when status is missing or you need to know that a specific
turn finished:

```sh
hc wait NAME --output "OVERSEER-DONE-1" --timeout 600   # reason:"output" = done
```

- `--output` matches only output printed **after** the wait starts. Start it immediately after
  launching or sending. If it times out (`reason:"timeout"`), check `hc read` before
  re-waiting, because the marker may already have printed.
- **Never put the literal marker in the prompt.** The echoed prompt would match on follow-up
  turns. Ask the worker to *assemble* it ("print the words OVERSEER, DONE and N joined with
  hyphens") and use a new N each turn.
- Run long waits with a Bash timeout above hc's `--timeout`. Don't sleep-poll.
- If the screen shows a permission prompt or question, the worker is blocked. Show the user;
  don't force through.

## 6. Read the result

```sh
hc read --lines 200 NAME | grep -v '^\s*$' | tail -120
```

Quote the worker's actual text from the screen before summarizing. Never infer success.
For long outputs (write-capable workers only), have the worker write to a file and read
that file. Read-only workers (`--read-only`) must answer on screen.

## 7. Follow-up turns

```sh
hc send NAME "Next task … final line: the words OVERSEER, DONE and 2 joined with hyphens." >/dev/null
hc wait NAME --output "OVERSEER-DONE-2" --timeout 600
```

`hc interrupt NAME` stops a turn without killing the worker.

## 8. Release

A worker's DONE means its **turn** ended, not that the work is accepted. Keep it alive while
follow-ups are likely, and release it as soon as they aren't. Releasing frees memory (a few hundred
MB per worker) and never loses work: the worktree, branch, conversation and log all remain.

```sh
R=~/.claude/skills/herdr-overseer/scripts/release-workers.py
$R --name w-login              # 1. on acceptance: you merged it or opened its PR and ran your checks
$R --idle-min 30               # 2. safety net: the handoff guard runs this every minute (automatic);
                               #    you may also run it after integrating
hc label w-login overseer.hold=1   # keep a done worker out of the sweep while a follow-up is planned
                                   # (also when your own review of it will take longer than 30 min)
```

- Only launcher-labelled workers are touched. `working`/`blocked` workers are never released.
- Each release is logged in `state/workers.log` (`RELEASED`).
- **Reopen with context:** `launch-worker.sh --resume w-login --task "FOLLOW-UP" --space SP`.
  It uses the same lane, worktree, role and read-only setting (from the log), and continues the
  worker's last conversation in that worktree (`claude --continue` / `agy -c` / `opencode -c`).
  It doesn't use a rotation turn. Prefer this to a fresh worker for any late fix round.
- Remove a worktree only after its branch is merged (`git worktree remove …`), and keep the branch
  until the user is done with it. Only release workers you (this coordinator) started.
- Never stop or restart the hc server or the Herdr app.

## 8b. Handoff (automatic, before the prompt cache goes cold)

The coordinator's prompt cache lasts 1 hour on a subscription. Once it expires, the next turn re-reads the whole
context at full cost. The **handoff guard** (`scripts/handoff-guard.py`, hc terminal `handoff-guard`,
started by the SessionStart hook through `start-guard.sh`) watches every coordinator (label
`overseer.role=coordinator`, or a Herdr tab named `coordinator`). After **50 idle minutes**
(`--idle-min` / `HANDOFF_IDLE_MIN`), it sends one message starting with `[handoff-guard]`
that asks for a handoff file at a given path. It sends that once per idle stretch, and asks again
only after real work has happened.

**When you get that message:** start no work. Check live state (`hc ls`, `git -C REPO branch -vv`,
`git worktree list`, `gh pr list`, `tail state/workers.log`). Then write the file below, exactly
at the path given. Reply with only `HANDOFF WRITTEN <path>`. You can also write one yourself
whenever the user is leaving or before a risky step. Put it under
`state/handoffs/<Repo>/<YYYY-MM-DDTHH-MM-SS>-manual.md`.

**Loading:** `scripts/load-handoff.py` is a SessionStart hook (startup, resume, clear and compact).
It injects the newest handoff for the project, from either `state/handoffs/<Repo>/` or your own
`handoff*.md` notes in the project's auto-memory folder, into any non-worker session in the main checkout,
if the handoff is less than 7 days old. Workers (`OVERSEER_ROLE=worker`, set by
`launch-worker.sh`) and worktree sessions are skipped. Treat a loaded handoff as a starting point
and re-verify live state before acting on it.

Handoff template. Be specific: names, paths, commands, numbers. The next coordinator has nothing
else to go on.

```markdown
# Coordinator handoff: <Repo> — <date time>
## 1. Goal and user intent
What the user asked for, in their words where possible; scope limits; what "done" means.
## 2. Decisions and standing instructions from this session
Each decision with its reason; user approvals and refusals; preferences stated.
## 3. Workers
| name | lane | role | status | worktree | branch | task (1 line) | result / verified? |
Include released ones from this session and how to --resume them.
## 4. Integration state
Branches merged, PRs open (number, title, CI, review state), what you verified yourself (commands + results), what is NOT verified.
## 5. In flight / blocked
Anything running (builds, tests, workers mid-turn), with how to check it. Blockers and who must act.
## 6. Next steps (ordered)
Exactly what the next coordinator should do first, second, third; include ready-to-run commands.
## 7. Open questions for the user
## 8. Tech-debt notes and risks
## 9. Gotchas learned this session
Tool quirks, flaky tests, env/secrets locations (never the secret values), rate limits, lane health.
## 10. Key files and references
Paths touched, docs, issue/PR links.
```

## 9. Watching a run (separate session, on request)

When the user asks another session to "watch" the coordinator, run the watcher as a background
monitor (re-arm it if it expires):

```sh
OVERSEER_REPO=/abs/main/checkout python3 -u ~/.claude/skills/herdr-overseer/scripts/watch.py   # one line per event
```

It reports new and gone terminals, launches and lane rotation, policy breaks (worker without
launcher labels, wrong model/effort, implementation in the main checkout, consecutive same-lane
launches, caps), trust/permission/Chrome prompts, real rate-limit/auth/API errors, stalls (10 min
with no screen change while working), the coordinator's hc commands, its context and 5h usage
thresholds, main-checkout edits, and load above 12. Everything is appended to
`state/observations.log`; write findings for the next revision into `state/retro-notes.md`.
Report setup and workflow health only, not the coding work.

## Checklist

- [ ] Preflight: claude, hc and the lanes' agents installed (tell the user if not); note HC_TERMINAL_ID
- [ ] Space found or created, if the app is open
- [ ] Worker launched through launch-worker.sh with an explicit name and cwd
- [ ] Trust/Chrome dialogs handled (trust only with user approval)
- [ ] Waited on status or an assembled marker, read the real output, quoted it
- [ ] Project untouched for read-only work (`git status --porcelain` unchanged)
- [ ] Workers released once results are accepted
