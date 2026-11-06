#!/usr/bin/env python3
"""Overseer watcher (setup/workflow health; NOT for judging the coding work). v2: audits coordinator + workers + all live sessions. One line per notable event.
Events are also appended to state/observations.log for the retro.
Usage: OVERSEER_REPO=/abs/main/checkout python3 -u watch.py   (OVERSEER_REPO optional)"""
import json, os, re, subprocess, time, hashlib

POLL_S = 5
STALL_S = 600
SKILL = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
STATE = os.path.join(SKILL, "state")
WLOG, OBS = f"{STATE}/workers.log", f"{STATE}/observations.log"


def load_config(path):
    """KEY=value / KEY="value" lines of config/overseer.env (no shell evaluation)."""
    cfg = {}
    try:
        for line in open(path):
            m = re.match(r'\s*([A-Za-z_][A-Za-z0-9_]*)=(.*)$', line)
            if m:
                v = m.group(2).split(" #")[0].strip()
                cfg[m.group(1)] = v[1:-1] if len(v) > 1 and v[0] == v[-1] and v[0] in "\"'" else v
    except FileNotFoundError:
        pass
    return cfg


CFG = load_config(os.environ.get("OVERSEER_CONFIG", os.path.join(SKILL, "config", "overseer.env")))
LANE_NAMES = CFG.get("LANES", "").split()
LANE_MODEL = {l: CFG.get(f"LANE_{l}_MODEL", "") for l in LANE_NAMES}   # policy: model each lane must use
SHELLS = {"zsh", "bash", "sh", "fish", "python3", "python", "env", None}
MAX_PER_LANE = int(CFG.get("MAX_PER_LANE", 5))
# The main checkout to guard (impl workers must not run there; edits there are reported). Optional.
REPO = os.path.realpath(os.path.expanduser(os.environ["OVERSEER_REPO"])) if os.environ.get("OVERSEER_REPO") else None
PROMPTS = {
    "TRUST PROMPT": r"trust this folder",
    "CHROME PROMPT": r"Claude in Chrome extension detected",
    "RATE LIMIT": r"API Error: 429|rate_limit_error|You've hit your (?:session |5-hour |weekly )?limit|usage limit reached|limit reached \S* ?resets",
    "AUTH PROBLEM": r"Please run /login|Invalid API key|OAuth token (has )?expired|not logged in|authentication_error",
    "API ERROR": r"API Error|overloaded_error",
    "PERMISSION PROMPT": r"Do you want to (proceed|make this edit|create|run)",
    "DENY-RULE BUG": r"Permission deny rule .* matches no known tool",
    "CRASH": r"Traceback \(most recent|panicked at|Segmentation fault|FATAL",
}
os.makedirs(STATE, exist_ok=True)

def sh(*a, t=20):
    try: return subprocess.run(a, capture_output=True, text=True, timeout=t).stdout
    except Exception: return ""

def jget(*a):
    try: return json.loads(sh(*a))
    except Exception: return None

def emit(msg):
    line = f"{time.strftime('%H:%M:%S')} {msg}"
    print(line, flush=True)
    with open(OBS, "a") as f: f.write(time.strftime("%Y-%m-%d ") + line + "\n")

def stat(t):
    s = t.get("status")
    return s.get("state") if isinstance(s, dict) else s

known, info, hits, last_change, cmd_seen, thresh = {}, {}, set(), {}, set(), set()
coord = None
g0 = sh("git", "-C", REPO, "status", "--porcelain") if REPO else ""
wl_n = sum(1 for _ in open(WLOG)) if os.path.exists(WLOG) else 0
last_lane_by_pool = {}
first = True

