#!/usr/bin/env python3
"""handoff-guard.py: (1) release workers done/idle 30+ min (OVERSEER_SWEEP_IDLE_MIN); (2) ask an idle coordinator to write a detailed handoff while its prompt cache is still warm.

Claude Code on a subscription keeps the main conversation's prompt cache for 1 hour. A coordinator that
sits idle longer loses it, and the next turn re-reads the whole context at full price. Shortly before that,
this guard sends the coordinator one prompt asking it to write a handoff (SKILL.md "Handoff"). The next
session in that project loads the newest handoff through the SessionStart hook (scripts/load-handoff.py).

A coordinator is an hc terminal labelled overseer.role=coordinator, or one whose Herdr tab is named
"coordinator". It is asked at most once per idle stretch: no new request until it has done real work again.

  handoff-guard.py                 # loop forever (run via start-guard.sh as hc terminal "handoff-guard")
  handoff-guard.py --once          # one pass, then exit (testing)
  handoff-guard.py --idle-min 0.5  # threshold in minutes (default 50, for the 1 h cache)
  handoff-guard.py --once --idle-min 0 --only t9z   # test against one coordinator
"""
import argparse
import json
import os
import re
import subprocess
import sys
import time

SKILL = os.path.expanduser("~/.claude/skills/herdr-overseer")
STATE_FILE = os.path.join(SKILL, "state", "handoff-guard.json")
HANDOFF_ROOT = os.path.join(SKILL, "state", "handoffs")
LOG = os.path.join(SKILL, "state", "observations.log")
IDLE_STATES = {"idle", "done"}
DEFAULT_IDLE_MIN = 50.0
POLL_SECONDS = 60
SWEEP_IDLE_MIN = float(os.environ.get("OVERSEER_SWEEP_IDLE_MIN", 30))
RELEASE = os.path.join(SKILL, "scripts", "release-workers.py")


def hc(*args):
    out = subprocess.run(["hc", *args], capture_output=True, text=True, timeout=30)
    if out.returncode != 0:
        raise RuntimeError(f"hc {' '.join(args)}: {out.stderr.strip()[:200]}")
    return out.stdout


def log(msg):
    line = f"{time.strftime('%Y-%m-%d %H:%M:%S')} HANDOFF-GUARD {msg}"
    print(line, flush=True)
    with open(LOG, "a") as f:
        f.write(line + "\n")


def load_state():
    try:
        with open(STATE_FILE) as f:
            return json.load(f)
    except (FileNotFoundError, json.JSONDecodeError):
        return {}


def save_state(state):
    tmp = STATE_FILE + ".tmp"
    with open(tmp, "w") as f:
        json.dump(state, f, indent=1)
    os.replace(tmp, STATE_FILE)


def project_slug(cwd):
    """Main-repo folder name, so worktrees and subfolders map to the same project."""
    try:
        common = subprocess.run(["git", "-C", cwd, "rev-parse", "--path-format=absolute", "--git-common-dir"],
                                capture_output=True, text=True, timeout=10).stdout.strip()
        if common:
            return os.path.basename(os.path.dirname(common))
    except (OSError, subprocess.TimeoutExpired):
        pass
    return os.path.basename(os.path.normpath(cwd)) or "unknown"


def coordinators():
    found = []
    for t in json.loads(hc("ls", "--json"))["terminals"]:
        if t.get("state") != "live" or t.get("agent") != "claude-code":
            continue
        where = t.get("where") or ""
        try:
            g = json.loads(hc("get", t["address"]))
        except (RuntimeError, json.JSONDecodeError):
            continue
        labels = g.get("labels") or {}
        if labels.get("overseer.role") != "coordinator" and not re.search(r"/ coordinator$", where):
            continue
        status = g.get("status") or {}
        found.append({"addr": g["address"], "cwd": g.get("cwd") or t.get("cwd") or "",
                      "state": status.get("state") if isinstance(status, dict) else status,
                      "since_ms": g.get("status_ms"), "turn": g.get("turn") or t.get("turn") or 0,
                      "where": where})
    return found


