#!/usr/bin/env bash
# tests/scripts/test-known-issues-smoke.sh
# Smoke test for .claude/docs/KNOWN-ISSUES.md
#
# Verifies that:
#   1. The KNOWN-ISSUES.md file exists
#   2. It contains all 10 required incident entries (INC-001 through INC-010)
#   3. Each incident covers a distinct DSO operational friction point
#
# Usage: bash tests/scripts/test-known-issues-smoke.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
KNOWN_ISSUES="$REPO_ROOT/docs/KNOWN-ISSUES.md"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-known-issues-smoke.sh ==="

# ── test_file_exists ──────────────────────────────────────────────────────────
test_file_exists() {
    _snapshot_fail
    if [[ -f "$KNOWN_ISSUES" ]]; then
        : # file exists, assertions will follow
    else
        (( ++FAIL ))
        printf "FAIL: KNOWN-ISSUES.md does not exist at %s\n" "$KNOWN_ISSUES" >&2
    fi
    assert_pass_if_clean "KNOWN-ISSUES.md file exists"
}

# ── test_has_ten_incidents ────────────────────────────────────────────────────
test_has_ten_incidents() {
    _snapshot_fail
    local count
    count=$(grep -c '^### INC-' "$KNOWN_ISSUES" 2>/dev/null || echo "0")
    if [[ "$count" -ge 10 ]]; then
        (( ++PASS ))
    else
        (( ++FAIL ))
        printf "FAIL: expected >= 10 incident entries, found %s\n" "$count" >&2
    fi
    assert_pass_if_clean "KNOWN-ISSUES.md has >= 10 incidents"
}

# ── test_inc_ids_sequential ───────────────────────────────────────────────────
test_inc_ids_sequential() {
    _snapshot_fail
    for i in 1 2 3 4 5 6 7 8 9 10; do
        local id
        id="INC-$(printf '%03d' "$i")"
        if ! grep -q "^### $id" "$KNOWN_ISSUES" 2>/dev/null; then
            (( ++FAIL ))
            printf "FAIL: missing incident heading ### %s\n" "$id" >&2
        else
            (( ++PASS ))
        fi
    done
    assert_pass_if_clean "INC-001 through INC-010 all present"
}

# ── test_exit_144_incident ────────────────────────────────────────────────────
# INC covers tool timeout ceiling (exit 144 / SIGURG)
test_exit_144_incident() {
    _snapshot_fail
    assert_contains "exit 144 keyword present" "exit 144" "$(cat "$KNOWN_ISSUES" 2>/dev/null)"
    local content
    content="$(cat "$KNOWN_ISSUES" 2>/dev/null)"
    # Must have a Fix section referencing timeout or test-batched (match literal **Fix**: marker)
    if [[ "$content" == *exit\ 144* ]] && { _exit144_ctx=$(grep -A 20 "exit 144" <<< "$content"); [[ "$_exit144_ctx" == *'**Fix**:'* ]]; }; then
        (( ++PASS ))
    else
        (( ++FAIL ))
        printf "FAIL: exit 144 incident missing Fix section\n" >&2
    fi
    assert_pass_if_clean "exit 144 (tool timeout ceiling) incident documented with Fix"
}

# ── test_worktree_path_incident ───────────────────────────────────────────────
# INC covers path confusion in worktrees
test_worktree_path_incident() {
    _snapshot_fail
    local content
    content="$(cat "$KNOWN_ISSUES" 2>/dev/null)"
    if [[ "${content,,}" == *worktree* ]] && [[ "${content,,}" == *path* ]]; then
        (( ++PASS ))
    else
        (( ++FAIL ))
        printf "FAIL: worktree path confusion incident not found\n" >&2
    fi
    # Fix must reference git rev-parse or absolute path
    if [[ "$content" =~ rev-parse|absolute\ path|show-toplevel ]]; then
        (( ++PASS ))
    else
        (( ++FAIL ))
        printf "FAIL: worktree path incident Fix does not reference rev-parse/absolute path\n" >&2
    fi
    assert_pass_if_clean "worktree path confusion incident documented with Fix"
}

# ── test_test_timeout_incident ────────────────────────────────────────────────
# INC covers broad test commands killed by timeout
test_test_timeout_incident() {
    _snapshot_fail
    local content
    content="$(cat "$KNOWN_ISSUES" 2>/dev/null)"
    if [[ "${content,,}" =~ test-batched|make\ test|test\ timeout ]]; then
        (( ++PASS ))
    else
        (( ++FAIL ))
        printf "FAIL: test timeout (broad test commands) incident not found\n" >&2
    fi
    assert_pass_if_clean "test timeout (broad test commands killed) incident documented"
}

# ── test_venv_command_not_found_incident ──────────────────────────────────────
# INC covers worktree venv / command-not-found
test_venv_command_not_found_incident() {
    _snapshot_fail
    local content
    content="$(cat "$KNOWN_ISSUES" 2>/dev/null)"
    if [[ "${content,,}" =~ venv|command.not.found|poetry\ env ]]; then
        (( ++PASS ))
    else
        (( ++FAIL ))
        printf "FAIL: venv/command-not-found incident not found\n" >&2
    fi
    assert_pass_if_clean "venv command-not-found incident documented"
}

