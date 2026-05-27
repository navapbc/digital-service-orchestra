#!/usr/bin/env bash
# tests/scripts/test-lint-story-dds.sh
#
# Behavior tests for plugins/dso/scripts/lint-story-dds.sh.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LINT="$REPO_ROOT/plugins/dso/scripts/lint-story-dds.sh"

PASS=0
FAIL=0

_assert_contains() {
    local name="$1" needle="$2" hay="$3"
    if printf '%s' "$hay" | grep -qF -- "$needle"; then
        PASS=$((PASS+1))
    else
        FAIL=$((FAIL+1))
        printf "FAIL: %s\n  expected to contain: %s\n  actual: %s\n" "$name" "$needle" "$hay" >&2
    fi
}

_assert_not_contains() {
    local name="$1" needle="$2" hay="$3"
    if printf '%s' "$hay" | grep -qF -- "$needle"; then
        FAIL=$((FAIL+1))
        printf "FAIL: %s\n  expected NOT to contain: %s\n  actual: %s\n" "$name" "$needle" "$hay" >&2
    else
        PASS=$((PASS+1))
    fi
}

_assert_eq() {
    local name="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        PASS=$((PASS+1))
    else
        FAIL=$((FAIL+1))
        printf "FAIL: %s\n  expected: %s\n  actual:   %s\n" "$name" "$expected" "$actual" >&2
    fi
}

test_shape_only_dds_emit_warning() {
    local tmp; tmp=$(mktemp /tmp/lint-dd-shape.XXXXXX)
    cat > "$tmp" <<'EOF'
## What
shape-only story

## Done Definitions
- The schema includes a `parent_id` field
- The function signature accepts (story_id, command) arguments
- A new directory `obligations/` exists at the repo root
EOF
    # Note: "directory exists" but lacks the "file.*exists" pattern; this is intentionally shape-only.
    local stderr_out
    stderr_out=$(bash "$LINT" --file "$tmp" 2>&1 >/dev/null)
    local exit_code=$?
    _assert_eq "lint exits 0 (advisory) on shape-only DDs" "0" "$exit_code"
    _assert_contains "shape-only DDs emit WARNING" "WARNING" "$stderr_out"
    rm -f "$tmp"
}

test_behavior_paired_dds_silent() {
    local tmp; tmp=$(mktemp /tmp/lint-dd-behav.XXXXXX)
    cat > "$tmp" <<'EOF'
## What
behavior-paired story

## Done Definitions
- Running the script produces a JSON object with an `obligations_created` array
- The verifier emits P1=PASS when ticket creation succeeds
- A new ticket file appears under .tickets-tracker/ with the expected parent_id
EOF
    local stderr_out
    stderr_out=$(bash "$LINT" --file "$tmp" 2>&1 >/dev/null)
    local exit_code=$?
    _assert_eq "lint exits 0 (advisory) on behavior-paired DDs" "0" "$exit_code"
    _assert_not_contains "behavior-paired DDs silent (no WARNING)" "WARNING" "$stderr_out"
    rm -f "$tmp"
}

test_missing_dd_section_no_warning() {
    local tmp; tmp=$(mktemp /tmp/lint-dd-none.XXXXXX)
    cat > "$tmp" <<'EOF'
## What
story with no Done Definitions section
EOF
    local stderr_out
    stderr_out=$(bash "$LINT" --file "$tmp" 2>&1 >/dev/null)
    local exit_code=$?
    _assert_eq "lint exits 0 when section is absent" "0" "$exit_code"
    _assert_not_contains "absent DD section does not emit WARNING" "WARNING" "$stderr_out"
    rm -f "$tmp"
}

test_shape_only_dds_emit_warning
test_behavior_paired_dds_silent
test_missing_dd_section_no_warning

printf "lint-story-dds: PASS=%d FAIL=%d\n" "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]] || exit 1
exit 0
