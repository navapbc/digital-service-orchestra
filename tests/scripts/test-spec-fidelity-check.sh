#!/usr/bin/env bash
# tests/scripts/test-spec-fidelity-check.sh
# RED test suite for plugins/dso/scripts/spec-fidelity-check.sh
#
# Tests cover the spec-fidelity check at preplanning close:
#   1. PIL field exactly matches story DD text → exits 0
#   2. PIL field dropped (absent in story DDs) → exits 1 with JSON {type:"drop",...}
#   3. PIL field key term mutated → exits 1 with JSON {type:"drop",...}
#   4. Story has additional DDs not in PIL (enrichment) → exits 0
#   5. All PIL fields present and matched → exits 0
#
# Interface under test:
#   spec-fidelity-check.sh --pil-json=<path> --story-dds=<path>
#   --pil-json: JSON file {"criteria": ["criterion text 1", ...]}
#   --story-dds: text file, one done-definition per line
#   Exit 0: all PIL criteria matched in story DDs
#   Exit 1: at least one PIL criterion has no match; stderr JSON {type:"drop",...}
#
# Near-match rule: ≥80% of PIL criterion words must appear in any DD line.
#
# Usage: bash tests/scripts/test-spec-fidelity-check.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail
#
# testing-mode: RED:49c1-885d-719e-47f1

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
FIDELITY_SCRIPT="$REPO_ROOT/plugins/dso/scripts/spec-fidelity-check.sh"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-spec-fidelity-check.sh ==="

# Helper: write PIL JSON criteria file
_write_pil_json() {
    local tmpfile="$1"
    shift
    # Build JSON array from remaining args (each arg = one criterion string)
    local json='{"criteria":['
    local first=1
    for criterion in "$@"; do
        if [[ $first -eq 0 ]]; then json+=','; fi
        # Escape double-quotes inside criterion
        local escaped="${criterion//\"/\\\"}"
        json+="\"${escaped}\""
        first=0
    done
    json+=']}'
    printf '%s' "$json" > "$tmpfile"
}

# Helper: write story DDs file (one DD per line)
_write_story_dds() {
    local tmpfile="$1"
    shift
    : > "$tmpfile"
    for dd in "$@"; do
        printf '%s\n' "$dd" >> "$tmpfile"
    done
}

# ── test_exact_match_exits_0 ──────────────────────────────────────────────────
# A PIL criterion that exactly matches a story DD line → exits 0.
test_exact_match_exits_0() {
    _snapshot_fail
    local rc=0
    local pil_tmp dd_tmp
    pil_tmp=$(mktemp "${TMPDIR:-/tmp}/test-pil-criteria.XXXXXX")
    dd_tmp=$(mktemp "${TMPDIR:-/tmp}/test-story-dds.XXXXXX")

    _write_pil_json "$pil_tmp" \
        "user can upload a document and see its classification within 30 seconds"
    _write_story_dds "$dd_tmp" \
        "user can upload a document and see its classification within 30 seconds"

    bash "$FIDELITY_SCRIPT" --pil-json="$pil_tmp" --story-dds="$dd_tmp" \
        2>/dev/null || rc=$?

    rm -f "$pil_tmp" "$dd_tmp"

    assert_eq "test_exact_match_exits_0: exit code is 0 for exact match" \
        "0" "$rc"
    assert_pass_if_clean "test_exact_match_exits_0"
}

# ── test_dropped_pil_criterion_exits_1_with_json ──────────────────────────────
# A PIL criterion that is completely absent from story DDs → exits 1 with JSON
# error on stderr containing type:"drop".
test_dropped_pil_criterion_exits_1_with_json() {
    _snapshot_fail
    local rc=0
    local pil_tmp dd_tmp stderr_out
    pil_tmp=$(mktemp "${TMPDIR:-/tmp}/test-pil-criteria.XXXXXX")
    dd_tmp=$(mktemp "${TMPDIR:-/tmp}/test-story-dds.XXXXXX")

    _write_pil_json "$pil_tmp" \
        "system processes documents up to 100 pages without timeout"
    _write_story_dds "$dd_tmp" \
        "user can view all extracted rules for a document"

    stderr_out=$(bash "$FIDELITY_SCRIPT" --pil-json="$pil_tmp" --story-dds="$dd_tmp" \
        2>&1) || rc=$?

    rm -f "$pil_tmp" "$dd_tmp"

    assert_eq "test_dropped_pil_criterion_exits_1_with_json: exit code is 1 for dropped PIL field" \
        "1" "$rc"
    assert_contains "test_dropped_pil_criterion_exits_1_with_json: stderr contains type drop" \
        '"type"' "$stderr_out"
    assert_contains "test_dropped_pil_criterion_exits_1_with_json: stderr contains drop value" \
        "drop" "$stderr_out"
    assert_contains "test_dropped_pil_criterion_exits_1_with_json: stderr contains pil_text key" \
        "pil_text" "$stderr_out"
    assert_pass_if_clean "test_dropped_pil_criterion_exits_1_with_json"
}

