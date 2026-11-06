#!/usr/bin/env python3
"""load-handoff.py: SessionStart hook. Loads the newest coordinator handoff for this project into the session.

Runs on startup, resume, clear and compact. Skips workers (OVERSEER_ROLE=worker, or a cwd under
~/.herdr/worktrees) and handoffs older than MAX_AGE_DAYS. It also makes sure the handoff guard is running
(scripts/start-guard.sh). It never fails the session: every error just means no handoff gets loaded.
"""
import json
import os
import re
import subprocess
import sys
import time

SKILL = os.path.expanduser("~/.claude/skills/herdr-overseer")
HANDOFF_ROOT = os.path.join(SKILL, "state", "handoffs")
WORKTREE_ROOT = os.path.realpath(os.path.expanduser("~/.herdr/worktrees"))
MAX_AGE_DAYS = 7
MAX_CHARS = 40000


def project_slug(cwd):
    try:
        common = subprocess.run(["git", "-C", cwd, "rev-parse", "--path-format=absolute", "--git-common-dir"],
                                capture_output=True, text=True, timeout=5).stdout.strip()
        if common:
            return os.path.basename(os.path.dirname(common))
    except (OSError, subprocess.TimeoutExpired):
        pass
    return os.path.basename(os.path.normpath(cwd))


def memory_dir(cwd):
    """Claude Code's auto-memory folder for this project (where coordinators also write handoff-*.md notes)."""
    return os.path.join(os.path.expanduser("~/.claude/projects"), re.sub(r"[^A-Za-z0-9]", "-", cwd), "memory")


def newest_handoff(slug, cwd):
    """Newest non-empty handoff: guard-requested (state/handoffs/<Repo>/*.md) or self-written (memory/handoff*.md)."""
    files = []
    d = os.path.join(HANDOFF_ROOT, slug)
    if os.path.isdir(d):
        files += [os.path.join(d, f) for f in os.listdir(d) if f.endswith(".md")]
    m = memory_dir(cwd)
    if os.path.isdir(m):
        files += [os.path.join(m, f) for f in os.listdir(m) if f.startswith("handoff") and f.endswith(".md")]
    files = [f for f in files if os.path.getsize(f) > 0]
    return max(files, key=os.path.getmtime) if files else None


def start_guard():
    try:
        subprocess.Popen([os.path.join(SKILL, "scripts", "start-guard.sh")], stdout=subprocess.DEVNULL,
                         stderr=subprocess.DEVNULL, start_new_session=True)
    except OSError:
        pass


def main():
    if os.environ.get("OVERSEER_ROLE") == "worker":
        return
    try:
        hook = json.load(sys.stdin)
    except (json.JSONDecodeError, ValueError):
        hook = {}
    cwd = os.path.realpath(hook.get("cwd") or os.getcwd())
    if cwd.startswith(WORKTREE_ROOT + os.sep):
        return
    start_guard()
    path = newest_handoff(project_slug(cwd), cwd)
    if not path:
        return
    age_h = (time.time() - os.path.getmtime(path)) / 3600
    if age_h > MAX_AGE_DAYS * 24:
        return
    with open(path, errors="replace") as f:
        body = f.read()
    cut = len(body) > MAX_CHARS
    if cut:
        body = body[:MAX_CHARS]
    age = f"{age_h * 60:.0f} min" if age_h < 1 else f"{age_h:.1f} h"
    context = (
        f"COORDINATOR HANDOFF (loaded by the herdr-overseer SessionStart hook; written {age} ago; file: {path}).\n"
        "This is the previous coordinator session's state. Treat it as your starting point, but verify live "
        "state (hc ls, git, gh) before acting on it; anything may have changed since it was written.\n"
        + ("[Truncated here; read the file for the rest.]\n" if cut else "")
        + "\n" + body
    )
    print(json.dumps({
        "systemMessage": f"Loaded coordinator handoff ({age} old): {os.path.basename(path)}",
        "hookSpecificOutput": {"hookEventName": "SessionStart", "additionalContext": context},
    }))


if __name__ == "__main__":
    try:
        main()
    except Exception as err:  # a hook must never break session start
        print(f"load-handoff: {err}", file=sys.stderr)
    sys.exit(0)
