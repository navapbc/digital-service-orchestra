#!/usr/bin/env bash
# tests/integration/test-ref-library.sh
# Integration tests for the DSO reference library (SC-5).
#
# Verifies corpus integrity, retrieval accuracy, tier rendering, and performance
# against the canonical plugins/dso/data/ui-reference/ corpus and
# plugins/dso/scripts/ref-query.sh retrieval script.
#
# SC-PATH NOTE: This file is named test-ref-library.sh (no -integration suffix)
# per SC-5 verbatim path. The runner (run-integration-tests.sh) is updated to
# discover this file in addition to the test-*-integration.sh glob.
#
# Sub-tests:
#   (a) session-timeout query returns entry with domain:[auth] or containing
#       "session timeout" in Summary tier
#   (b) --tier=summary output contains ### Summary and does NOT contain
#       ### Implementation
#   (c) manifest integrity — every _index.yaml entry resolves to a file at
#       its declared path
#   (d) no corpus file exceeds 500 lines
#   (e) precision sub-tests — three representative queries each return a top
#       result whose frontmatter tags match a predefined expected-tag mapping
#   (f) entire test suite completes within 10 seconds
#
# Usage: bash tests/integration/test-ref-library.sh
# Returns: exit 0 if all pass or skip, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-ref-library.sh ==="

# Graceful skip if globally disabled
if [[ "${TEST_INTEGRATION_SKIP:-0}" == "1" ]]; then
    echo "SKIP: TEST_INTEGRATION_SKIP=1"
    exit 0
fi

# ── Core path definitions ─────────────────────────────────────────────────────

CORPUS_DIR="$REPO_ROOT/plugins/dso/data/ui-reference"
INDEX_FILE="$CORPUS_DIR/_index.yaml"
REF_QUERY="$REPO_ROOT/plugins/dso/scripts/ref-query.sh"

# ── Corpus presence check ─────────────────────────────────────────────────────
# Sub-tests that require corpus files skip rather than fail when the corpus
# has not been populated yet (Layer 1+2 stories are still in progress).

CORPUS_AVAILABLE=0
if [[ -f "$INDEX_FILE" ]] && [[ -d "$CORPUS_DIR" ]]; then
    CORPUS_AVAILABLE=1
fi

REF_QUERY_AVAILABLE=0
if [[ -f "$REF_QUERY" ]]; then
    REF_QUERY_AVAILABLE=1
fi

# ── Sub-test (a): session-timeout query returns entry with domain:[auth] ──────
# or containing "session timeout" in the Summary tier output.
# SKIP when corpus or ref-query.sh is not yet available.

test_a_session_timeout_query() {
    if [[ "$CORPUS_AVAILABLE" -eq 0 ]]; then
        echo "SKIP: sub-test (a) — corpus not yet available at $CORPUS_DIR"
        return
    fi
    if [[ "$REF_QUERY_AVAILABLE" -eq 0 ]]; then
        echo "SKIP: sub-test (a) — ref-query.sh not yet available at $REF_QUERY"
        return
    fi

    local output
    output=$(bash "$REF_QUERY" "session timeout" --top-n 8 --tier=summary 2>&1) || true

    # Accept if output contains domain:[auth] tag or the phrase "session timeout"
    local found=0
    if echo "$output" | grep -qi "domain:.*auth" 2>/dev/null; then
        found=1
    elif echo "$output" | grep -qi "session timeout" 2>/dev/null; then
        found=1
    fi

    assert_eq \
        "sub-test (a): session-timeout query returns auth-domain or session-timeout entry" \
        "1" "$found"
}

# ── Sub-test (b): --tier=summary output structure ─────────────────────────────
# Output must contain "### Summary" and must NOT contain "### Implementation".
# SKIP when corpus or ref-query.sh is not yet available.

test_b_tier_summary_structure() {
    if [[ "$CORPUS_AVAILABLE" -eq 0 ]]; then
        echo "SKIP: sub-test (b) — corpus not yet available at $CORPUS_DIR"
        return
    fi
    if [[ "$REF_QUERY_AVAILABLE" -eq 0 ]]; then
        echo "SKIP: sub-test (b) — ref-query.sh not yet available at $REF_QUERY"
        return
    fi

    local output
    output=$(bash "$REF_QUERY" "form validation" --top-n 3 --tier=summary 2>&1) || true

    assert_contains \
        "sub-test (b): --tier=summary output contains '### Summary'" \
        "### Summary" "$output"

    assert_not_contains \
        "sub-test (b): --tier=summary output does NOT contain '### Implementation'" \
        "### Implementation" "$output"
}

