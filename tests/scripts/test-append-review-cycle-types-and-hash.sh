#!/usr/bin/env bash
# tests/scripts/test-append-review-cycle-types-and-hash.sh
# Field-type and draft_hash computation contract tests for
# plugins/dso/scripts/append_review_cycle.py
#
# Behaviors under test:
#   test_n_is_int_type              — cycles[0].n is a JSON number (int), not a string
#   test_findings_count_is_int_type — cycles[0].findings_count is a JSON number (int)
#   test_verdict_in_enum            — cycles[0].verdict is one of {pass, fail, escalate}
#   test_draft_hash_format_sha256   — cycles[0].draft_hash is a 64-char lowercase hex string
#   test_draft_hash_computed_from_delta_output — caller computes sha256 over DELTA OUTPUT block,
#                                                passes it via --draft-hash, writer stores it verbatim
#
# Usage: bash tests/scripts/test-append-review-cycle-types-and-hash.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

# NOTE: -e intentionally omitted — test functions return non-zero by design
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRIPT="$REPO_ROOT/plugins/dso/scripts/append_review_cycle.py"

source "$REPO_ROOT/tests/lib/assert.sh"

# Global cleanup registry
declare -a CLEANUP_DIRS=()
trap 'rm -rf "${CLEANUP_DIRS[@]:-}"' EXIT

# ── Helpers ───────────────────────────────────────────────────────────────────

_make_tmpdir() {
    local tmp
    tmp=$(mktemp -d "${TMPDIR:-/tmp}/test-arc-types-XXXXXX")
    CLEANUP_DIRS+=("$tmp")
    echo "$tmp"
}

_make_artifact() {
    local dir="$1"
    local content="$2"
    local path
    path=$(mktemp "${dir}/artifact-XXXXXX.json")
    printf '%s' "$content" > "$path"
    echo "$path"
}

_run_cli() {
    python3 "$SCRIPT" "$@"
}

# Canonical valid sha256 hex string (64 lowercase hex chars) used as a stable
# placeholder when the test does not care about the specific hash value.
_PLACEHOLDER_HASH="a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2"

# ── Tests ─────────────────────────────────────────────────────────────────────

test_n_is_int_type() {
    local dir artifact result
    dir=$(_make_tmpdir)
    artifact=$(_make_artifact "$dir" '{"producer":"test"}')

    _run_cli \
        --artifact "$artifact" \
        --n 1 \
        --draft-hash "$_PLACEHOLDER_HASH" \
        --findings-count 0 \
        --verdict pass \
        --timestamp-iso "2026-06-01T00:00:00+00:00"

    result=$(python3 -c "
import json
d = json.load(open('$artifact'))
assert isinstance(d['cycles'][0]['n'], int), \
    'n is %s, expected int' % type(d['cycles'][0]['n']).__name__
print('ok')
" 2>&1)
    assert_eq "test_n_is_int_type: n field is JSON int" "ok" "$result"
}

test_findings_count_is_int_type() {
    local dir artifact result
    dir=$(_make_tmpdir)
    artifact=$(_make_artifact "$dir" '{"producer":"test"}')

    _run_cli \
        --artifact "$artifact" \
        --n 1 \
        --draft-hash "$_PLACEHOLDER_HASH" \
        --findings-count 3 \
        --verdict fail \
        --timestamp-iso "2026-06-01T00:00:00+00:00"

    result=$(python3 -c "
import json
d = json.load(open('$artifact'))
assert isinstance(d['cycles'][0]['findings_count'], int), \
    'findings_count is %s, expected int' % type(d['cycles'][0]['findings_count']).__name__
print('ok')
" 2>&1)
    assert_eq "test_findings_count_is_int_type: findings_count field is JSON int" "ok" "$result"
}

test_verdict_in_enum() {
    local dir artifact result
    dir=$(_make_tmpdir)
    artifact=$(_make_artifact "$dir" '{"producer":"test"}')

    _run_cli \
        --artifact "$artifact" \
        --n 1 \
        --draft-hash "$_PLACEHOLDER_HASH" \
        --findings-count 0 \
        --verdict pass \
        --timestamp-iso "2026-06-01T00:00:00+00:00"

    result=$(python3 -c "
import json
d = json.load(open('$artifact'))
assert d['cycles'][0]['verdict'] in ('pass', 'fail', 'escalate'), \
    'verdict %r not in allowed set' % d['cycles'][0]['verdict']
print('ok')
" 2>&1)
    assert_eq "test_verdict_in_enum: verdict is one of {pass, fail, escalate}" "ok" "$result"
}

test_draft_hash_format_sha256() {
    local dir artifact result
    dir=$(_make_tmpdir)
    artifact=$(_make_artifact "$dir" '{"producer":"test"}')

    _run_cli \
        --artifact "$artifact" \
        --n 1 \
        --draft-hash "$_PLACEHOLDER_HASH" \
        --findings-count 0 \
        --verdict pass \
        --timestamp-iso "2026-06-01T00:00:00+00:00"

    result=$(python3 -c "
import json, re
d = json.load(open('$artifact'))
h = d['cycles'][0]['draft_hash']
assert re.fullmatch(r'[a-f0-9]{64}', h), \
    'draft_hash %r does not match ^[a-f0-9]{64}$' % h
print('ok')
" 2>&1)
    assert_eq "test_draft_hash_format_sha256: draft_hash is 64-char lowercase hex" "ok" "$result"
}

test_draft_hash_computed_from_delta_output() {
    local dir artifact DELTA expected_hash actual_hash
    dir=$(_make_tmpdir)
    artifact=$(_make_artifact "$dir" '{"producer":"test"}')

    # Build a representative DELTA OUTPUT string — matches what a review producer
    # would emit as its DELTA OUTPUT block (the caller-side contract is to sha256
    # this string and pass the digest as --draft-hash).
    DELTA="=== DELTA OUTPUT ===
foo bar baz
"

    # Compute sha256 of the DELTA string via python3 hashlib (portable; avoids
    # shasum vs sha256sum divergence between macOS and Linux).
    expected_hash=$(python3 -c "
import hashlib, sys
print(hashlib.sha256(sys.argv[1].encode()).hexdigest())
" "$DELTA")

    _run_cli \
        --artifact "$artifact" \
        --n 1 \
        --draft-hash "$expected_hash" \
        --findings-count 2 \
        --verdict fail \
        --timestamp-iso "2026-06-01T00:00:00+00:00"

    actual_hash=$(python3 -c "import json; d=json.load(open('$artifact')); print(d['cycles'][0]['draft_hash'])")

    assert_eq "test_draft_hash_computed_from_delta_output: stored hash matches sha256 of DELTA block" \
        "$expected_hash" "$actual_hash"

    # Also confirm the stored value has the correct sha256 format (64-char hex).
    local format_check
    format_check=$(python3 -c "
import re, sys
h = sys.argv[1]
assert re.fullmatch(r'[a-f0-9]{64}', h), 'bad format: %r' % h
print('ok')
" "$actual_hash" 2>&1)
    assert_eq "test_draft_hash_computed_from_delta_output: stored hash has sha256 format" \
        "ok" "$format_check"
}

# ── Run all tests ─────────────────────────────────────────────────────────────

echo "=== test-append-review-cycle-types-and-hash.sh ==="

test_n_is_int_type
test_findings_count_is_int_type
test_verdict_in_enum
test_draft_hash_format_sha256
test_draft_hash_computed_from_delta_output

print_summary
