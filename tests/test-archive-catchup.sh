#!/usr/bin/env bash
# Test: --catch-up mode targets sessions with retryable statuses across projects
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

echo "=== Test: Archive --catch-up mode ==="

episodic_db_init "$EPISODIC_DB" >/dev/null 2>&1

# Insert sessions with various statuses across multiple projects
# Retryable: no_summary, summary_failed, pending
# Non-retryable: complete, too_short

echo ""
echo "Test 1: Insert sessions with various statuses"

episodic_db_insert_session "s-nosummary" "project-a" "/a" "/a/s1" "/src/s1" "prompt1" 10 5 5 "main" "2026-01-01T00:00:00Z" "2026-01-01T01:00:00Z" 60
episodic_db_update_log "s-nosummary" "no_summary"

episodic_db_insert_session "s-failed" "project-b" "/b" "/a/s2" "/src/s2" "prompt2" 8 4 4 "main" "2026-01-02T00:00:00Z" "2026-01-02T01:00:00Z" 45
episodic_db_update_log "s-failed" "summary_failed"

episodic_db_insert_session "s-pending" "project-a" "/a" "/a/s3" "/src/s3" "prompt3" 6 3 3 "dev" "2026-01-03T00:00:00Z" "2026-01-03T01:00:00Z" 30
episodic_db_update_log "s-pending" "pending"

episodic_db_insert_session "s-complete" "project-a" "/a" "/a/s4" "/src/s4" "prompt4" 12 6 6 "main" "2026-01-04T00:00:00Z" "2026-01-04T01:00:00Z" 90
episodic_db_update_log "s-complete" "complete"

episodic_db_insert_session "s-tooshort" "project-b" "/b" "/a/s5" "/src/s5" "hi" 1 1 0 "main" "2026-01-05T00:00:00Z" "2026-01-05T00:01:00Z" 1
episodic_db_update_log "s-tooshort" "too_short"

assert_eq "5 sessions inserted" "5" "$(episodic_db_exec "SELECT count(*) FROM sessions;")"

# Test 2: --catch-up --dry-run identifies exactly the 3 retryable sessions
echo ""
echo "Test 2: --catch-up --dry-run targets retryable statuses only"

output=$("$SCRIPT_DIR/../bin/episodic-archive" --catch-up --dry-run 2>/dev/null)

# Count lines starting with "Would summarize:"
retryable_count=$(echo "$output" | grep -c "^Would summarize:" || true)
assert_eq "3 sessions targeted" "3" "$retryable_count"

# Check that the right sessions are targeted
echo "$output" | grep -q "s-nosummary" && nosummary_found="yes" || nosummary_found="no"
assert_eq "no_summary session targeted" "yes" "$nosummary_found"

echo "$output" | grep -q "s-failed" && failed_found="yes" || failed_found="no"
assert_eq "summary_failed session targeted" "yes" "$failed_found"

echo "$output" | grep -q "s-pending" && pending_found="yes" || pending_found="no"
assert_eq "pending session targeted" "yes" "$pending_found"

# Test 3: Completed and too_short sessions are NOT targeted
echo ""
echo "Test 3: Non-retryable statuses are excluded"

echo "$output" | grep -q "s-complete" && complete_found="yes" || complete_found="no"
assert_eq "complete session NOT targeted" "no" "$complete_found"

echo "$output" | grep -q "s-tooshort" && tooshort_found="yes" || tooshort_found="no"
assert_eq "too_short session NOT targeted" "no" "$tooshort_found"

# Test 4: Cross-project coverage (sessions from both project-a and project-b)
echo ""
echo "Test 4: Cross-project coverage"

project_a_count=$(echo "$output" | grep "project-a" | grep -c "^Would summarize:" || true)
project_b_count=$(echo "$output" | grep "project-b" | grep -c "^Would summarize:" || true)

assert_eq "project-a sessions targeted" "2" "$project_a_count"
assert_eq "project-b sessions targeted" "1" "$project_b_count"

# Test 5: --catch-up with no retryable sessions exits cleanly
echo ""
echo "Test 5: Clean exit when nothing to catch up"

# Update all retryable to complete
episodic_db_update_log "s-nosummary" "complete"
episodic_db_update_log "s-failed" "complete"
episodic_db_update_log "s-pending" "complete"

exit_code=0
output2=$("$SCRIPT_DIR/../bin/episodic-archive" --catch-up --dry-run 2>/dev/null) || exit_code=$?
assert_eq "Exit code 0 when nothing to do" "0" "$exit_code"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
