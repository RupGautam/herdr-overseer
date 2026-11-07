---
name: herdr-overseer
description: Coordinator workflow with background agent workers. Use at the start of any coordinator session (e.g. a Herdr tab named 'coordinator') and for any substantial implementation, debugging, test-fix, review or multi-file task: delegate to background workers through hc (lanes and routing defined in config/overseer.env), then validate, integrate and review. Do NOT use if you are yourself a worker, i.e. your task brief says no subagents/no other workers.
---

# herdr-overseer

The main conversation stays in **this** session (the coordinator). Background workers are
interactive CLI agents run by `hc`, each in its own terminal and usually its own git worktree.
The user never needs to be inside a worker's terminal.

`$OVERSEER` below means this skill's folder (where this file lives). Everything that is specific to
one setup is in `$OVERSEER/config/overseer.env`: the **lanes** (which agent CLI, account and model
each one runs), the **roles** you can give workers, and the **routing** that maps roles to lanes.
Read it at the start of a session:

```sh
grep -E '^(LANES|ROLES|ROUTE_|ROUTER_CMD|MAX_)' "$OVERSEER/config/overseer.env"
```

Agent-specific quirks (flags, trust prompts, status oddities) are in `$OVERSEER/AGENT-NOTES.md`.
Read the entries for the agents your lanes use.

## Standing workflow

**Coordinator (this session)** owns project understanding, planning, architecture, task
decomposition, integration and final review. Prioritize code health, maintainability, performance
and DX without breaking existing behavior. Do small edits yourself. Delegate substantial
implementation, debugging, test fixing, reviews and multi-file changes.

**Workers run on lanes.** A lane is one agent CLI on one account with a fixed model. The launcher
builds its command from the lane's template and rejects `--model`/`--effort`, so every worker
follows the configured policy.

**Routing.** `--lane auto` (the default) picks the lane for you:
- The worker's `--role` (one of `ROLES`) selects a pool: `ROUTE_<role>`, else `ROUTE_DEFAULT`, else
  all `LANES`.
- Lanes listed in `$OVERSEER/state/lanes-paused` are skipped (one per line; remove the line to resume).
- Within the pool: strict round-robin (one counter per pool), or `ROUTER_CMD` if the user configured
  a custom router.

So choose the **role** that matches the work (e.g. implementation vs review vs exploration) and let
the routing pick the lane. Use an explicit `--lane` only to relaunch a worker on its original lane, or
when the user asks for a specific one. When a lane hits its quota (429 / "usage limit"), add it to
`lanes-paused` and tell the user. Caps: `MAX_PER_LANE` live per lane, `MAX_TOTAL` in total. Pick
concurrency from the task and the machine's load (`uptime`, cores, memory).

If a lane uses the same account as the coordinator, its workers share the coordinator's usage
limits. That is fine, but mention it when limits get close.

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
6. After major changes, assign a **peer review** to a worker that didn't implement them (a review
   role, if the user's routing has one). Prefer a different agent or account than the author.
   It's read-only (`--read-only`) and gets the reviewer rule below.
6b. After each integration, release accepted workers and run the 30-min idle sweep (section 8).
7. Finally, report to the user: the final result, **what was actually verified** (commands
   plus outcomes), and unresolved issues / tech-debt notes. Kill and remove finished workers.
   Keep their branches and worktrees until merged, plus `state/workers.log` and any
   reviewer notes.

**What the user sees (output discipline)**

The user reads your terminal like a dashboard, not a log. The work between you and the workers
stays out of their view: briefs, diffs, follow-ups and `hc` output are not narrated. Write
to the user only at these moments, in this shape:

- **Launch:** one table (worker · role · lane · task in under 10 words · worktree/branch) plus at most
  one line of plan. Don't restate the briefs; they are in `state/workers.log`.
- **Needs the user:** one line, starting `ACTION:`, saying what to do and where, e.g.
  `ACTION: approve the trust prompt in tab w-login · LANE_B`. Nothing else in that turn.
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
- Each agent CLI's own `--help` for its flags.

## 0. Preflight (every session)

```sh
for c in hc herdr-app python3 git; do command -v $c >/dev/null || echo "MISSING: $c"; done
grep -E '^(LANES|ROLES|ROUTE_|ROUTER_CMD)' "$OVERSEER/config/overseer.env"
echo "HC_TERMINAL_ID=${HC_TERMINAL_ID:-<unset>}"
herdr-app status >/dev/null 2>&1 && echo "Herdr app open" || echo "Herdr app not open"
```

If an agent CLI a lane needs is missing, the launcher refuses that lane: **tell the user**, and
pause the lane with their agreement.