# ── test_mutated_pil_criterion_exits_1 ───────────────────────────────────────
# A PIL criterion where key terms are replaced by synonyms → < 80% word overlap
# → exits 1 (treated as drop/no match).
test_mutated_pil_criterion_exits_1() {
    _snapshot_fail
    local rc=0
    local pil_tmp dd_tmp stderr_out
    pil_tmp=$(mktemp "${TMPDIR:-/tmp}/test-pil-criteria.XXXXXX")
    dd_tmp=$(mktemp "${TMPDIR:-/tmp}/test-story-dds.XXXXXX")

    # PIL says "reviewed rules persist across sessions"
    # DD says something completely different — key terms dropped, mutated
    _write_pil_json "$pil_tmp" \
        "reviewed rules persist across sessions and visible when user returns"
    _write_story_dds "$dd_tmp" \
        "the approval status is stored in the database permanently"

    stderr_out=$(bash "$FIDELITY_SCRIPT" --pil-json="$pil_tmp" --story-dds="$dd_tmp" \
        2>&1) || rc=$?

    rm -f "$pil_tmp" "$dd_tmp"

    assert_eq "test_mutated_pil_criterion_exits_1: exit code is 1 for mutated key terms" \
        "1" "$rc"
    assert_contains "test_mutated_pil_criterion_exits_1: stderr contains type" \
        '"type"' "$stderr_out"
    assert_contains "test_mutated_pil_criterion_exits_1: stderr contains drop" \
        "drop" "$stderr_out"
    assert_pass_if_clean "test_mutated_pil_criterion_exits_1"
}

# ── test_enrichment_allowed_exits_0 ──────────────────────────────────────────
# Story has extra DDs not sourced from PIL (enrichment) → PIL criteria still matched
# → exits 0. Enrichment is permitted.
test_enrichment_allowed_exits_0() {
    _snapshot_fail
    local rc=0
    local pil_tmp dd_tmp
    pil_tmp=$(mktemp "${TMPDIR:-/tmp}/test-pil-criteria.XXXXXX")
    dd_tmp=$(mktemp "${TMPDIR:-/tmp}/test-story-dds.XXXXXX")

    _write_pil_json "$pil_tmp" \
        "user can view all extracted rules for a document"
    _write_story_dds "$dd_tmp" \
        "user can view all extracted rules for a document" \
        "unit tests written and passing for all new or modified logic" \
        "no regressions in existing rule extraction pipeline"

    bash "$FIDELITY_SCRIPT" --pil-json="$pil_tmp" --story-dds="$dd_tmp" \
        2>/dev/null || rc=$?

    rm -f "$pil_tmp" "$dd_tmp"

    assert_eq "test_enrichment_allowed_exits_0: exit code is 0 when extra DDs present (enrichment OK)" \
        "0" "$rc"
    assert_pass_if_clean "test_enrichment_allowed_exits_0"
}

# ── test_all_pil_fields_present_exits_0 ──────────────────────────────────────
# Multiple PIL criteria all matched in story DDs → exits 0.
test_all_pil_fields_present_exits_0() {
    _snapshot_fail
    local rc=0
    local pil_tmp dd_tmp
    pil_tmp=$(mktemp "${TMPDIR:-/tmp}/test-pil-criteria.XXXXXX")
    dd_tmp=$(mktemp "${TMPDIR:-/tmp}/test-story-dds.XXXXXX")

    _write_pil_json "$pil_tmp" \
        "user can upload a document and see classification within 30 seconds" \
        "system processes documents up to 100 pages without timeout" \
        "reviewed rules appear in the exported Rego output"
    _write_story_dds "$dd_tmp" \
        "user can upload a document and see classification within 30 seconds" \
        "system processes documents up to 100 pages without timeout" \
        "reviewed rules appear in the exported Rego output"

    bash "$FIDELITY_SCRIPT" --pil-json="$pil_tmp" --story-dds="$dd_tmp" \
        2>/dev/null || rc=$?

    rm -f "$pil_tmp" "$dd_tmp"

    assert_eq "test_all_pil_fields_present_exits_0: exit code is 0 when all PIL criteria matched" \
        "0" "$rc"
    assert_pass_if_clean "test_all_pil_fields_present_exits_0"
}

# ── Run all tests ─────────────────────────────────────────────────────────────

test_exact_match_exits_0
test_dropped_pil_criterion_exits_1_with_json
test_mutated_pil_criterion_exits_1
test_enrichment_allowed_exits_0
test_all_pil_fields_present_exits_0

print_summary
