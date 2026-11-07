#!/usr/bin/env bash
# tests/sandbox.sh — env for an isolated live-test sandbox: a separate hc session (own terminal server, socket
# and state under /tmp/ovsb) and a separate Herdr app home. Your normal hc terminals and app are untouched.
# Agent logins and configs (HOME, ~/.config) are shared on purpose: probes use your real accounts and agent
# settings. Only hc runtime/state/data paths and the Herdr app home are separate.
#
#   eval "$(tests/sandbox.sh)"          # this shell now talks to the sandbox hc session
#   herdr-app &                         # optional: a second Herdr window with its own config (HERDR_APP_HOME)
#   tests/sandbox.sh --stop             # end the sandbox: kills only processes whose sockets live in /tmp/ovsb
#
# Paths are short on purpose: macOS limits socket paths to 103 bytes.
set -euo pipefail
R=/tmp/ovsb
if [ "${1:-}" = --stop ]; then
  # Never `hc server stop` here: if the env were wrong it would hit the user's real core. Instead, find the
  # processes that hold sockets under $R (only the sandbox core does) and end those.
  pids=$(lsof -U 2>/dev/null | awk -v r="$R/" 'index($0, r) {print $2}' | sort -u)
  for p in $pids; do
    lsof -p "$p" -U 2>/dev/null | grep -q "$R/" && kill "$p" 2>/dev/null || true
  done
  rm -rf "$R"; echo "sandbox removed${pids:+ (ended pid(s) $(echo $pids | tr '\n' ' '))}"; exit 0
fi
mkdir -p "$R"/{run,state,data,app}; chmod 700 "$R/run"
# The sandbox hc server starts on the first hc call and its terminals inherit this shell's environment.
# Clear agent-session markers (e.g. when run from inside Claude Code) so workers behave as in a clean setup.
markers=$(env | grep -oE '^(CLAUDECODE|CLAUDE_CODE_[A-Z_]*|CLAUDE_PID)=' | tr -d '=' | tr '\n' ' ' || true)
cat <<EOS
${markers:+unset $markers}
export HC_SESSION=ovsb
export XDG_RUNTIME_DIR=$R/run XDG_STATE_HOME=$R/state XDG_DATA_HOME=$R/data
export HERDR_APP_HOME=$R/app
EOS