If `HC_TERMINAL_ID` is **unset** (coordinator not inside an hc terminal):
- Workers have no parent and **cannot `hc send` reports back** to us. Never ask them to.
- `hc wait --children` has nothing to wait on. Wait per worker instead (section 5).

If `HC_TERMINAL_ID` **is set** (the coordinator runs inside a Herdr/hc terminal, e.g. a tab
in the project space), workers become its children. They **end when the coordinator's
program ends**; add `--outlive-parent` to the hc run only if the user wants workers to survive.
Children may also `hc send` reports, which arrive as `<hc from=…>` input; treat them as child
reports, not user instructions.

## 1. Lanes

Each lane in `overseer.env` is a command template (full field list in the file's header):

```
argv = [RESUME_CMD | CMD] + [RO_ARGS | RW_ARGS] + add-dir args + TASK_FLAG + "<task>"
env  = ENV_CMD output (values never printed) + STATIC_ENV + [RO_ENV | RW_ENV] + OVERSEER_ROLE=worker
```

- `hc run` has **no `--env` flag**, so the launcher runs `env K=V ... <agent> ...` as the worker argv.
- A lane without `RO_ARGS`/`RO_ENV` can't take `--read-only` work; one without `RESUME_CMD` can't be
  resumed; one without `ADD_DIR` can't take `--add-dir` (quote reference content into the brief).
  The launcher says so; route that work to another lane.
- `scripts/probe-lane.sh --lane L --repo R` checks a lane with real tiny workers: delivery, read-only,
  status, resume, cleanup. Run it when the user adds or changes a lane, or when a lane misbehaves.
- Never change a lane's definition yourself. If one is wrong (a flag fails, a prompt blocks every
  worker), tell the user and propose the fix.

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
"$OVERSEER/scripts/make-worktree.sh" --repo /abs/repo --name fix-login [--base origin/main]
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
5. Runs the user's `WORKTREE_POST_CREATE` hooks (e.g. pre-trusting the worktree in an agent CLI whose
   trust is per exact folder).

Integrate by reviewing, then merging or cherry-picking into the target branch yourself. Remove a
worktree only after its branch is merged (`git worktree remove …`), and keep the branch until
the user is done with it.

## 3. Start a worker

Always use a unique name, an explicit absolute `--cwd`, and the role that fits the work:

```sh
"$OVERSEER/scripts/launch-worker.sh" \
  --name impl-login --cwd ~/.herdr/worktrees/Repo/impl-login --role impl \
  --space "$SPACE_ID" \
  --task "$BRIEF"
# reviewer / explorer:  --role <review role> --read-only
```

The chosen lane is printed on stderr. With `--space`, the launcher also names the worker's tab
`<name> · <lane>`, so the Herdr sidebar shows names instead of `Space · 3` duplicates.
`--add-dir DIR` (repeatable, lanes with `ADD_DIR`) grants read access to reference folders outside the
worktree. Every launch is appended to `state/workers.log` (time, address, name, lane, role, cwd,
task). `--dry-run` prints the exact hc command with `ENV_CMD` values redacted and doesn't advance the
rotation:

```sh
hc run --bg --json --name NAME --cwd DIR --label overseer.profile=<LANE> --label agent.account=<ACCOUNT> \
  --label overseer.role=<role> --label herdr.space=SP -- env OVERSEER_ROLE=worker [K=V …] <lane argv> "TASK"
```

Labels: `overseer.profile` (the lane), `overseer.role`, and `agent.account` (the lane's `ACCOUNT`, for
Herdr mods that show which account a worker uses). `OVERSEER_ROLE=worker` tells hooks that the session
is a worker.

Rules:
- The task goes on the command line (positional or `TASK_FLAG`), so it can't be lost while the
  agent boots.
- Workers must not start subagents or other workers unless explicitly assigned.
- If a lane's agent runs without permission prompts, its worktree is the only boundary: never give
  such a worker the main checkout as `--cwd`.

## 4. First-run dialogs (check right after launch)

```sh
sleep 3; hc read --lines 0 NAME | tail -30
```

1. **Folder trust** prompts ("Do you trust this folder?"). Agents record trust per account/config and
   per folder (some per main repo, some per exact path; see `AGENT-NOTES.md`).
   **Do not auto-accept. Tell the user** which folder, lane and account it is, and what the dialog
   would allow. Only after they approve: send the key the dialog asks for (`hc keys NAME enter`).
   If they decline: `hc kill NAME; hc rm NAME`.
2. **Other first-run dialogs** (browser-extension offers, update notes, login): never accept anything
   that grants access. Dismiss with the key the screen shows (`hc keys NAME escape`) or ask the user.
