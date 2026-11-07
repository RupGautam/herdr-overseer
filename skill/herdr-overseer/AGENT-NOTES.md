# Agent notes

Quirks of specific agent CLIs when they run as hc workers. Nothing in the scripts depends on this file.
The coordinator reads the entries for the agents its lanes use. Add an entry when you learn something
about another agent. Matching lane definitions are in `config/lanes.examples`.

## Claude Code (`claude`), used in practice

- **The task is a positional arg.** `--disallowedTools` is variadic, so always use the `=` form
  (`--disallowedTools=Edit,Write,NotebookEdit,Bash`). Otherwise it swallows the task as deny rules, and
  the screen shows `Permission deny rule "…" matches no known tool`. Read-only workers should also block
  Bash, because a project's `.claude/settings.local.json` may pre-approve it.
- **Separate accounts** are separate config dirs: `CLAUDE_CONFIG_DIR=…` through `STATIC_ENV`, or through
  an account switcher in `ENV_CMD`. Each config dir logs in once.
- **Folder trust** is recorded per config dir × **main git repo**. A worktree inherits trust from its main
  checkout, so the prompt appears at most once per account per repo. Check ahead with:
  `python3 -c 'import json;print(json.load(open("<CLAUDE_CONFIG_DIR>/.claude.json")).get("projects",{}).get("<abs repo>",{}).get("hasTrustDialogAccepted"))'`.
  To approve: `hc keys NAME enter` (option 1 is preselected).
- **"Claude in Chrome extension detected"** dialog: `hc keys NAME escape` keeps browser tools off.
- **Status:** hc reports status for claude workers even behind the `env` wrapper. `first_message` is not
  reported, because hc sees the agent as `env`.
- **Coordinator:** as a coordinator, Claude Code loads this skill natively, and `load-handoff.py` runs as
  its SessionStart hook. Its subscription prompt cache lasts 1 hour, which is what the 50-minute guard
  threshold is for.

## Antigravity CLI (`agy`), used in practice

- `agy --model M -i "TASK"` starts interactive with a first task. `-c` continues the last session.
- **Permission modes:** read-only uses `--mode plan`. `--mode auto` is not available on every account. The
  options are `--mode accept-edits` (asks for shell commands) or `--dangerously-skip-permissions` (asks
  nothing; the worktree is the only boundary).
- **Plan mode does not refuse writes, it asks** (probe, agy 1.5.2): asked to create a file, a `--mode plan`
  worker prepares the edit and shows "Allow creation of this file? 1. Yes / 2. No". A read-only agy worker
  that tries to write therefore stalls on a prompt until someone answers. Brief read-only agy workers not
  to write files, and answer such a prompt with *No*. **Escape interrupts the whole turn** ("What should
  Antigravity CLI do instead?"); after Escape, send a message telling it to continue without writing.
- **Folder trust is per exact path** (`trustedWorkspaces` in `~/.gemini/antigravity-cli/settings.json`).
  A worktree prompts even when its main repo is trusted. `examples/hooks/agy-trust-worktree.py` (a
  `WORKTREE_POST_CREATE` hook) trusts new worktrees of already-trusted repos.
- **Status:** it has reported `idle` right after launch, before its first turn starts (2026-11-03; not
  reproduced in the agy 1.5.2 probe, which showed no status, then `working`). Wait for `working` before
  waiting for `done`. It can report `done` while its own background job (a long build or e2e suite) is
  still running, and the 30-minute idle sweep would then kill that job. Brief agy workers to run long
  jobs in the foreground, or label them `overseer.hold=1`.

## opencode, used in practice

- **No model flag:** pass `OPENCODE_CONFIG_CONTENT={"model":"…","default_agent":"build"}`, with
  `plan` as the agent for read-only.
- **Always `--standalone`.** Without it, tools run in opencode's shared background service, outside the
  hc terminal.
- **`default_agent` matters** when a plugin (e.g. oh-my-opencode) would otherwise start an orchestrator
  agent that delegates to sub-agents.
- **`--prompt` auto-submits** the task. `-c` continues. There is no `--add-dir`.

## OpenAI Codex CLI (`codex`), flags from `--help` only (codex-cli 0.166)

- The prompt is positional. Model: `-m`. Approval: `-a never|on-request|…`. Sandbox:
  `-s read-only|workspace-write|danger-full-access`. Extra dirs: `--add-dir DIR`.
- **Always `--no-daemon`** (hc's own docs): without it, codex runs its tools in its shared background
  app-server, outside the hc terminal, so hc can't see or stop them. It applies to `resume` too.
- **Resume is a subcommand:** `codex resume --last [PROMPT]`, which is why lanes have a separate `RESUME_CMD`.
  Verify that `--last` picks the session of the worker's directory before relying on `--resume`.
- Custom agents and models are defined in `~/.codex/config.toml`. A lane can select one with `-c key=value`
  overrides, or with a separate `CODEX_HOME` in `STATIC_ENV`.
- **Folder trust prompt** (probe, codex-cli 0.166): in a git worktree, codex asks "Trust this folder? …
  Trusting will apply to the repository root: <main repo>", even with `[projects."/"] trust_level =
  "trusted"` in `~/.codex/config.toml`. One approval per main repo; ask the user.
- Probe results beyond the trust prompt: pending (see SETUP.md step 5).
