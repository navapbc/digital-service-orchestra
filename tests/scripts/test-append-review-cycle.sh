#!/usr/bin/env bash
# tests/scripts/test-append-review-cycle.sh
# Behavioral tests for plugins/dso/scripts/append_review_cycle.py
#
# Behaviors under test:
#   test_append_preserves_prior_cycles  — artifact with 2 existing cycles → becomes 3 after append
#   test_lazy_migration_initializes     — artifact without cycles[] → cycles[] created with 1 entry
#   test_preserves_other_keys           — top-level producer/findings/tier keys survive append
#   test_draft_hash_recorded            — appended entry's draft_hash matches CLI argument
#   test_rejects_unknown_verdict        — --verdict garbage causes non-zero exit
#
# Usage: bash tests/scripts/test-append-review-cycle.sh
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
    tmp=$(mktemp -d "${TMPDIR:-/tmp}/test-arc-XXXXXX")
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

# ── Tests ─────────────────────────────────────────────────────────────────────

test_append_preserves_prior_cycles() {
    local dir artifact existing_json cycle_count
    dir=$(_make_tmpdir)
    existing_json='{"producer":"test","cycles":[{"n":1,"draft_hash":"aaa","findings_count":2,"verdict":"fail","timestamp_iso":"2026-01-01T00:00:00+00:00"},{"n":2,"draft_hash":"bbb","findings_count":1,"verdict":"fail","timestamp_iso":"2026-01-02T00:00:00+00:00"}]}'
    artifact=$(_make_artifact "$dir" "$existing_json")

    _run_cli \
        --artifact "$artifact" \
        --n 3 \
        --draft-hash "ccc" \
        --findings-count 0 \
        --verdict pass \
        --timestamp-iso "2026-01-03T00:00:00+00:00"

    cycle_count=$(python3 -c "import json; d=json.load(open('$artifact')); print(len(d['cycles']))")
    assert_eq "test_append_preserves_prior_cycles: cycles length is 3" "3" "$cycle_count"
}

test_lazy_migration_initializes() {
    local dir artifact existing_json cycle_count
    dir=$(_make_tmpdir)
    existing_json='{"producer":"test","findings":[]}'
    artifact=$(_make_artifact "$dir" "$existing_json")

    _run_cli \
        --artifact "$artifact" \
        --n 1 \
        --draft-hash "ddd" \
        --findings-count 5 \
        --verdict fail \
        --timestamp-iso "2026-02-01T00:00:00+00:00"

    cycle_count=$(python3 -c "import json; d=json.load(open('$artifact')); print(len(d['cycles']))")
    assert_eq "test_lazy_migration_initializes: cycles length is 1" "1" "$cycle_count"
}

test_preserves_other_keys() {
    local dir artifact existing_json producer_val findings_val tier_val
    dir=$(_make_tmpdir)
    existing_json='{"producer":"my-agent","findings":[{"id":1}],"tier":"deep"}'
    artifact=$(_make_artifact "$dir" "$existing_json")

    _run_cli \
        --artifact "$artifact" \
        --n 1 \
        --draft-hash "eee" \
        --findings-count 1 \
        --verdict fail \
        --timestamp-iso "2026-03-01T00:00:00+00:00"

    producer_val=$(python3 -c "import json; d=json.load(open('$artifact')); print(d['producer'])")
    findings_val=$(python3 -c "import json; d=json.load(open('$artifact')); print(len(d['findings']))")
    tier_val=$(python3 -c "import json; d=json.load(open('$artifact')); print(d['tier'])")

    assert_eq "test_preserves_other_keys: producer unchanged" "my-agent" "$producer_val"
    assert_eq "test_preserves_other_keys: findings unchanged" "1" "$findings_val"
    assert_eq "test_preserves_other_keys: tier unchanged" "deep" "$tier_val"
}

test_draft_hash_recorded() {
    local dir artifact existing_json draft_hash_in actual_hash
    dir=$(_make_tmpdir)
    existing_json='{"producer":"test"}'
    artifact=$(_make_artifact "$dir" "$existing_json")
    draft_hash_in="abc123def456abc123def456abc123def456abc123def456abc123def456abc1"

    _run_cli \
        --artifact "$artifact" \
        --n 1 \
        --draft-hash "$draft_hash_in" \
        --findings-count 0 \
        --verdict pass \
        --timestamp-iso "2026-04-01T00:00:00+00:00"

    actual_hash=$(python3 -c "import json; d=json.load(open('$artifact')); print(d['cycles'][0]['draft_hash'])")
    assert_eq "test_draft_hash_recorded: draft_hash matches CLI arg" "$draft_hash_in" "$actual_hash"
}

test_rejects_unknown_verdict() {
    local dir artifact existing_json exit_code
    dir=$(_make_tmpdir)
    existing_json='{"producer":"test"}'
    artifact=$(_make_artifact "$dir" "$existing_json")

    exit_code=0
    _run_cli \
        --artifact "$artifact" \
        --n 1 \
        --draft-hash "fff" \
        --findings-count 0 \
        --verdict garbage \
        --timestamp-iso "2026-05-01T00:00:00+00:00" \
        2>/dev/null || exit_code=$?

    assert_ne "test_rejects_unknown_verdict: exits non-zero" "0" "$exit_code"
}

# ── Run all tests ─────────────────────────────────────────────────────────────

echo "=== test-append-review-cycle.sh ==="

test_append_preserves_prior_cycles
test_lazy_migration_initializes
test_preserves_other_keys
test_draft_hash_recorded
test_rejects_unknown_verdict

print_summary
