#!/usr/bin/env bash
# install.sh — install the herdr-overseer skill for Claude Code.
#
#   ./install.sh [--link] [--dry-run]
#
#   --link     symlink the skill instead of copying it (for working on this repo)
#   --dry-run  show what would change
#
# Installs to ~/.claude/skills/herdr-overseer, creates config/overseer.env from the example if missing,
# and adds the SessionStart hook (scripts/load-handoff.py) to ~/.claude/settings.json.
# Safe to re-run: your config, run state and other hooks are kept; replaced files are backed up first.
set -euo pipefail

SRC="$(cd "$(dirname "$0")" && pwd)/skill/herdr-overseer"
DEST="$HOME/.claude/skills/herdr-overseer"
SETTINGS="$HOME/.claude/settings.json"
LINK=0 DRY=0
for a in "$@"; do
  case "$a" in
    --link) LINK=1 ;; --dry-run) DRY=1 ;;
    -h|--help) sed -n 2,11p "$0"; exit 0 ;;
    *) echo "unknown option: $a" >&2; exit 2 ;;
  esac
done
say() { printf '%s\n' "$*"; }
run() { if [ "$DRY" -eq 1 ]; then say "  [dry-run] $*"; else "$@"; fi; }

say "== Prerequisites"
for c in claude hc herdr-app python3 git; do
  command -v "$c" >/dev/null && say "  ok       $c" || say "  MISSING  $c (required)"
done
for c in ccs agy opencode gh; do
  command -v "$c" >/dev/null && say "  ok       $c" || say "  missing  $c (only needed by lanes/steps that use it)"
done

say "== Skill -> $DEST"
if [ "$LINK" -eq 1 ]; then
  if [ -e "$DEST" ] && [ ! -L "$DEST" ]; then
    BK="$DEST.backup-$(date +%Y%m%d-%H%M%S)"; run mv "$DEST" "$BK"; say "  moved existing install to $BK"
  fi
  run mkdir -p "$(dirname "$DEST")"; run ln -sfn "$SRC" "$DEST"; say "  linked"
else
  [ -L "$DEST" ] && run rm "$DEST"
  run mkdir -p "$DEST"
  for p in SKILL.md scripts; do run rm -rf "$DEST/$p"; run cp -R "$SRC/$p" "$DEST/$p"; done
  run mkdir -p "$DEST/config/worktree-include"
  run cp "$SRC/config/overseer.env.example" "$DEST/config/"
  for f in "$SRC"/config/worktree-include/*; do
    [ -e "$DEST/config/worktree-include/$(basename "$f")" ] || run cp "$f" "$DEST/config/worktree-include/"
  done
  say "  copied (config/overseer.env and state/ untouched)"
fi
run chmod +x "$SRC"/scripts/*.sh "$SRC"/scripts/*.py
if [ ! -f "$DEST/config/overseer.env" ]; then
  run cp "$SRC/config/overseer.env.example" "$DEST/config/overseer.env"
  say "  created config/overseer.env from the example: edit it (lanes, ccs profiles, models)"
fi
run mkdir -p "$DEST/state/handoffs"

say "== SessionStart hook in $SETTINGS"
if [ "$DRY" -eq 0 ]; then
  [ -f "$SETTINGS" ] && cp "$SETTINGS" "$SETTINGS.bak-herdr-overseer"
  python3 - "$SETTINGS" <<'EOF'
import json, os, sys
path = sys.argv[1]
s = json.load(open(path)) if os.path.exists(path) and os.path.getsize(path) else {}
cmd = "python3 ~/.claude/skills/herdr-overseer/scripts/load-handoff.py"
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

say "== Herdr status integrations (optional)"
if command -v herdr >/dev/null; then say "  run: herdr integration install claude   (and opencode, if you use it)"
else say "  install the herdr CLI to get agent status in Herdr: herdr integration install claude"; fi

say "Done. Next: edit $DEST/config/overseer.env, then see README.md 'Set up accounts'."
