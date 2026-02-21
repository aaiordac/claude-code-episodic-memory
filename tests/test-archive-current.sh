#!/usr/bin/env bash
# Test: --current mode archives session by CLAUDE_SESSION_ID + CWD
set -euo pipefail

TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT

export EPISODIC_DATA_DIR="$TEST_DIR"
export EPISODIC_DB="$TEST_DIR/test.db"
export EPISODIC_LOG="$TEST_DIR/test.log"
export EPISODIC_KNOWLEDGE_DIR="$TEST_DIR/knowledge"
export EPISODIC_ARCHIVE_DIR="$TEST_DIR/archives"
export EPISODIC_CLAUDE_PROJECTS="$TEST_DIR/projects"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/db.sh"

PASS=0
FAIL=0

assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        echo "  ✓ $desc"
        PASS=$((PASS + 1))
    else
        echo "  ✗ $desc: expected '$expected', got '$actual'"
        FAIL=$((FAIL + 1))
    fi
}

echo "=== Test: Archive --current mode ==="

episodic_db_init "$EPISODIC_DB" >/dev/null 2>&1

# Set up a fake project directory with a session file
FAKE_CWD="/home/user/my-project"
PROJECT_DIR_NAME=$(echo "$FAKE_CWD" | tr '/' '-')
SESSION_DIR="$EPISODIC_CLAUDE_PROJECTS/$PROJECT_DIR_NAME"
mkdir -p "$SESSION_DIR"

# Copy fixture to simulate a session file
FIXTURE="$SCRIPT_DIR/fixtures/sample-session.jsonl"
SESSION_ID="test-session-001"
cp "$FIXTURE" "$SESSION_DIR/${SESSION_ID}.jsonl"

# Test 1: --current archives session with correct project name
echo ""
echo "Test 1: --current archives the current session"
export CWD="$FAKE_CWD"
export CLAUDE_SESSION_ID="$SESSION_ID"
"$SCRIPT_DIR/../bin/episodic-archive" --current --no-summary >/dev/null 2>&1

count=$(episodic_db_exec "SELECT count(*) FROM sessions WHERE id='$SESSION_ID';")
assert_eq "Session archived" "1" "$count"

project=$(episodic_db_exec "SELECT project FROM sessions WHERE id='$SESSION_ID';")
assert_eq "Project name is CWD basename" "my-project" "$project"

status=$(episodic_db_exec "SELECT status FROM archive_log WHERE session_id='$SESSION_ID';")
assert_eq "Status is no_summary" "no_summary" "$status"

# Test 2: Graceful exit when CLAUDE_SESSION_ID is unset
echo ""
echo "Test 2: Graceful exit without CLAUDE_SESSION_ID"
unset CLAUDE_SESSION_ID
output=$("$SCRIPT_DIR/../bin/episodic-archive" --current --no-summary 2>&1 || true)
# Should exit 0 without error output
exit_code=0
"$SCRIPT_DIR/../bin/episodic-archive" --current --no-summary 2>/dev/null || exit_code=$?
assert_eq "Exit code is 0" "0" "$exit_code"

# Test 3: Graceful exit when session file doesn't exist
echo ""
echo "Test 3: Graceful exit with nonexistent session file"
export CLAUDE_SESSION_ID="nonexistent-session-999"
export CWD="$FAKE_CWD"
exit_code=0
"$SCRIPT_DIR/../bin/episodic-archive" --current --no-summary 2>/dev/null || exit_code=$?
assert_eq "Exit code is 0 for missing file" "0" "$exit_code"

# Test 4: Idempotent — re-archiving same session doesn't create duplicates
echo ""
echo "Test 4: Idempotent re-archive"
export CLAUDE_SESSION_ID="$SESSION_ID"
"$SCRIPT_DIR/../bin/episodic-archive" --current --no-summary >/dev/null 2>&1
count=$(episodic_db_exec "SELECT count(*) FROM sessions WHERE id='$SESSION_ID';")
assert_eq "Still only 1 session" "1" "$count"

# Test 5: Resumed session — appending messages triggers re-archive
echo ""
echo "Test 5: Resumed session detected by message count growth"
export CLAUDE_SESSION_ID="$SESSION_ID"
export CWD="$FAKE_CWD"

# Record the original message count
orig_count=$(episodic_db_exec "SELECT message_count FROM sessions WHERE id='$SESSION_ID';")

# Append new messages to simulate a resumed session
cat >> "$SESSION_DIR/${SESSION_ID}.jsonl" <<'JSONL'
{"type":"user","message":{"content":"resumed session message"},"timestamp":"2026-01-01T02:00:00.000Z","sessionId":"test-session-001"}
{"type":"assistant","message":{"content":[{"type":"text","text":"welcome back"}]},"timestamp":"2026-01-01T02:01:00.000Z","sessionId":"test-session-001"}
JSONL

# Re-archive — should detect growth and reset status
"$SCRIPT_DIR/../bin/episodic-archive" --current --no-summary >/dev/null 2>&1

new_count=$(episodic_db_exec "SELECT message_count FROM sessions WHERE id='$SESSION_ID';")
new_status=$(episodic_db_exec "SELECT status FROM archive_log WHERE session_id='$SESSION_ID';")

# Message count should have increased
assert_eq "Message count updated" "1" "$(( new_count > orig_count ? 1 : 0 ))"
assert_eq "Status reset to no_summary" "no_summary" "$new_status"

# Test 6: Unchanged session is not re-archived (still idempotent)
echo ""
echo "Test 6: Unchanged resumed session stays idempotent"
# Mark as complete first
episodic_db_update_log "$SESSION_ID" "complete"
# Re-run without changing the file — should skip (is_archived returns true)
"$SCRIPT_DIR/../bin/episodic-archive" --current --no-summary >/dev/null 2>&1
final_status=$(episodic_db_exec "SELECT status FROM archive_log WHERE session_id='$SESSION_ID';")
assert_eq "Status stays complete" "complete" "$final_status"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