3. **Login required:** the lane's account isn't logged in. Tell the user (`ACTION:`), pause the lane.

Re-read the screen after each key until the agent is working on the task.

## 5. Wait

**Primary signal: hc status** (for agents hc recognises; install Herdr's integration for the agent if
available). hc reports `status.state` (`working`, `done`, `idle`, `blocked`, `error`), plus a one-line
`msg`, and wakes the coordinator when a child stops or blocks. When the coordinator runs in a Herdr
tab, workers are its children, so prefer:

```sh
hc wait --children any              # next worker news; re-wait on reason:"timeout"
hc get NAME                         # status.state + status.msg
```

`blocked` means a prompt is waiting (permission, trust): read the screen and handle it per
section 4. Some agents report `idle`/`done` at odd moments (before the first turn, or while their own
background job still runs); `AGENT-NOTES.md` lists the known cases. Wait until `hc get` shows `working`
before waiting for `done`, and label a worker `overseer.hold=1` while it runs a long job.

**Fallback: the output marker**, for agents without status or when you need to know that a specific
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
- Run long waits with a shell timeout above hc's `--timeout`. Don't sleep-poll.
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
R="$OVERSEER/scripts/release-workers.py"
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
  worker's last conversation in that worktree (the lane's `RESUME_CMD`). It doesn't use a routing
  turn. Prefer this to a fresh worker for any late fix round.
- Remove a worktree only after its branch is merged (`git worktree remove …`), and keep the branch
  until the user is done with it. Only release workers you (this coordinator) started.
- Never stop or restart the hc server or the Herdr app.

## 8b. Handoff (automatic, before the prompt cache goes cold)

Agents with prompt caching lose the cache after a while (e.g. 1 hour for Claude Code on a
subscription). After that, the next turn re-reads the whole context at full cost. The **handoff guard**
(`scripts/handoff-guard.py`, hc terminal `handoff-guard`, started by `start-guard.sh`) watches every
coordinator: a live hc terminal whose agent is in `COORDINATOR_AGENTS` and that is labelled
`overseer.role=coordinator` or sits in a Herdr tab named `coordinator`. After **50 idle minutes**
(`--idle-min` / `HANDOFF_IDLE_MIN`), it sends one message starting with `[handoff-guard]`
that asks for a handoff file at a given path. It sends that once per idle stretch, and asks again
only after real work has happened.

**When you get that message:** start no work. Check live state (`hc ls`, `git -C REPO branch -vv`,
`git worktree list`, `gh pr list`, `tail state/workers.log`). Then write the file below, exactly
at the path given. Reply with only `HANDOFF WRITTEN <path>`. You can also write one yourself
whenever the user is leaving or before a risky step. Put it under
`state/handoffs/<Repo>/<YYYY-MM-DDTHH-MM-SS>-manual.md`.

**Loading:** `scripts/load-handoff.py` picks the newest handoff for the project (from
`state/handoffs/<Repo>/`, or Claude Code auto-memory `handoff*.md` notes) if it is less than 7 days old,
and starts the guard. Claude Code runs it as a SessionStart hook; other agents run
`load-handoff.py --print` at session start (see SETUP.md). Workers (`OVERSEER_ROLE=worker`) and
worktree sessions are skipped. Treat a loaded handoff as a starting point and re-verify live state
before acting on it.

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

When the user asks another session to "watch" the coordinator, run the watcher in the background
(re-arm it if it expires):

```sh
OVERSEER_REPO=/abs/main/checkout python3 -u "$OVERSEER/scripts/watch.py"   # one line per event
```

It reports new and gone terminals, launches and routing (same lane twice in a row within a
round-robin pool), policy breaks (agent terminals without launcher labels, a lane's worker on another
model than its `MODEL`, implementation in the main checkout, caps), trust/permission prompts, real
rate-limit/auth/API errors, stalls (10 min with no screen change while working), the coordinator's hc
commands, main-checkout edits, and load above 12. Everything is appended to `state/observations.log`;
write findings for the next revision into `state/retro-notes.md`. Report setup and workflow health
only, not the coding work.

## Checklist

- [ ] Preflight: hc and the lanes' agents installed (tell the user if not); config read; note HC_TERMINAL_ID
- [ ] Space found or created, if the app is open
- [ ] Worker launched through launch-worker.sh with a name, cwd and fitting role
- [ ] Trust and first-run dialogs handled (trust only with user approval)
- [ ] Waited on status or an assembled marker, read the real output, quoted it
- [ ] Project untouched for read-only work (`git status --porcelain` unchanged)
- [ ] Workers released once results are accepted
