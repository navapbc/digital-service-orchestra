#!/usr/bin/env bash
# tests/scripts/test-debug-everything-prompt-contracts.sh
#
# Structural-boundary tests for the 6 debug-everything sub-agent prompt files
# added/relocated during the skill-refactor pass, plus the shared
# test-failure-fix.md prompt relocated from debug-everything/prompts/.
#
# Per behavioral-testing-standard Rule 5: each assertion targets a NAMED
# CONTRACT identifier (env var, signal name, schema field, routing category,
# parameter name) consumed by the orchestrator or another prompt — NOT prose
# phrases. A regression that renames or removes any of these silently breaks
# the orchestrator's parse path. Pattern follows
# tests/scripts/test-gha-scanner-prompt-contract.sh.

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
PROMPTS_DIR="$REPO_ROOT/plugins/dso/skills/debug-everything/prompts"
SHARED_PROMPTS_DIR="$REPO_ROOT/plugins/dso/skills/shared/prompts"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-debug-everything-prompt-contracts.sh ==="

_assert_contract_present() {
    local file="$1" identifier="$2" label="$3"
    if grep -qF "$identifier" "$file"; then
        assert_eq "$label" "found" "found"
    else
        assert_eq "$label" "found" "missing"
    fi
}

_assert_file_nonempty() {
    local file="$1" name="$2"
    if [[ -s "$file" ]]; then
        assert_eq "$name exists and is non-empty" "exists" "exists"
    else
        assert_eq "$name exists and is non-empty" "exists" "missing"
    fi
}

# ── session-init.md ───────────────────────────────────────────────────────────
SESSION_INIT="$PROMPTS_DIR/session-init.md"
echo "--- session-init.md contracts ---"
_assert_file_nonempty "$SESSION_INIT" "session-init.md"
for var in DISPATCH_ISOLATION MAX_FIX_VALIDATE_CYCLES LOCK_ID INTERACTIVE_SESSION; do
    _assert_contract_present "$SESSION_INIT" "$var" "session-init.md exports '$var'"
done
_assert_contract_present "$SESSION_INIT" "agent-batch-lifecycle.sh lock-acquire" \
    "session-init.md references agent-batch-lifecycle.sh lock-acquire"

# ── dispatch-fix-batch.md ─────────────────────────────────────────────────────
DISPATCH_FIX="$PROMPTS_DIR/dispatch-fix-batch.md"
echo "--- dispatch-fix-batch.md contracts ---"
_assert_file_nonempty "$DISPATCH_FIX" "dispatch-fix-batch.md"
_assert_contract_present "$DISPATCH_FIX" "MAX_AGENTS" \
    "dispatch-fix-batch.md references MAX_AGENTS protocol"
_assert_contract_present "$DISPATCH_FIX" "/dso:fix-bug" \
    "dispatch-fix-batch.md delegates to /dso:fix-bug"
_assert_contract_present "$DISPATCH_FIX" "agent-routing-table.md" \
    "dispatch-fix-batch.md references agent-routing-table.md"

# ── agent-routing-table.md ────────────────────────────────────────────────────
ROUTING="$PROMPTS_DIR/agent-routing-table.md"
echo "--- agent-routing-table.md contracts ---"
_assert_file_nonempty "$ROUTING" "agent-routing-table.md"
for category in mechanical_fix test_fix_unit test_fix_e_to_e code_simplify complex_debug; do
    _assert_contract_present "$ROUTING" "$category" \
        "agent-routing-table.md routing category '$category' present"
done

# ── complex-escalation-handler.md ─────────────────────────────────────────────
COMPLEX="$PROMPTS_DIR/complex-escalation-handler.md"
echo "--- complex-escalation-handler.md contracts ---"
_assert_file_nonempty "$COMPLEX" "complex-escalation-handler.md"
_assert_contract_present "$COMPLEX" "COMPLEX_ESCALATION: true" \
    "complex-escalation-handler.md detection signal 'COMPLEX_ESCALATION: true'"
for field in escalation_type bug_id escalation_reason investigation_findings; do
    _assert_contract_present "$COMPLEX" "$field" \
        "complex-escalation-handler.md schema field '$field' present"
done
_assert_contract_present "$COMPLEX" "skip to Step 4" \
    "complex-escalation-handler.md 'skip to Step 4' re-dispatch directive"

# ── file-overlap-resolution.md ────────────────────────────────────────────────
OVERLAP="$PROMPTS_DIR/file-overlap-resolution.md"
echo "--- file-overlap-resolution.md contracts ---"
_assert_file_nonempty "$OVERLAP" "file-overlap-resolution.md"
_assert_contract_present "$OVERLAP" "CONFLICTS:" \
    "file-overlap-resolution.md emits 'CONFLICTS:' summary signal"
_assert_contract_present "$OVERLAP" "CONFLICT:" \
    "file-overlap-resolution.md emits per-overlap 'CONFLICT:' signal"
_assert_contract_present "$OVERLAP" "PRIMARY=" \
    "file-overlap-resolution.md uses 'PRIMARY=' field"
_assert_contract_present "$OVERLAP" "SECONDARY=" \
    "file-overlap-resolution.md uses 'SECONDARY=' field"
_assert_contract_present "$OVERLAP" "oscillation" \
    "file-overlap-resolution.md references oscillation guard"

# ── gha-dispatch.md ───────────────────────────────────────────────────────────
GHA_DISPATCH="$PROMPTS_DIR/gha-dispatch.md"
echo "--- gha-dispatch.md contracts ---"
_assert_file_nonempty "$GHA_DISPATCH" "gha-dispatch.md"
_assert_contract_present "$GHA_DISPATCH" "EPIC_COMMENT_LABEL" \
    "gha-dispatch.md accepts EPIC_COMMENT_LABEL parameter"
_assert_contract_present "$GHA_DISPATCH" "gha-scanner.md" \
    "gha-dispatch.md references gha-scanner.md"
_assert_contract_present "$GHA_DISPATCH" "tickets_created" \
    "gha-dispatch.md parses 'tickets_created' summary field"

# ── shared/prompts/test-failure-fix.md ────────────────────────────────────────
TEST_FAILURE_FIX="$SHARED_PROMPTS_DIR/test-failure-fix.md"
echo "--- shared/prompts/test-failure-fix.md contracts ---"
_assert_file_nonempty "$TEST_FAILURE_FIX" "shared/prompts/test-failure-fix.md"
_assert_contract_present "$TEST_FAILURE_FIX" "{task_id}" \
    "test-failure-fix.md exposes '{task_id}' template parameter"
_assert_contract_present "$TEST_FAILURE_FIX" "{attempt}" \
    "test-failure-fix.md exposes '{attempt}' template parameter"
_assert_contract_present "$TEST_FAILURE_FIX" "{parent_task_id}" \
    "test-failure-fix.md exposes '{parent_task_id}' template parameter"
_assert_contract_present "$TEST_FAILURE_FIX" "Decision Gate" \
    "test-failure-fix.md provides 'Decision Gate' classification section"

print_summary