while True:
    d = jget("hc", "ls", "--json")
    if not d: time.sleep(POLL_S); continue
    cur = {t["address"]: t for t in d["terminals"]}
    for a, t in cur.items():
        if a not in info or not info[a].get("labels", {}).get("overseer.profile"):
            g = jget("hc", "get", a) or {}
            info[a] = {"labels": g.get("labels", {}), "argv": (g.get("foreground") or {}).get("argv") or g.get("argv") or [], "parent": g.get("parent")}
        lab, argv = info[a]["labels"], info[a]["argv"]
        if lab.get("where", "").endswith("/ coordinator") or (t.get("where") or "").endswith("/ coordinator"): coord = a
        if a not in known and not first:
            emit(f"NEW {a} agent={t.get('agent')} where={t.get('where')} cwd={t.get('cwd')} profile={lab.get('overseer.profile','-')} role={lab.get('overseer.role','-')} parent={info[a]['parent']}")
            joined = " ".join(argv)
            lane = lab.get("overseer.profile")
            if t.get("agent") not in SHELLS and a != coord and lab.get("overseer.role") not in ("coordinator", "guard"):
                if not lane:
                    emit(f"POLICY: {a} ({t.get('agent')}) looks like an agent started WITHOUT launch-worker.sh (no overseer.profile label) - round-robin/env injection bypassed?")
                m = re.search(r"(?:--model|-m)[ =](\S+)", joined)
                want = LANE_MODEL.get(lane or "", "")
                if want and m and m.group(1) != want:
                    emit(f"POLICY: {a} on lane {lane} uses model {m.group(1)}, lane policy is {want}")
            if REPO and lab.get("overseer.role") == "impl" and (t.get("cwd") or "").rstrip("/") == REPO:
                emit(f"POLICY: impl worker {a} runs in the MAIN checkout, not a worktree")
        elif a in known and stat(t) != stat(known[a]) and stat(t) in ("blocked", "error") :
            emit(f"STATUS {a} {stat(known[a])} -> {stat(t)} ({t.get('where')})")
        elif a in known and a == coord and stat(t) != stat(known[a]):
            emit(f"COORD {stat(known[a])} -> {stat(t)}")
    for a in set(known) - set(cur):
        emit(f"GONE {a} ({known[a].get('where')}, agent={known[a].get('agent')})")
    # screens
    now = time.time()
    for a, t in cur.items():
        scr = sh("hc", "read", "--lines", "0", a)
        if not scr: continue
        h = hashlib.md5(scr.encode()).hexdigest()
        prev = last_change.get(a)
        if not prev or prev[0] != h: last_change[a] = (h, now, False)
        elif info[a]["labels"].get("overseer.profile") and not prev[2] and now - prev[1] > STALL_S and stat(t) not in ("done", "idle") and "OVERSEER-DONE" not in scr:
            emit(f"STALL? worker {a} screen unchanged {int((now-prev[1])/60)}m ({t.get('where')})"); last_change[a] = (h, prev[1], True)
        for name, pat in PROMPTS.items():
            for m in set(re.findall(pat, scr, re.I)):
                key = (a, name, str(m).lower())
                if key in hits: continue
                hits.add(key)
                if not first: emit(f"{name} in {a} ({t.get('where')}): {m}")
        if a == coord:
            for c in re.findall(r"^\s*(?:⎿\s*)?\$ (hc (?:send|keys|kill|rm|interrupt|run)[^\n]{0,160})", scr, re.M):
                k = c.strip()
                if k not in cmd_seen:
                    cmd_seen.add(k)
                    if not first: emit(f"COORD CMD: {k}")
            if LANE_NAMES and re.search(r"--profile (" + "|".join(map(re.escape, LANE_NAMES)) + ")", scr) and "launch-worker" not in scr:
                k = ("manual-env", a)
                if k not in hits: hits.add(k); emit("POLICY: coordinator choosing lanes/profiles by hand instead of launch-worker.sh")
            usage = [(int(m.group(1)), "ctx") for m in re.finditer(r"(\d+)% \d+k/\dM", scr)]
            usage += [(int(m.group(1)), "5h") for m in re.finditer(r"5h (\d+)%", scr)]
            for p, kind in usage:
                for th in ((50, 75, 90) if kind == "ctx" else (70, 90)):
                    if p >= th and (kind, th) not in thresh:
                        thresh.add((kind, th))
                        if not first:
                            emit(f"COORD {'context' if kind == 'ctx' else 'main-account 5h usage'} at {p}% (>= {th}%)")
    # launches
    if os.path.exists(WLOG):
        lines = open(WLOG).read().splitlines()
        for l in lines[wl_n:]:
            f = l.split("\t")
            emit("LAUNCH " + " ".join(f[1:6]))
            if len(f) > 3:
                role = f[4] if len(f) > 4 else ""
                pool = (CFG.get(f"ROUTE_{role}") or CFG.get("ROUTE_DEFAULT") or " ".join(LANE_NAMES)).split()
                key = " ".join(pool)
                resumed = l.endswith("\tresumed")
                # Round-robin check: only when no custom router and the role's pool has several lanes.
                if not CFG.get("ROUTER_CMD") and len(pool) > 1 and role != "RELEASED" and not resumed:
                    if last_lane_by_pool.get(key) == f[3]: emit(f"ROUND-ROBIN? consecutive {role} launches on {f[3]} (pool: {key})")
                    last_lane_by_pool[key] = f[3]
        wl_n = len(lines)
    # per-profile cap
    cnt = {}
    for a in cur:
        p = info.get(a, {}).get("labels", {}).get("overseer.profile")
        if p: cnt[p] = cnt.get(p, 0) + 1
    for p, n in cnt.items():
        if n > MAX_PER_LANE and ("cap", p, n) not in hits: hits.add(("cap", p, n)); emit(f"CAP EXCEEDED {p}: {n}")
    g = sh("git", "-C", REPO, "status", "--porcelain") if REPO else ""
    if g != g0:
        emit("MAIN CHECKOUT changed: " + ", ".join(sorted(set(g.splitlines()) ^ set(g0.splitlines())))[:300]); g0 = g
    la = os.getloadavg()[0]
    if la > 12 and ("load",) not in hits: hits.add(("load",)); emit(f"HIGH LOAD {la:.1f}")
    if la < 8: hits.discard(("load",))
    if first:
        emit(f"watch v2 armed: {len(cur)} live terminals, coordinator={coord}, all screens scanned (existing prompts baselined)")
        first = False
    known = cur
    time.sleep(POLL_S)
