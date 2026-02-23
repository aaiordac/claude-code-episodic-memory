#!/usr/bin/env bash
# Stop hook: checkpoint session + push knowledge changes
# No API calls here — full summary happens on next SessionStart
#
# Claude Code passes hook context as JSON on stdin:
#   { "session_id": "...", "cwd": "...", "transcript_path": "...", ... }

EPISODIC_ROOT="${EPISODIC_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

# Skip if not installed
[[ -f "$EPISODIC_ROOT/bin/episodic-archive" ]] || exit 0

source "$EPISODIC_ROOT/lib/config.sh"

# Parse hook input from stdin (Claude Code sends JSON)
HOOK_INPUT=$(cat)
export CLAUDE_SESSION_ID=$(echo "$HOOK_INPUT" | jq -r '.session_id // empty' 2>/dev/null)
export CWD=$(echo "$HOOK_INPUT" | jq -r '.cwd // empty' 2>/dev/null)

CWD_BASENAME=$(basename "${CWD:-unknown}")
episodic_log "INFO" "Stop hook started [$CWD_BASENAME] (session=$CLAUDE_SESSION_ID)"

# Quick metadata-only archive of current session (no Haiku call)
"$EPISODIC_ROOT/bin/episodic-archive" --current --no-summary &>/dev/null || true

# Push any knowledge repo changes (background, non-blocking)
if [[ -f "$EPISODIC_ROOT/bin/episodic-knowledge-sync" ]]; then
    "$EPISODIC_ROOT/bin/episodic-knowledge-sync" push &>/dev/null &
fi

episodic_log "INFO" "Stop hook finished [$CWD_BASENAME] (session=$CLAUDE_SESSION_ID)"
