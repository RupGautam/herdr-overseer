#!/usr/bin/env bash
# install.sh — install herdr-overseer.
#
#   ./install.sh [--dest DIR] [--coordinator claude-code|other] [--link] [--dry-run]
#
#   --dest DIR       where the skill goes. Default: ~/.claude/skills/herdr-overseer when the coordinator is
#                    Claude Code, else ~/.herdr-overseer. Agents with a skills folder can use theirs.
#   --coordinator    claude-code (default if `claude` is installed): adds the SessionStart hook that loads
#                    handoffs to ~/.claude/settings.json. other: no hook; see SETUP.md "Coordinator".
#   --link           symlink instead of copy (for working on this repo)
#   --dry-run        show what would change
#
# Safe to re-run: config/overseer.env and state/ are kept; settings.json is backed up before a change.
set -euo pipefail

SRC="$(cd "$(dirname "$0")" && pwd)/skill/herdr-overseer"
COORD="" DEST="" LINK=0 DRY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --dest) DEST="${2/#\~/$HOME}"; shift 2 ;;
    --coordinator) COORD="${2:-}"; shift 2 ;;
    --link) LINK=1; shift ;;
    --dry-run) DRY=1; shift ;;
    -h|--help) sed -n 2,14p "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done
[ -n "$COORD" ] || { command -v claude >/dev/null && COORD=claude-code || COORD=other; }
case "$COORD" in claude-code|other) ;; *) echo "--coordinator must be claude-code or other" >&2; exit 2 ;; esac
if [ -z "$DEST" ]; then
  if [ "$COORD" = claude-code ]; then DEST="$HOME/.claude/skills/herdr-overseer"; else DEST="$HOME/.herdr-overseer"; fi
fi
DEST="${DEST%/}"
say() { printf '%s\n' "$*"; }
run() { if [ "$DRY" -eq 1 ]; then say "  [dry-run] $*"; else "$@"; fi; }

say "== Prerequisites"
for c in hc herdr-app python3 git; do
  command -v "$c" >/dev/null && say "  ok       $c" || say "  MISSING  $c (required)"
done
command -v gh >/dev/null && say "  ok       gh" || say "  missing  gh (optional: PR steps)"
say "  Agent CLIs are whatever your lanes use; the launcher checks them per lane."

say "== Skill -> $DEST"
if [ "$LINK" -eq 1 ]; then
  if [ -e "$DEST" ] && [ ! -L "$DEST" ]; then
    BK="$DEST.backup-$(date +%Y%m%d-%H%M%S)"; run mv "$DEST" "$BK"; say "  moved existing install to $BK"
  fi
  run mkdir -p "$(dirname "$DEST")"; run ln -sfn "$SRC" "$DEST"; say "  linked"
else
  [ -L "$DEST" ] && run rm "$DEST"
  run mkdir -p "$DEST/config/worktree-include"
  for p in SKILL.md AGENT-NOTES.md scripts examples; do run rm -rf "${DEST:?}/$p"; run cp -R "$SRC/$p" "$DEST/$p"; done
  for f in overseer.env.example lanes.examples; do run cp "$SRC/config/$f" "$DEST/config/$f"; done
  for f in "$SRC"/config/worktree-include/*; do
    [ -e "$DEST/config/worktree-include/$(basename "$f")" ] || run cp "$f" "$DEST/config/worktree-include/"
  done
  say "  copied (config/overseer.env and state/ untouched)"
fi
run chmod +x "$SRC"/scripts/* "$SRC"/examples/*/*
if [ ! -f "$DEST/config/overseer.env" ]; then
  run cp "$SRC/config/overseer.env.example" "$DEST/config/overseer.env"
  say "  created config/overseer.env from the example: define your lanes, roles and routing (SETUP.md)"
fi
run mkdir -p "$DEST/state/handoffs"

if [ "$COORD" = claude-code ]; then
  SETTINGS="$HOME/.claude/settings.json"
  say "== Claude Code coordinator: SessionStart hook in $SETTINGS"
  if [ "$DRY" -eq 0 ]; then
    [ -f "$SETTINGS" ] && cp "$SETTINGS" "$SETTINGS.bak-herdr-overseer"
    python3 - "$SETTINGS" "$DEST/scripts/load-handoff.py" <<'EOF'
import json, os, sys
path, script = sys.argv[1], sys.argv[2]
home = os.path.expanduser("~")
cmd = "python3 " + ("~" + script[len(home):] if script.startswith(home + "/") else script)
s = json.load(open(path)) if os.path.exists(path) and os.path.getsize(path) else {}
arr = s.setdefault("hooks", {}).setdefault("SessionStart", [])
if any(h.get("command") == cmd for m in arr for h in m.get("hooks", [])):
    print("  already present")
else:
    arr.append({"matcher": "^(startup|resume|clear|compact)$",
                "hooks": [{"type": "command", "command": cmd, "timeout": 15}]})
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(s, f, indent=2)
    os.replace(tmp, path)
    print("  added")
EOF
  fi
else
  say "== Coordinator is not Claude Code: no hook installed."
  say "  Make your coordinator agent read $DEST/SKILL.md and run"
  say "  'python3 $DEST/scripts/load-handoff.py --print' at session start (SETUP.md, 'Coordinator')."
fi

say "Done. Next: define lanes/roles/routing in $DEST/config/overseer.env (SETUP.md), then verify (SETUP.md step 5)."