def recent_memory_handoff(cwd, since_ms):
    """A handoff the coordinator already wrote itself in its project memory during/after its last turn."""
    mem = os.path.join(os.path.expanduser("~/.claude/projects"), re.sub(r"[^A-Za-z0-9]", "-", cwd), "memory")
    if not os.path.isdir(mem):
        return None
    files = [os.path.join(mem, f) for f in os.listdir(mem) if f.startswith("handoff") and f.endswith(".md")]
    newest = max(files, key=os.path.getmtime, default=None)
    if newest and os.path.getmtime(newest) * 1000 >= since_ms - 15 * 60000:
        return newest
    return None


def request_text(path):
    return (
        "[handoff-guard] You have been idle for a while and your prompt cache expires soon. "
        "Do not start or resume any work. Write the coordinator handoff now, following the "
        "\"Handoff\" section of the herdr-overseer skill (re-read that section first), to this exact file: "
        f"{path} . Check live state (hc ls, git status/branches, gh pr list) instead of relying on memory. "
        f"Then reply with one line only: HANDOFF WRITTEN {path}"
    )


def check(c, state, idle_min, now_ms):
    key = c["addr"]
    rec = state.get(key, {})
    if rec.get("path") and not rec.get("reported") and c["state"] == "error" and not os.path.exists(rec["path"]):
        # e.g. usage limit hit: the cache is cold by the time it resets, so a retry would cost a full re-read.
        rec["reported"] = True
        log(f"{key} ({c['where']}): handoff request FAILED (status error, often a usage limit); no file at "
            f"{rec['path']}. Not retrying. The latest memory handoff, if any, still applies.")
        return
    if c["state"] not in IDLE_STATES or not c["since_ms"]:
        return
    idle = (now_ms - c["since_ms"]) / 60000
    if idle < idle_min:
        return
    # The handoff turn itself adds one turn; wait for real work before asking again.
    if rec.get("sent_turn") is not None and c["turn"] <= rec["sent_turn"] + 1:
        return
    own = recent_memory_handoff(c["cwd"], c["since_ms"])
    if own:
        state[key] = {"sent_turn": c["turn"] - 1, "skipped_for": own}
        log(f"{key} ({c['where']}) idle {idle:.0f} min: it already wrote {own}; not asking")
        return
    slug = project_slug(c["cwd"])
    out_dir = os.path.join(HANDOFF_ROOT, slug)
    os.makedirs(out_dir, exist_ok=True)
    path = os.path.join(out_dir, time.strftime("%Y-%m-%dT%H-%M-%S") + f"-{key}.md")
    try:
        hc("send", key, request_text(path))
    except RuntimeError as err:
        log(f"{key} ({c['where']}): send failed: {err}")
        return
    state[key] = {"sent_turn": c["turn"], "sent_at": time.strftime("%Y-%m-%dT%H:%M:%S"), "path": path}
    log(f"{key} ({c['where']}) idle {idle:.0f} min, turn {c['turn']}: asked for handoff -> {path}")


def sweep_workers():
    """Release overseer workers that have been done/idle >= SWEEP_IDLE_MIN (skips overseer.hold=1).
    Records and worktrees stay; reopen with launch-worker.sh --resume NAME."""
    out = subprocess.run([sys.executable, RELEASE, "--idle-min", str(SWEEP_IDLE_MIN)],
                         capture_output=True, text=True, timeout=120)
    for line in (out.stdout + out.stderr).splitlines():
        if line.startswith(("released", "release-workers:")):
            log(f"sweep: {line}")


def one_pass(idle_min, only=None):
    state = load_state()
    now_ms = time.time() * 1000
    live = set()
    for c in coordinators():
        live.add(c["addr"])
        if only is None or only == c["addr"]:
            check(c, state, idle_min, now_ms)
    save_state({k: v for k, v in state.items() if k in live})


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--idle-min", type=float, default=float(os.environ.get("HANDOFF_IDLE_MIN", DEFAULT_IDLE_MIN)))
    ap.add_argument("--once", action="store_true")
    ap.add_argument("--only", help="testing: act on this coordinator address only")
    a = ap.parse_args()
    os.makedirs(HANDOFF_ROOT, exist_ok=True)
    log(f"armed: idle threshold {a.idle_min} min")
    while True:
        try:
            one_pass(a.idle_min, a.only)
            if not a.only:
                sweep_workers()
        except (RuntimeError, json.JSONDecodeError, OSError, subprocess.TimeoutExpired) as err:
            log(f"pass failed: {err}")
        if a.once:
            return
        time.sleep(POLL_SECONDS)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        sys.exit(0)
