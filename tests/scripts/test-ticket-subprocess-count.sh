#!/usr/bin/env bash
# tests/scripts/test-ticket-subprocess-count.sh
# RED structural tests: verify ticket-list.sh, ticket-show.sh, and ticket-transition.sh
# use at most one python3 subprocess per logical pipeline branch after consolidation.
#
# These are static source-structure tests — they grep/awk the script files and count
# python3 invocations in specific sections. They do NOT intercept live subprocesses.
#
# Current counts (before S2-T4 consolidation):
#   ticket-list.sh LLM branch:         2 python3 calls (filter + importlib dance)
#   ticket-list.sh default branch:      2 python3 calls (filter + heredoc inline)
#   ticket-show.sh LLM pathway:         4 python3 calls (reducer + llm-fmt + pretty + bridge)
#   ticket-transition.sh epic-close:    2 python3 calls (reducer + type extraction)
#
# After S2-T4 consolidation all of the above must be ≤1.
#
# Tests 5 (flock section) verifies the invariant is maintained at exactly 1.
#
# Usage: bash tests/scripts/test-ticket-subprocess-count.sh
# Returns: exit non-zero (RED) until consolidation is implemented.

# NOTE: -e is intentionally omitted — test functions return non-zero by design.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"

LIST_SCRIPT="$REPO_ROOT/plugins/dso/scripts/ticket-list.sh"
SHOW_SCRIPT="$REPO_ROOT/plugins/dso/scripts/ticket-show.sh"
TRANSITION_SCRIPT="$REPO_ROOT/plugins/dso/scripts/ticket-transition.sh"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-ticket-subprocess-count.sh ==="