# ── Sub-test (c): manifest integrity ─────────────────────────────────────────
# Every _index.yaml entry must resolve to a file at its declared path field.
# SKIP when corpus is not yet available.

test_c_manifest_integrity() {
    if [[ "$CORPUS_AVAILABLE" -eq 0 ]]; then
        echo "SKIP: sub-test (c) — corpus not yet available at $CORPUS_DIR"
        return
    fi

    # Parse path fields from _index.yaml using python3
    local broken_count=0
    local checked_count=0
    local broken_entries=""

    # Extract file paths from _index.yaml: lines matching "  file_path:" key
    while IFS= read -r path_value; do
        [[ -z "$path_value" ]] && continue
        checked_count=$(( checked_count + 1 ))
        # Resolve relative to CORPUS_DIR (paths may be relative or absolute)
        local resolved_path
        if [[ "$path_value" = /* ]]; then
            resolved_path="$path_value"
        else
            resolved_path="$CORPUS_DIR/$path_value"
        fi
        if [[ ! -f "$resolved_path" ]]; then
            broken_count=$(( broken_count + 1 ))
            broken_entries="${broken_entries}\n  missing: $path_value"
        fi
    done < <(python3 - "$INDEX_FILE" <<'PYEOF'
import sys
try:
    with open(sys.argv[1]) as f:
        content = f.read()
    # Extract file_path values: lines with "file_path:" key (YAML list items: "- file_path: ...")
    import re
    for m in re.finditer(r'^[-\s]+file_path:\s*(.+)$', content, re.MULTILINE):
        val = m.group(1).strip().strip('"').strip("'")
        if val:
            print(val)
except Exception as e:
    import sys as _sys
    print(f"ERROR: {e}", file=_sys.stderr)
PYEOF
)

    if [[ "$checked_count" -eq 0 ]]; then
        echo "SKIP: sub-test (c) — _index.yaml has no path entries (empty or not populated)"
        return
    fi

    assert_eq \
        "sub-test (c): manifest integrity — all $checked_count _index.yaml path entries resolve to files (broken=$broken_count${broken_entries:+:}${broken_entries:-})" \
        "0" "$broken_count"
}

# ── Sub-test (d): no corpus file exceeds 500 lines ───────────────────────────
# SKIP when corpus is not yet available.

test_d_corpus_file_line_limit() {
    if [[ "$CORPUS_AVAILABLE" -eq 0 ]]; then
        echo "SKIP: sub-test (d) — corpus not yet available at $CORPUS_DIR"
        return
    fi

    local oversized_count=0
    local oversized_files=""
    local checked_count=0

    while IFS= read -r -d '' corpus_file; do
        # Skip _index.yaml and _schema.yaml — they are manifests, not corpus entries
        local basename
        basename="$(basename "$corpus_file")"
        if [[ "$basename" == _index.yaml ]] || [[ "$basename" == _schema.yaml ]]; then
            continue
        fi
        checked_count=$(( checked_count + 1 ))
        local line_count
        line_count=$(wc -l < "$corpus_file" 2>/dev/null || echo 0)
        if [[ "$line_count" -gt 500 ]]; then
            oversized_count=$(( oversized_count + 1 ))
            oversized_files="${oversized_files}\n  ${corpus_file} (${line_count} lines)"
        fi
    done < <(find "$CORPUS_DIR" -type f \( -name "*.md" -o -name "*.yaml" -o -name "*.yml" \) -print0 2>/dev/null)

    if [[ "$checked_count" -eq 0 ]]; then
        echo "SKIP: sub-test (d) — no corpus files found (corpus not yet populated)"
        return
    fi

    assert_eq \
        "sub-test (d): no corpus file exceeds 500 lines (checked=$checked_count, oversized=$oversized_count${oversized_files:+:}${oversized_files:-})" \
        "0" "$oversized_count"
}

# ── Sub-test (e): precision queries return expected tagged top results ─────────
# Three representative queries, each with an expected frontmatter tag.
# SKIP when corpus or ref-query.sh is not yet available.
# NOTE: The USWDS form validation query depends on story bdb4-3211 (Layer 2)
# being complete. It will SKIP rather than FAIL if the corpus is partial.

_check_precision_query() {
    local label="$1"
    local query="$2"
    local expected_tag="$3"
    local allow_skip="${4:-0}"

    local output
    local rc=0
    output=$(bash "$REF_QUERY" "$query" --top-n 1 --tier=summary 2>&1) || rc=$?

    # Zero-result signal: ref-query.sh emits "[ref-query: no results for query:"
    if echo "$output" | grep -q "\[ref-query: no results"; then
        if [[ "$allow_skip" == "1" ]]; then
            echo "SKIP: precision sub-test '$label' — no results (corpus may be partial)"
            return
        fi
        (( ++FAIL ))
        printf "FAIL: precision sub-test '%s'\n  at: %s:%s\n  query returned no results\n" \
            "$label" "${BASH_SOURCE[0]}" "${LINENO}" >&2
        return
    fi

    # Check if expected tag appears in output
    local found=0
    if echo "$output" | grep -qi "$expected_tag" 2>/dev/null; then
        found=1
    fi

    assert_eq \
        "sub-test (e): precision query '$label' — top result contains tag '$expected_tag'" \
        "1" "$found"
}

test_e_precision_queries() {
    if [[ "$CORPUS_AVAILABLE" -eq 0 ]]; then
        echo "SKIP: sub-test (e) — corpus not yet available at $CORPUS_DIR"
        return
    fi
    if [[ "$REF_QUERY_AVAILABLE" -eq 0 ]]; then
        echo "SKIP: sub-test (e) — ref-query.sh not yet available at $REF_QUERY"
        return
    fi

    # Query 1: "USWDS form validation" → top result has component:[form]
    # Depends on bdb4-3211 (Layer 2); allow skip if no results.
    _check_precision_query \
        "USWDS form validation" \
        "USWDS form validation" \
        "component:.*form" \
        "1"

    # Query 2: "WCAG 2.2 keyboard navigation" → top result has
    # compliance:[wcag-2.2-aaa] AND action:[keyboard-nav]
    _check_precision_query \
        "WCAG 2.2 keyboard navigation (compliance)" \
        "WCAG 2.2 keyboard navigation" \
        "compliance:.*wcag-2\.2" \
        "0"
    _check_precision_query \
        "WCAG 2.2 keyboard navigation (action)" \
        "WCAG 2.2 keyboard navigation" \
        "action:.*keyboard-nav" \
        "0"

    # Query 3: "government authentication anti-pattern" → top result has domain:[auth]
    _check_precision_query \
        "government authentication anti-pattern" \
        "government authentication anti-pattern" \
        "domain:.*auth" \
        "0"
}

# ── Sub-test (f): entire suite completes within 10 seconds ───────────────────
# This sub-test is structural — it is checked by timing the full run at the
# end of this script (see "Run all tests" section below). A sentinel variable
# is set here to document the requirement; the actual check runs post-suite.

_SUITE_START_EPOCH=""
_TIMING_LIMIT_SECONDS=10

test_f_timing_sentinel() {
    # Timing is enforced at the suite level below; this function documents the
    # requirement and will be called as part of the function list.
    : # no-op — timing check happens in the post-suite epilog
}

# ── Run all sub-tests ─────────────────────────────────────────────────────────

# Record suite start time (epoch seconds; bash built-in)
_SUITE_START_EPOCH=$SECONDS

test_a_session_timeout_query
test_b_tier_summary_structure
test_c_manifest_integrity
test_d_corpus_file_line_limit
test_e_precision_queries
test_f_timing_sentinel

# ── Sub-test (f): timing check post-suite ────────────────────────────────────

_SUITE_ELAPSED=$(( SECONDS - _SUITE_START_EPOCH ))
if [[ "$_SUITE_ELAPSED" -gt "$_TIMING_LIMIT_SECONDS" ]]; then
    (( ++FAIL ))
    printf "FAIL: sub-test (f): entire suite completed in %ds (limit: %ds)\n  at: %s\n" \
        "$_SUITE_ELAPSED" "$_TIMING_LIMIT_SECONDS" "${BASH_SOURCE[0]}" >&2
else
    (( ++PASS ))
    echo "sub-test (f): timing — suite completed in ${_SUITE_ELAPSED}s (limit: ${_TIMING_LIMIT_SECONDS}s) ... PASS"
fi

print_summary
