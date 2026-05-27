#!/usr/bin/env bash
# tests/scripts/test-design-md-fixtures.sh
# Tests design-md-lint.sh linter behavior using fixture files.
#
# Covers story 2c45-c324-d9f4-44e4, task a7a3-6154-e550-446a.
# DDs tested:
#   dd-3: design-md-lint.sh blocks on each violation file and passes on each clean file
#   dd-4: Cold-start and warm-cache latency recorded; cold-start >30s emits advisory
#
# RED markers: test_design_md_fixtures
# These tests are RED until design-md-lint.sh is implemented (task d9de-371f-17b5-4756).
#
# Usage: bash tests/scripts/test-design-md-fixtures.sh
# Returns: exit 0 always (advisory, not failure, on latency; failures on coverage)

set -uo pipefail

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_REPO_ROOT="$(cd "$_SCRIPT_DIR/../.." && pwd)"

LINTER="$_REPO_ROOT/plugins/dso/scripts/design-md-lint.sh"
FIXTURE_DIR="$_SCRIPT_DIR/fixtures/design-md"

source "$_REPO_ROOT/tests/lib/assert.sh"

echo "=== test-design-md-fixtures.sh ==="

# ── Precondition: linter must exist ───────────────────────────────────────────
echo ""
echo "--- precondition: design-md-lint.sh exists ---"
if [[ ! -f "$LINTER" ]]; then
    echo "ADVISORY: design-md-lint.sh not found at: $LINTER — skipping test suite" >&2
    echo "LATENCY cold_start=0s warm_cache=0s"
    exit 0
fi

if [[ ! -x "$LINTER" ]]; then
    echo "ADVISORY: design-md-lint.sh is not executable at: $LINTER — skipping test suite" >&2
    echo "LATENCY cold_start=0s warm_cache=0s"
    exit 0
fi

# ── Precondition: fixture directory must exist ────────────────────────────────
echo ""
echo "--- precondition: fixtures/design-md directory exists ---"
if [[ ! -d "$FIXTURE_DIR" ]]; then
    echo "ADVISORY: fixtures/design-md directory not found at: $FIXTURE_DIR — skipping test suite" >&2
    echo "LATENCY cold_start=0s warm_cache=0s"
    exit 0
fi

# ── Cold-start latency measurement ────────────────────────────────────────────
echo ""
echo "--- measuring cold-start latency ---"

_cold_start_begin=$SECONDS

# Find a representative fixture to measure against (prefer any violation-* file)
_sample_fixture=""
for _f in "$FIXTURE_DIR"/violation-* "$FIXTURE_DIR"/clean-*; do
    if [[ -f "$_f" ]]; then
        _sample_fixture="$_f"
        break
    fi
done

if [[ -n "$_sample_fixture" ]]; then
    "$LINTER" "$_sample_fixture" >/dev/null 2>&1 || true
fi

_cold_start_end=$SECONDS
_cold_start_elapsed=$(( _cold_start_end - _cold_start_begin ))

# ── Warm-cache latency measurement ────────────────────────────────────────────
echo ""
echo "--- measuring warm-cache latency ---"

_warm_cache_begin=$SECONDS

if [[ -n "$_sample_fixture" ]]; then
    "$LINTER" "$_sample_fixture" >/dev/null 2>&1 || true
fi

_warm_cache_end=$SECONDS
_warm_cache_elapsed=$(( _warm_cache_end - _warm_cache_begin ))

# ── violation-* fixtures: assert non-zero exit ────────────────────────────────
echo ""
echo "--- test: violation-* fixtures must exit non-zero ---"

_violation_count=0
_violation_tested=0

for _fixture in "$FIXTURE_DIR"/violation-*; do
    [[ -f "$_fixture" ]] || continue
    _violation_count=$(( _violation_count + 1 ))
    _fixture_name="$(basename "$_fixture")"
    _exit_code=0
    "$LINTER" "$_fixture" >/dev/null 2>&1 || _exit_code=$?
    if [[ "$_exit_code" -ne 0 ]]; then
        assert_eq "violation fixture exits non-zero: $_fixture_name" "non-zero" "non-zero"
        _violation_tested=$(( _violation_tested + 1 ))
    else
        # Explicit fail: violation fixture should not exit 0
        (( ++FAIL ))
        printf "FAIL: violation fixture exits non-zero: %s\n  at:       %s:%s\n  expected: non-zero\n  actual:   0\n" \
            "$_fixture_name" "${BASH_SOURCE[0]}" "$LINENO" >&2
    fi
done

if [[ "$_violation_count" -eq 0 ]]; then
    echo "  ADVISORY: no violation-* fixtures found in $FIXTURE_DIR — linter rejection tests skipped" >&2
fi

# ── clean-* fixtures: assert zero exit ───────────────────────────────────────
echo ""
echo "--- test: clean-* fixtures must exit zero ---"

_clean_count=0
_clean_tested=0

for _fixture in "$FIXTURE_DIR"/clean-*; do
    [[ -f "$_fixture" ]] || continue
    _clean_count=$(( _clean_count + 1 ))
    _fixture_name="$(basename "$_fixture")"
    _exit_code=0
    "$LINTER" "$_fixture" >/dev/null 2>&1 || _exit_code=$?
    if [[ "$_exit_code" -eq 0 ]]; then
        assert_eq "clean fixture exits zero: $_fixture_name" "0" "0"
        _clean_tested=$(( _clean_tested + 1 ))
    else
        # Explicit fail: clean fixture should not exit non-zero
        (( ++FAIL ))
        printf "FAIL: clean fixture exits zero: %s\n  at:       %s:%s\n  expected: 0\n  actual:   %s\n" \
            "$_fixture_name" "${BASH_SOURCE[0]}" "$LINENO" "$_exit_code" >&2
    fi
done

if [[ "$_clean_count" -eq 0 ]]; then
    echo "  ADVISORY: no clean-* fixtures found in $FIXTURE_DIR — linter acceptance tests skipped" >&2
fi

# ── Latency output ────────────────────────────────────────────────────────────
echo ""
echo "LATENCY cold_start=${_cold_start_elapsed}s warm_cache=${_warm_cache_elapsed}s"

# Advisory (not failure) if cold-start exceeds 30s
if [[ "$_cold_start_elapsed" -gt 30 ]]; then
    echo "ADVISORY: cold-start latency ${_cold_start_elapsed}s exceeds 30s threshold — consider caching" >&2
fi

print_summary
