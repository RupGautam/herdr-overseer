# Cold-start test

The proof that `SETUP.md` works for someone who isn't us: a different LLM, on a clean account, with no
help, reaches a passing conformance probe on every lane it configures. Nobody who built this may intervene
except to do what the LLM explicitly asks a human to do (log in, approve a trust prompt).

## Setup (about 15 minutes, once)

1. **A clean macOS user.** System Settings → Users & Groups → Add User ("coldstart", Standard). Log in
   as that user. Nothing from your own account (dotfiles, `~/.claude`, `~/.codex`, ccs, agy settings,
   Herdr config) may exist there. Check with:
   `ls -a ~ | grep -E '^\.(claude|codex|ccs|gemini|config)$'` (it should print nothing).
2. **Base tools only:** Homebrew, git, Python 3, `gh` (optional), and the Herdr app from https://herdr.dev.
   Open the app once.
3. **The agent CLIs to test**, installed but not configured. Use at least two different providers, e.g.
   `codex` and `claude`. For a full run add `agy` and `opencode`. Log each in **only when the installing
   LLM asks for it.**
4. **A small test repo with a remote:** any public repo cloned to `~/Code/<name>` with an `origin`, plus
   one gitignored file with a fake secret (`.env` with `PUBLIC_X=1` and `SECRET_X=do-not-copy`).
5. **The installing LLM:** a different agent than the one that built this, e.g. Codex CLI
   (`codex`) or Gemini, started in an empty folder.

## The test

Give the installing LLM exactly this, nothing more:

> Install herdr-overseer for me by following https://github.com/rupgautam/herdr-overseer/blob/main/SETUP.md.
> My project is ~/Code/<name>. Ask me anything you need.

Answer its questions as a new user would:
- Coordinator: Claude Code.
- Workers: Codex and Claude.
- Routing: `impl` on Claude, `review` and `scout` on Codex.
- Read-only allowed on all lanes.
- `PUBLIC_` variables are public.
- Default caps.

Do what it asks a human to do (logins, trust prompts), nothing else. Don't fix its mistakes; note them.

## What counts as a pass

All of these, checked by you after the LLM reports done:

| # | Check | How |
|---|---|---|
| 1 | Installed without hand edits by you | Your notes contain no "I fixed …" |
| 2 | Config expresses the requested routing | `grep -E '^(LANES\|ROLES\|ROUTE_)' <install>/config/overseer.env` |
| 3 | Routing works | `launch-worker.sh --dry-run --role review --name x --cwd ~/Code/<name> --task hi` picks a Codex lane; `--role impl` picks Claude |
| 4 | Every lane passes the probe | `scripts/probe-lane.sh --lane <L> --repo ~/Code/<name>` for each lane: C1–C4 and C6 PASS (C2/C4/C5 may be SKIP only for a lane that truly lacks the mode) |
| 5 | Secrets stay out of worktrees | `make-worktree.sh --repo ~/Code/<name> --name cs1`, then `cat ~/.herdr/worktrees/<name>/cs1/.env` shows `PUBLIC_X=1` only |
| 6 | Coordinator works | Open the coordinator in a Herdr tab named `coordinator`, ask for a tiny read-only review task, and see a launch table, a worker on the routed lane and a result table. `hc ls` shows `handoff-guard` |
| 7 | No trust prompt was accepted without you | The LLM's transcript shows it asked you each time |

Record: the time to a passing state, every point where the LLM stalled or guessed, and every question it
asked that SETUP.md should have answered. Each one becomes a SETUP.md fix.

## Cleanup

Log out, then delete the "coldstart" user (with its home folder). Nothing on your own account changed.