# ── Test 1: ticket-list.sh LLM format branch uses ≤1 python3 process ─────────
# Currently uses 2 python3 calls in the llm branch:
#   line ~106: filter/convert pipeline step
#   line ~122: importlib/to_llm pipeline step
# After S2-T4 consolidation, the branch must invoke python3 at most once.
echo "Test 1: ticket-list.sh LLM format branch uses at most 1 python3 subprocess"
test_list_llm_branch_single_python3() {
    if [ ! -f "$LIST_SCRIPT" ]; then
        assert_eq "ticket-list.sh exists" "exists" "missing"
        return
    fi

    # Count python3 invocations between 'if [ "$format" = "llm" ]' and the 'else' delimiter.
    # The pattern '\$format' matches a literal $format in the awk script.
    local llm_count
    llm_count=$(awk '
        /if \[ "\$format" = "llm" \]/ { in_llm=1 }
        /^else$/ && in_llm { in_llm=0 }
        in_llm && /python3/ && !/^\s*#/ { count++ }
        END { print count+0 }
    ' "$LIST_SCRIPT")

    # RED: currently 2 (filter+format pipeline); must be ≤1 after consolidation.
    assert_eq "ticket-list.sh LLM branch python3 count is ≤1" "1" "$llm_count"
}
test_list_llm_branch_single_python3

# ── Test 2: ticket-list.sh default format branch uses ≤1 python3 process ─────
# The default (JSON array) branch currently has 2 python3 calls:
#   one inline python3 -c for filtering/outputting results
#   one via heredoc '<<< "$batch_output"' (also python3)
# After S2-T4 consolidation, this branch must invoke python3 at most once.
echo "Test 2: ticket-list.sh default format branch uses at most 1 python3 subprocess"
test_list_default_branch_single_python3() {
    if [ ! -f "$LIST_SCRIPT" ]; then
        assert_eq "ticket-list.sh exists" "exists" "missing"
        return
    fi

    # Count python3 invocations in the 'else' branch (default JSON output).
    # From '^else$' (after the llm guard) to '^fi$' at end of the if block.
    local default_count
    default_count=$(awk '
        /^else$/ { in_default=1; next }
        /^fi$/ && in_default { in_default=0 }
        in_default && /python3/ && !/^\s*#/ { count++ }
        END { print count+0 }
    ' "$LIST_SCRIPT")

    # RED: currently 2 (filter inline + heredoc); must be ≤1 after consolidation.
    assert_eq "ticket-list.sh default branch python3 count is ≤1" "1" "$default_count"
}
test_list_default_branch_single_python3

# ── Test 3: ticket-show.sh full LLM pathway uses ≤1 python3 process ──────────
# The full LLM pathway currently invokes 4 python3 subprocesses across the
# reducer call and format/output section:
#   line ~82:  reducer subprocess
#   line ~95:  importlib/to_llm subprocess (LLM branch)
#   line ~115: pretty-print subprocess (default branch)
#   line ~117: bridge-alert count subprocess (default branch)
# After S2-T4 consolidation, the LLM pathway must use ≤1 python3 subprocess.
# We test the full section from the reducer invocation to the closing fi.
echo "Test 3: ticket-show.sh full script uses at most 1 python3 subprocess for LLM pathway"
test_show_llm_pathway_single_python3() {
    if [ ! -f "$SHOW_SCRIPT" ]; then
        assert_eq "ticket-show.sh exists" "exists" "missing"
        return
    fi

    # Count all python3 invocations from the '# ── Invoke reducer' comment to
    # the closing 'fi' of the format if/else block.
    local total_count
    total_count=$(awk '
        /# ── Invoke reducer/ { in_block=1 }
        /^fi$/ && in_block { in_block=0 }
        in_block && /python3/ && !/^\s*#/ { count++ }
        END { print count+0 }
    ' "$SHOW_SCRIPT")

    # RED: currently 4 (reducer + llm-fmt + pretty-print + bridge-alert count).
    # After consolidation the full section must use ≤1 direct python3 spawn.
    assert_eq "ticket-show.sh format section python3 count is ≤1" "1" "$total_count"
}
test_show_llm_pathway_single_python3

# ── Test 4: ticket-transition.sh epic-close section uses ≤1 python3 ──────────
# The epic-close reminder section (lines ~388-393) currently invokes 2 python3 calls
# in a pipeline: one for the reducer, one for type extraction via json.loads.
# After S2-T4 consolidation, this must be a single python3 call.
echo "Test 4: ticket-transition.sh epic-close section uses at most 1 python3 subprocess"
test_transition_epic_close_single_python3() {
    if [ ! -f "$TRANSITION_SCRIPT" ]; then
        assert_eq "ticket-transition.sh exists" "exists" "missing"
        return
    fi

    # Count python3 invocations in the epic-close reminder section.
    # From '# Epic-close reminder' to the closing 'fi' of the if block.
    local epic_close_count
    epic_close_count=$(awk '
        /# Epic-close reminder/ { in_block=1 }
        /^fi$/ && in_block { in_block=0 }
        in_block && /python3/ && !/^\s*#/ { count++ }
        END { print count+0 }
    ' "$TRANSITION_SCRIPT")

    # RED: currently 2 (reducer | type-extraction pipeline); must be ≤1 after consolidation.
    assert_eq "ticket-transition.sh epic-close python3 count is ≤1" "1" "$epic_close_count"
}
test_transition_epic_close_single_python3

# ── Test 5: ticket-transition.sh main flock pipeline uses exactly 1 python3 ───
# The flock section (lines ~222-352) must contain exactly 1 python3 -c invocation.
# This is an invariant test — it verifies the flock block was NOT accidentally
# split into multiple subprocesses during consolidation work.
echo "Test 5: ticket-transition.sh main flock section uses exactly 1 python3 subprocess"
test_transition_flock_section_exactly_one_python3() {
    if [ ! -f "$TRANSITION_SCRIPT" ]; then
        assert_eq "ticket-transition.sh exists" "exists" "missing"
        return
    fi

    # Count python3 invocations from the flock comment to the 'flock_exit=$?' capture.
    # Uses ^\s*python3 since the flock block's python3 is at the start of a line.
    local flock_count
    flock_count=$(awk '
        /# The entire read-verify-write is done inside python3/ { in_flock=1 }
        /flock_exit=\$\?/ && in_flock { in_flock=0 }
        in_flock && /^\s*python3/ { count++ }
        END { print count+0 }
    ' "$TRANSITION_SCRIPT")

    # Invariant: flock block must contain exactly 1 python3 invocation (already true).
    # This is a GREEN invariant test — it verifies the implementation did not regress.
    assert_eq "ticket-transition.sh flock section python3 count is exactly 1" "1" "$flock_count"
}
test_transition_flock_section_exactly_one_python3

print_summary
