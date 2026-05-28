#!/usr/bin/env bash
# shellcheck disable=SC2016
# Rationale: this test file uses single-quoted printf format strings containing
# literal backticks (e.g., '`dso:<name>`' to inject AGENTS.md table rows). The
# backticks are literal characters in the format string, not command-substitution
# markers we want the shell to evaluate.
#
# tests/scripts/test-check-agents-doc.sh
# Behavioral tests for plugins/dso/scripts/check-agents-doc.sh
#
# Tests cover:
#  - live repo (post-PR-E baseline) -> exit 0
#  - injected file-only agent (file added without doc) -> exit 1 with FILE-ONLY in stderr
#  - injected doc-only agent (doc row added without file) -> exit 1 with DOC-ONLY in stderr
#
# Usage: bash tests/scripts/test-check-agents-doc.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail
#
# testing-mode: GREEN

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRIPT="$PLUGIN_ROOT/plugins/dso/scripts/check-agents-doc.sh"
AGENTS_DIR="$PLUGIN_ROOT/plugins/dso/agents"
AGENTS_MD="$PLUGIN_ROOT/plugins/dso/docs/AGENTS.md"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-check-agents-doc.sh ==="

# ── test_live_repo_clean ──────────────────────────────────────────────────────
test_live_repo_clean() {
    _snapshot_fail
    local rc=0
    bash "$SCRIPT" >/dev/null 2>&1 || rc=$?
    assert_eq "test_live_repo_clean: post-PR-E baseline has zero agent-doc drift" "0" "$rc"
    assert_pass_if_clean "test_live_repo_clean"
}

# ── test_file_only_agent_flagged ──────────────────────────────────────────────
test_file_only_agent_flagged() {
    _snapshot_fail
    # Inject a synthetic agent file (no doc row). Trap-cleanup ensures the fixture
    # is removed even if the test is interrupted (SIGINT or
    # normal function return) — without the trap, a leaked file would cascade and
    # fail subsequent pre-commit invocations of check-agents-doc.sh.
    local _agent_name="test-injected-orphan-agent-$$"
    local _agent_file="$AGENTS_DIR/$_agent_name.md"
    local stderr_file
    stderr_file=$(mktemp "${TMPDIR:-/tmp}/test-check-agents-doc-fo.XXXXXX")
    # shellcheck disable=SC2064
    trap "rm -f '$_agent_file' '$stderr_file'" RETURN
    printf '%s\n' "---" "name: $_agent_name" "description: synthetic test fixture" "---" "Test content." > "$_agent_file"
    local rc=0
    bash "$SCRIPT" >/dev/null 2>"$stderr_file" || rc=$?
    local stderr_content
    stderr_content=$(cat "$stderr_file")
    assert_eq "test_file_only_agent_flagged: exit 1 when an agent file has no doc row" "1" "$rc"
    if echo "$stderr_content" | grep -qF "dso:$_agent_name"; then
        echo "  PASS: test_file_only_agent_flagged: stderr names the file-only agent"
        (( PASS++ ))
    else
        echo "  FAIL: test_file_only_agent_flagged: stderr did not name '$_agent_name'" >&2
        echo "  Actual stderr: $stderr_content" >&2
        (( FAIL++ ))
    fi
    assert_pass_if_clean "test_file_only_agent_flagged"
}

# ── test_doc_only_agent_flagged ───────────────────────────────────────────────
test_doc_only_agent_flagged() {
    _snapshot_fail
    # Inject a synthetic doc row (no agent file). Trap-restore ensures AGENTS.md
    # is restored from backup on SIGINT or normal function return (otherwise the
    # synthetic row leaks into the real doc and corrupts the next run).
    local _agent_name="test-orphan-doc-row-only-$$"
    local _backup
    _backup=$(mktemp "${TMPDIR:-/tmp}/test-check-agents-doc-do-backup.XXXXXX")
    cp "$AGENTS_MD" "$_backup"
    local stderr_file
    stderr_file=$(mktemp "${TMPDIR:-/tmp}/test-check-agents-doc-do.XXXXXX")
    # shellcheck disable=SC2064
    trap "cp '$_backup' '$AGENTS_MD'; rm -f '$_backup' '$stderr_file'" RETURN
    printf '| `dso:%s` | sonnet | synthetic test fixture (no file) |\n' "$_agent_name" >> "$AGENTS_MD"
    local rc=0
    bash "$SCRIPT" >/dev/null 2>"$stderr_file" || rc=$?
    local stderr_content
    stderr_content=$(cat "$stderr_file")
    assert_eq "test_doc_only_agent_flagged: exit 1 when a doc row has no file" "1" "$rc"
    if echo "$stderr_content" | grep -qF "dso:$_agent_name"; then
        echo "  PASS: test_doc_only_agent_flagged: stderr names the doc-only agent"
        (( PASS++ ))
    else
        echo "  FAIL: test_doc_only_agent_flagged: stderr did not name '$_agent_name'" >&2
        echo "  Actual stderr: $stderr_content" >&2
        (( FAIL++ ))
    fi
    assert_pass_if_clean "test_doc_only_agent_flagged"
}

# ── Run all tests ──────────────────────────────────────────────────────────────
test_live_repo_clean
test_file_only_agent_flagged
test_doc_only_agent_flagged

print_summary
