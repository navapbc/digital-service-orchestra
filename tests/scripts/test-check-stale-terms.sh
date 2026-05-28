#!/usr/bin/env bash
# Tests for check-stale-terms.sh
# Verifies the lint detects stale "skeleton/walking-skeleton/lands-in-Task"
# vocabulary in production source files and respects the per-line escape
# annotation and path-based exclusions.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$REPO_ROOT/tests/lib/assert.sh"

SUT="$REPO_ROOT/plugins/dso/scripts/check-stale-terms.sh"

# ── Test scaffolding ─────────────────────────────────────────────────────────
TMPDIR_TEST=""
_setup() {
    TMPDIR_TEST=$(mktemp -d "${TMPDIR:-/tmp}/test-check-stale-terms.XXXXXX")
}
_teardown() {
    [[ -n "$TMPDIR_TEST" ]] && rm -rf "$TMPDIR_TEST"
}
trap _teardown EXIT

# ── Tests ────────────────────────────────────────────────────────────────────

test_detects_skeleton_implementation() {
    _setup
    cat > "$TMPDIR_TEST/x.sh" <<'EOF'
#!/usr/bin/env bash
# Skeleton implementation that satisfies T1 dispatcher.
echo hi
EOF
    local _out _rc=0
    _out=$("$SUT" --scan-dir "$TMPDIR_TEST" 2>&1) || _rc=$?
    assert_eq "expected exit 1 on violation" "1" "$_rc"
    assert_contains "violation should be reported" "skeleton implementation" "$_out"
    _teardown
}

test_detects_walking_skeleton() {
    _setup
    cat > "$TMPDIR_TEST/a.py" <<'EOF'
"""Module that demonstrates the walking-skeleton pattern."""
EOF
    local _rc=0
    "$SUT" --scan-dir "$TMPDIR_TEST" >/dev/null 2>&1 || _rc=$?
    assert_eq "walking-skeleton exits 1" "1" "$_rc"
    _teardown
}

test_detects_lands_in_Task() {
    _setup
    cat > "$TMPDIR_TEST/x.sh" <<'EOF'
#!/usr/bin/env bash
# Full implementation lands in Task 3.
echo hi
EOF
    local _rc=0
    "$SUT" --scan-dir "$TMPDIR_TEST" >/dev/null 2>&1 || _rc=$?
    assert_eq "lands-in-Task exits 1" "1" "$_rc"
    _teardown
}

test_no_false_positive_on_placeholder_value() {
    # The word "placeholder" alone (e.g., describing a runtime sentinel value)
    # must not match — only "placeholder implementation" should.
    _setup
    cat > "$TMPDIR_TEST/x.sh" <<'EOF'
#!/usr/bin/env bash
# story_id may be empty — emit a placeholder so the regex still matches.
local _trailer_id="${_story_id:-unknown}"
EOF
    local _rc=0
    "$SUT" --scan-dir "$TMPDIR_TEST" >/dev/null 2>&1 || _rc=$?
    assert_eq "no false positive on 'placeholder' noun" "0" "$_rc"
    _teardown
}

test_per_line_escape_annotation() {
    _setup
    cat > "$TMPDIR_TEST/x.sh" <<'EOF'
#!/usr/bin/env bash
# This is a skeleton — # stale-term-ok (legitimate reference)
echo hi
EOF
    local _rc=0
    "$SUT" --scan-dir "$TMPDIR_TEST" >/dev/null 2>&1 || _rc=$?
    assert_eq "escape annotation respected" "0" "$_rc"
    _teardown
}

test_path_exclusion_tests_dir() {
    _setup
    mkdir -p "$TMPDIR_TEST/tests"
    cat > "$TMPDIR_TEST/tests/x.sh" <<'EOF'
#!/usr/bin/env bash
# Skeleton implementation kept as a fixture for the linter test suite.
EOF
    local _rc=0
    "$SUT" --scan-dir "$TMPDIR_TEST" >/dev/null 2>&1 || _rc=$?
    assert_eq "tests/ path excluded" "0" "$_rc"
    _teardown
}

test_path_exclusion_docs_designs() {
    _setup
    mkdir -p "$TMPDIR_TEST/docs/designs"
    cat > "$TMPDIR_TEST/docs/designs/x.sh" <<'EOF'
#!/usr/bin/env bash
# A walking-skeleton design exploration kept under docs/designs/.
EOF
    local _rc=0
    "$SUT" --scan-dir "$TMPDIR_TEST" >/dev/null 2>&1 || _rc=$?
    assert_eq "docs/designs/ excluded" "0" "$_rc"
    _teardown
}

test_clean_file_exits_zero() {
    _setup
    cat > "$TMPDIR_TEST/x.sh" <<'EOF'
#!/usr/bin/env bash
# Production logic for the merge-to-main pipeline. No stale vocabulary.
echo hi
EOF
    local _rc=0
    "$SUT" --scan-dir "$TMPDIR_TEST" >/dev/null 2>&1 || _rc=$?
    assert_eq "clean file exits 0" "0" "$_rc"
    _teardown
}

test_repo_currently_passes() {
    # Sanity: after F-08 rewrites, the live repo must pass the lint.
    local _rc=0
    "$SUT" >/dev/null 2>&1 || _rc=$?
    assert_eq "live repo passes lint" "0" "$_rc"
}

# ── Run all tests ────────────────────────────────────────────────────────────
test_detects_skeleton_implementation
test_detects_walking_skeleton
test_detects_lands_in_Task
test_no_false_positive_on_placeholder_value
test_per_line_escape_annotation
test_path_exclusion_tests_dir
test_path_exclusion_docs_designs
test_clean_file_exits_zero
test_repo_currently_passes

print_summary
