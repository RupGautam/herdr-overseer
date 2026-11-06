#!/usr/bin/env python3
"""release-workers.py: free finished herdr-overseer workers. Their worktrees, branches and logs are kept.

Two modes (the coordinator runs both; see SKILL.md "Release"):
  release-workers.py --name w-a [--name w-b]   # on acceptance: release these workers now
  release-workers.py --idle-min 30             # safety net: release workers done/idle >= 30 min

Only terminals launched by launch-worker.sh (label overseer.profile) are touched. Workers that are
working or blocked are never released. A worker labelled overseer.hold=1 is skipped by the idle sweep
(set with `hc label NAME overseer.hold=1` while a follow-up is planned). Releases are appended to
state/workers.log. Reopen a released worker with: launch-worker.sh --resume NAME --task "..."
"""
import argparse
import json
import os
import subprocess
import sys
import time

STATE = os.path.expanduser("~/.claude/skills/herdr-overseer/state")
LOG = os.path.join(STATE, "workers.log")
RELEASABLE = {"done", "idle"}


def hc(*args):
    out = subprocess.run(["hc", *args], capture_output=True, text=True, timeout=30)
    if out.returncode != 0:
        raise RuntimeError(f"hc {' '.join(args)} failed: {out.stderr.strip()[:200]}")
    return out.stdout


def workers():
    """Live terminals launched by launch-worker.sh, with labels, status and idle age."""
    found = []
    for t in json.loads(hc("ls", "--json"))["terminals"]:
        try:
            g = json.loads(hc("get", t["address"]))
        except (RuntimeError, json.JSONDecodeError) as err:
            print(f"skip {t['address']}: {err}", file=sys.stderr)
            continue
        labels = g.get("labels") or {}
        if not labels.get("overseer.profile"):
            continue
        status = g.get("status") or {}
        state = status.get("state") if isinstance(status, dict) else status
        since = g.get("status_ms")
        idle_min = (time.time() * 1000 - since) / 60000 if since else None
        found.append({"addr": g["address"], "name": g.get("name") or g["address"], "state": state,
                      "idle_min": idle_min, "lane": labels.get("overseer.profile"),
                      "hold": labels.get("overseer.hold") == "1", "cwd": g.get("cwd", "")})
    return found


def release(w, reason, dry):
    verb = "would release" if dry else "released"
    if not dry:
        hc("kill", w["addr"])
        hc("rm", w["addr"])
        with open(LOG, "a") as f:
            f.write(f"{time.strftime('%Y-%m-%dT%H:%M:%S')}\t{w['addr']}\t{w['name']}\t{w['lane']}\tRELEASED\t{w['cwd']}\t{reason}\n")
    print(f"{verb} {w['name']} ({w['addr']}, {w['lane']}): {reason}")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--name", action="append", default=[], help="release this worker (accepted work)")
    ap.add_argument("--idle-min", type=float, help="release workers done/idle at least this many minutes")
    ap.add_argument("--dry-run", action="store_true")
    a = ap.parse_args()
    if not a.name and a.idle_min is None:
        ap.error("give --name and/or --idle-min")
    ws = workers()
    by_name = {w["name"]: w for w in ws}
    for n in a.name:
        w = by_name.get(n)
        if w is None:
            print(f"not a live overseer worker: {n}", file=sys.stderr)
        elif w["state"] not in RELEASABLE:
            print(f"kept {n}: status {w['state']} (only done/idle workers are released)", file=sys.stderr)
        else:
            release(w, "accepted", a.dry_run)
    if a.idle_min is not None:
        for w in ws:
            if w["name"] in a.name or w["state"] not in RELEASABLE:
                continue
            if w["hold"]:
                print(f"kept {w['name']}: on hold")
            elif w["idle_min"] is not None and w["idle_min"] >= a.idle_min:
                release(w, f"{w['state']} for {w['idle_min']:.0f} min", a.dry_run)


if __name__ == "__main__":
    try:
        main()
    except RuntimeError as err:
        sys.exit(f"release-workers: {err}")
