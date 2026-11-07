#!/usr/bin/env python3
"""release-workers.py: free finished herdr-overseer workers. Their worktrees, branches and logs are kept.

Two modes (the coordinator runs both; see SKILL.md "Release"):
  release-workers.py --name w-a [--name w-b]   # on acceptance: release these workers now
  release-workers.py --idle-min 30             # safety net: release workers done/idle >= 30 min

Only terminals launched by launch-worker.sh (label overseer.profile) are touched. Workers that are
working or blocked are never released, and neither are workers whose background processes are busy:
some agents report done/idle while a job they started (a build, a test suite) is still running, and
releasing them would kill it. Busy = the worker's descendant processes (not the agent process itself)
used >= BUSY_CPU (default 20%) of a core over a SAMPLE_S (2 s) window. --force skips that check for --name. A worker labelled overseer.hold=1 is skipped by the idle sweep
(set with `hc label NAME overseer.hold=1` while a follow-up is planned). Releases are appended to
state/workers.log. Reopen a released worker with: launch-worker.sh --resume NAME --task "..."
"""
import argparse
import json
import os
import subprocess
import sys
import time

STATE = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "state")
LOG = os.path.join(STATE, "workers.log")
RELEASABLE = {"done", "idle"}
BUSY_CPU = float(os.environ.get("OVERSEER_BUSY_CPU", 0.2))      # fraction of one core
SAMPLE_S = float(os.environ.get("OVERSEER_BUSY_SAMPLE_S", 2))


def cpu_seconds(text):
    """ps TIME ([[dd-]hh:]mm:ss[.ss]) -> seconds."""
    days = 0
    if "-" in text:
        d, text = text.split("-", 1); days = int(d)
    parts = [float(x) for x in text.split(":")]
    secs = 0.0
    for x in parts:
        secs = secs * 60 + x
    return days * 86400 + secs


def process_table():
    rows = subprocess.run(["ps", "-axo", "pid=,ppid=,time="], capture_output=True, text=True).stdout.split("\n")
    table = {}
    for r in rows:
        f = r.split()
        if len(f) == 3:
            table[f[0]] = (f[1], cpu_seconds(f[2]))
    return table


def background_cpu(table, root, exclude):
    """CPU seconds used so far by all descendants of `root`, minus the `exclude` pids (shell, agent)."""
    kids = {}
    for pid, (ppid, _) in table.items():
        kids.setdefault(ppid, []).append(pid)
    total, todo = {}, list(kids.get(root, []))
    while todo:
        p = todo.pop()
        if p not in exclude:
            total[p] = table[p][1]
        todo.extend(kids.get(p, []))
    return total


def busy_workers(ws):
    """{addr: cpu_fraction} for workers whose background processes are busy. One shared sample window."""
    roots = {w["addr"]: (w["pid"], {w["pid"], w["fg_pid"]}) for w in ws if w.get("pid")}
    if not roots:
        return {}
    t0 = process_table()
    before = {a: background_cpu(t0, r, ex) for a, (r, ex) in roots.items()}
    time.sleep(SAMPLE_S)
    t1 = process_table()
    busy = {}
    for a, (r, ex) in roots.items():
        after = background_cpu(t1, r, ex)
        used = sum(v - before[a].get(p, 0.0) for p, v in after.items())
        if used / SAMPLE_S >= BUSY_CPU:
            busy[a] = used / SAMPLE_S
    return busy


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
        fg = g.get("foreground") or {}
        found.append({"addr": g["address"], "name": g.get("name") or g["address"], "state": state,
                      "idle_min": idle_min, "lane": labels.get("overseer.profile"),
                      "hold": labels.get("overseer.hold") == "1", "cwd": g.get("cwd", ""),
                      "pid": str(g["pid"]) if g.get("pid") else None,
                      "fg_pid": str(fg["pid"]) if fg.get("pid") else None})
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
    ap.add_argument("--force", action="store_true", help="--name only: release even if background processes are busy")
    a = ap.parse_args()
    if not a.name and a.idle_min is None:
        ap.error("give --name and/or --idle-min")
    ws = workers()
    by_name = {w["name"]: w for w in ws}
    named, swept = [], []
    for n in a.name:
        w = by_name.get(n)
        if w is None:
            print(f"not a live overseer worker: {n}", file=sys.stderr)
        elif w["state"] not in RELEASABLE:
            print(f"kept {n}: status {w['state']} (only done/idle workers are released)", file=sys.stderr)
        else:
            named.append(w)
    if a.idle_min is not None:
        for w in ws:
            if w["name"] in a.name or w["state"] not in RELEASABLE:
                continue
            if w["hold"]:
                print(f"kept {w['name']}: on hold")
            elif w["idle_min"] is not None and w["idle_min"] >= a.idle_min:
                swept.append(w)
    busy = busy_workers([w for w in named if not a.force] + swept)
    for w in named:
        if w["addr"] in busy:
            print(f"kept {w['name']}: background processes busy ({busy[w['addr']]:.0%} CPU); "
                  "wait for the job or use --force", file=sys.stderr)
        else:
            release(w, "accepted", a.dry_run)
    for w in swept:
        if w["addr"] in busy:
            print(f"kept {w['name']}: {w['state']} but background processes busy ({busy[w['addr']]:.0%} CPU)")
        else:
            release(w, f"{w['state']} for {w['idle_min']:.0f} min", a.dry_run)


if __name__ == "__main__":
    try:
        main()
    except RuntimeError as err:
        sys.exit(f"release-workers: {err}")
