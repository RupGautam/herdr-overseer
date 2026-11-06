#!/usr/bin/env bash
# make-worktree.sh — create a worker worktree that can build and run immediately.
#   1. git worktree at ~/.herdr/worktrees/<Repo>/<name> on branch overseer/<name>, based on origin/main
#   2. node_modules cloned (APFS copy-on-write, macOS) from any checkout whose lockfile is identical
#   3. gitignored runtime files copied in from the main checkout. The list comes from
#      <repo>/.worktreeinclude or config/worktree-include/<Repo>. .env* files keep only the lines whose
#      variable name matches WORKTREE_PUBLIC_ENV_RE (config/overseer.env); never secrets.
#      Every copied file must be gitignored in the worktree, or it is removed again.
#   4. ~/.herdr/worktrees is kept out of Spotlight (.metadata_never_index)
#   5. optional post-create hooks (WORKTREE_POST_CREATE), e.g. pre-trusting the worktree in an agent CLI
#
# Usage: make-worktree.sh --repo /abs/repo --name task-name [--base origin/main]
set -euo pipefail

readonly SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
readonly WT_ROOT="$HOME/.herdr/worktrees"
WORKTREE_PUBLIC_ENV_RE=""
CONFIG="${OVERSEER_CONFIG:-$SKILL_DIR/config/overseer.env}"
# shellcheck source=/dev/null
[ -f "$CONFIG" ] && source "$CONFIG"

REPO="" NAME="" BASE="origin/main"
die() { echo "make-worktree: $*" >&2; exit 2; }

while [ $# -gt 0 ]; do
  case "$1" in
    --repo) REPO="${2:-}"; shift 2 ;;
    --name) NAME="${2:-}"; shift 2 ;;
    --base) BASE="${2:-}"; shift 2 ;;
    *) die "unknown argument: $1" ;;
  esac
done
[ -d "$REPO/.git" ] || [ -f "$REPO/.git" ] || die "--repo must be a git checkout"
[[ "$NAME" =~ ^[a-z0-9][a-z0-9_-]{0,40}$ ]] || die "--name must be lowercase a-z 0-9 - _"
REPO="$(cd "$REPO" && pwd)"
REPO_NAME="$(basename "$REPO")"

DEST="$WT_ROOT/$REPO_NAME/$NAME"
BRANCH="overseer/$NAME"
[ -e "$DEST" ] && die "already exists: $DEST"

mkdir -p "$WT_ROOT"
touch "$WT_ROOT/.metadata_never_index"

git -C "$REPO" fetch --quiet origin
git -C "$REPO" worktree add --quiet -b "$BRANCH" "$DEST" "$BASE"

# 2. Dependencies: clone node_modules from any checkout (main or another worktree) whose
#    lockfile is identical. That is safe because the same lockfile means the same dependency tree.
CHECKOUTS=()
while IFS= read -r l; do [ "${l%% *}" = "worktree" ] && CHECKOUTS+=("${l#worktree }"); done \
  < <(git -C "$REPO" worktree list --porcelain)
deps_note=()
while IFS= read -r lock; do
  rel="${lock#"$DEST"/}"; dir="$(dirname "$rel")"; done_dir=0
  for c in "${CHECKOUTS[@]}"; do
    [ "$c" = "$DEST" ] && continue
    if [ -d "$c/$dir/node_modules" ] && cmp -s "$c/$rel" "$lock"; then
      cp -cR "$c/$dir/node_modules" "$DEST/$dir/" && deps_note+=("$dir: cloned from ${c/#$HOME/~}") && done_dir=1
      break
    fi
  done
  [ "$done_dir" -eq 1 ] || deps_note+=("$dir: no checkout with this lockfile; run npm ci there")
done < <(find "$DEST" -maxdepth 2 -name package-lock.json -not -path '*/node_modules/*')

# 3. Runtime files from the repo's include list, verified gitignored inside the worktree.
LIST="$REPO/.worktreeinclude"
[ -f "$LIST" ] || LIST="$SKILL_DIR/config/worktree-include/$REPO_NAME"
copied=() placed=() labels=()
if [ -f "$LIST" ]; then
  while IFS= read -r rel || [ -n "$rel" ]; do
    rel="${rel%%#*}"; rel="$(echo "$rel" | xargs)"
    [ -z "$rel" ] && continue
    case "$rel" in /*|*..*) echo "make-worktree: skip $rel (must be a relative path inside the repo)" >&2; continue ;; esac
    [ -f "$REPO/$rel" ] || continue
    mkdir -p "$(dirname "$DEST/$rel")"
    case "$(basename "$rel")" in
      .env*)
        [ -n "$WORKTREE_PUBLIC_ENV_RE" ] || { copied+=("$rel: skipped (WORKTREE_PUBLIC_ENV_RE is empty)"); continue; }
        re="^[[:space:]]*(export[[:space:]]+)?${WORKTREE_PUBLIC_ENV_RE#^}"
        grep -Eq "$re" "$REPO/$rel" || continue
        grep -E "$re" "$REPO/$rel" > "$DEST/$rel"; chmod 600 "$DEST/$rel"
        labels+=("$rel (public keys only)") ;;
      *)
        cp "$REPO/$rel" "$DEST/$rel"; chmod 600 "$DEST/$rel"; labels+=("$rel") ;;
    esac
    placed+=("$rel")
  done < "$LIST"
fi
# placed[i] and labels[i] describe the same file; only files gitignored in the worktree are kept.
for i in ${placed[@]+"${!placed[@]}"}; do
  f="${placed[$i]}"
  if git -C "$DEST" check-ignore -q -- "$f"; then copied+=("${labels[$i]}"); continue; fi
  rm -f "$DEST/$f"
  echo "make-worktree: WARNING removed $f: not gitignored in $BRANCH (would be committable)" >&2
done

# 5. Optional post-create hooks (config WORKTREE_POST_CREATE: commands separated by ";"), each called as
#    <hook> <main repo> <worktree> <worktree root>, e.g. to pre-trust the worktree in an agent CLI.
#    See examples/hooks/. A failing hook is reported but does not undo the worktree.
hooks_note=()
IFS=';' read -r -a HOOKS <<< "${WORKTREE_POST_CREATE:-}"
for h in ${HOOKS[@]+"${HOOKS[@]}"}; do
  h="$(echo "$h" | xargs)"; [ -n "$h" ] || continue
  if out=$(bash -c "$h \"\$@\"" hook "$REPO" "$DEST" "$WT_ROOT" 2>&1); then hooks_note+=("${h##*/}: ${out:-ok}")
  else hooks_note+=("${h##*/}: FAILED ${out}"); fi
done

echo "worktree: $DEST"
echo "branch:   $BRANCH (from $BASE @ $(git -C "$DEST" rev-parse --short HEAD))"
printf 'deps:     %s\n' "${deps_note[@]:-none}"
printf 'config:   %s\n' "${copied[@]:-none}"
printf 'hooks:    %s\n' "${hooks_note[@]:-none}"