# ── test_review_gate_sub_agent_incident ───────────────────────────────────────
# INC covers review gate blocking sub-agent commits
test_review_gate_sub_agent_incident() {
    _snapshot_fail
    local content
    content="$(cat "$KNOWN_ISSUES" 2>/dev/null)"
    if [[ "${content,,}" =~ review\ gate|sub.agent.*commit|commit.*sub.agent ]]; then
        (( ++PASS ))
    else
        (( ++FAIL ))
        printf "FAIL: review gate sub-agent commit incident not found\n" >&2
    fi
    assert_pass_if_clean "review gate blocks sub-agent commits incident documented"
}

# ── test_nesting_tool_result_incident ─────────────────────────────────────────
# INC covers sub-agent nesting causing tool-result errors
test_nesting_tool_result_incident() {
    _snapshot_fail
    local content
    content="$(cat "$KNOWN_ISSUES" 2>/dev/null)"
    if [[ "${content,,}" =~ nesting|nested.*task|tool\ result\ missing ]]; then
        (( ++PASS ))
    else
        (( ++FAIL ))
        printf "FAIL: nesting/tool-result-missing incident not found\n" >&2
    fi
    assert_pass_if_clean "sub-agent nesting tool-result error incident documented"
}

# ── test_hook_cascade_incident ────────────────────────────────────────────────
# INC covers hook failure cascades
test_hook_cascade_incident() {
    _snapshot_fail
    local content
    content="$(cat "$KNOWN_ISSUES" 2>/dev/null)"
    if [[ "${content,,}" =~ hook.*cascade|cascade.*hook|hook-error-log|cascade.circuit ]]; then
        (( ++PASS ))
    else
        (( ++FAIL ))
        printf "FAIL: hook cascade incident not found\n" >&2
    fi
    assert_pass_if_clean "hook failure cascade incident documented"
}

# ── test_ticket_merge_conflict_incident ───────────────────────────────────────
# INC covers ticket index merge conflicts
test_ticket_merge_conflict_incident() {
    _snapshot_fail
    local content
    content="$(cat "$KNOWN_ISSUES" 2>/dev/null)"
    if [[ "${content,,}" =~ ticket.*merge|merge.*conflict.*ticket ]] || [[ "$content" == *\.tickets-tracker* ]]; then
        (( ++PASS ))
    else
        (( ++FAIL ))
        printf "FAIL: ticket merge conflict incident not found\n" >&2
    fi
    assert_pass_if_clean "ticket index merge conflict incident documented"
}

# ── test_claude_plugin_root_incident ──────────────────────────────────────────
# INC covers CLAUDE_PLUGIN_ROOT unbound in parallel execution
test_claude_plugin_root_incident() {
    _snapshot_fail
    local content
    content="$(cat "$KNOWN_ISSUES" 2>/dev/null)"
    if [[ "$content" == *CLAUDE_PLUGIN_ROOT* ]]; then
        (( ++PASS ))
    else
        (( ++FAIL ))
        printf "FAIL: CLAUDE_PLUGIN_ROOT incident not found\n" >&2
    fi
    assert_pass_if_clean "CLAUDE_PLUGIN_ROOT unbound incident documented"
}

# ── test_cascading_failure_runaway_incident ───────────────────────────────────
# INC covers cascading failure runaway
test_cascading_failure_runaway_incident() {
    _snapshot_fail
    local content
    content="$(cat "$KNOWN_ISSUES" 2>/dev/null)"
    if [[ "${content,,}" =~ cascading\ failure|cascade.*runaway|fix.cascade.recovery|runaway ]]; then
        (( ++PASS ))
    else
        (( ++FAIL ))
        printf "FAIL: cascading failure runaway incident not found\n" >&2
    fi
    assert_pass_if_clean "cascading failure runaway incident documented"
}

# ── test_all_incidents_have_fix_field ─────────────────────────────────────────
test_all_incidents_have_fix_field() {
    _snapshot_fail
    local fix_count
    fix_count=$(grep -c '\*\*Fix\*\*:' "$KNOWN_ISSUES" 2>/dev/null || echo "0")
    if [[ "$fix_count" -ge 10 ]]; then
        (( ++PASS ))
    else
        (( ++FAIL ))
        printf "FAIL: expected >= 10 Fix fields, found %s\n" "$fix_count" >&2
    fi
    assert_pass_if_clean "all 10 incidents have Fix fields"
}

# ── Run all tests ─────────────────────────────────────────────────────────────
test_file_exists
test_has_ten_incidents
test_inc_ids_sequential
test_exit_144_incident
test_worktree_path_incident
test_test_timeout_incident
test_venv_command_not_found_incident
test_review_gate_sub_agent_incident
test_nesting_tool_result_incident
test_hook_cascade_incident
test_ticket_merge_conflict_incident
test_claude_plugin_root_incident
test_cascading_failure_runaway_incident
test_all_incidents_have_fix_field

print_summary
