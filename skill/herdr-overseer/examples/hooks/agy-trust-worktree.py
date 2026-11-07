#!/usr/bin/env python3
"""WORKTREE_POST_CREATE hook for the Antigravity CLI (agy): trust a new worktree when its main repo is trusted.

agy's folder trust is per exact path (trustedWorkspaces in ~/.gemini/antigravity-cli/settings.json), so every
new worktree would prompt. This adds the worktree only if the main repo is already trusted, and prunes entries
for deleted worktrees under the worktree root. Untrusted repos are left alone, so agy still asks.

Usage (set in config/overseer.env):  WORKTREE_POST_CREATE=("python3 /abs/path/agy-trust-worktree.py")
Called as: <hook> <main repo> <new worktree> <worktree root>
"""
import json, os, sys, tempfile
repo, dest, root = (os.path.realpath(a) for a in sys.argv[1:4])
p = os.path.expanduser("~/.gemini/antigravity-cli/settings.json")
if not os.path.isfile(p):
    print("skipped (agy not configured)"); sys.exit()
d = json.load(open(p))
tw = d.get("trustedWorkspaces")
if not isinstance(tw, list):
    print("skipped (no trustedWorkspaces list)"); sys.exit()
keep = [w for w in tw if not (isinstance(w, str) and os.path.realpath(w).startswith(root + os.sep) and not os.path.isdir(w))]
pruned = len(tw) - len(keep)
trusted = {os.path.realpath(w) for w in keep if isinstance(w, str)}
if repo not in trusted:
    msg = "not added (main repo not trusted in agy; agy will ask)"
elif dest in trusted:
    msg = "already trusted"
else:
    keep.append(dest); msg = "added (main repo is trusted)"
if keep != tw:
    d["trustedWorkspaces"] = keep
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(p))
    with os.fdopen(fd, "w") as f: json.dump(d, f, indent=2); f.write("\n")
    os.replace(tmp, p)
print(msg + (f"; pruned {pruned} stale" if pruned else ""))
