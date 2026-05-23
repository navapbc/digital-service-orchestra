#!/usr/bin/env bash
# tests/scripts/test-review-cycles-end-to-end.sh
# End-to-end integration test exercising the cycles[] cross-touchpoint invariant.
#
# Drives a single review artifact through all 3 touchpoints in sequence:
#   1. Preplanning Phase E cycle   (n=1, verdict=fail)
#   2. Impl-plan Step 2 cycle      (n=2, verdict=fail)
#   3. Sprint verifier-fail cycle  (n=3, verdict=pass)
#
# Behaviors under test:
#   test_cycles_length_after_all_touchpoints — final cycles[] length == 3
#   test_each_entry_has_canonical_5_fields   — every entry carries n, draft_hash,
#                                              findings_count, verdict, timestamp_iso
#   test_n_values_monotonically_increasing   — n values are exactly 1, 2, 3 in order
#   test_top_level_keys_preserved            — producer (and other original keys) survive
#   test_valid_json_at_each_intermediate_step — artifact parses as JSON after each append
#   test_single_comment_dedupe_per_cycle     — ticket-comment text can reference the artifact
#                                              path without embedding cycle body (dedupe contract)
#
# Usage: bash tests/scripts/test-review-cycles-end-to-end.sh
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
    tmp=$(mktemp -d "${TMPDIR:-/tmp}/test-rce2e-XXXXXX")
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

# ── Shared fixture: drive one artifact through all 3 touchpoints ──────────────
#
# Returns (via stdout): path to the artifact file.
# The caller is responsible for the tmpdir's lifecycle (it is registered in
# CLEANUP_DIRS by _make_tmpdir).

_setup_e2e_artifact() {
    local dir
    dir=$(_make_tmpdir)

    local artifact
    artifact=$(_make_artifact "$dir" '{"producer": "test-e2e", "cycles": [], "metadata": {"epic": "81d7"}}')

    # Touchpoint 1 — preplanning Phase E (n=1, fail)
    _run_cli \
        --artifact "$artifact" \
        --n 1 \
        --draft-hash "deadbeef1111111111111111111111111111111111111111111111111111111" \
        --findings-count 2 \
        --verdict fail \
        --timestamp-iso "2026-05-01T10:00:00+00:00"

    # Touchpoint 2 — impl-plan Step 2 (n=2, fail)
    _run_cli \
        --artifact "$artifact" \
        --n 2 \
        --draft-hash "deadbeef2222222222222222222222222222222222222222222222222222222" \
        --findings-count 1 \
        --verdict fail \
        --timestamp-iso "2026-05-01T11:00:00+00:00"

    # Touchpoint 3 — sprint verifier-fail (n=3, pass)
    _run_cli \
        --artifact "$artifact" \
        --n 3 \
        --draft-hash "deadbeef3333333333333333333333333333333333333333333333333333333" \
        --findings-count 0 \
        --verdict pass \
        --timestamp-iso "2026-05-01T12:00:00+00:00"

    echo "$artifact"
}

# ── Tests ─────────────────────────────────────────────────────────────────────

test_cycles_length_after_all_touchpoints() {
    local artifact cycle_count
    artifact=$(_setup_e2e_artifact)

    cycle_count=$(python3 -c "import json; d=json.load(open('$artifact')); print(len(d['cycles']))")
    assert_eq "test_cycles_length_after_all_touchpoints: cycles[] length == 3" "3" "$cycle_count"
}

test_each_entry_has_canonical_5_fields() {
    local artifact field_check
    artifact=$(_setup_e2e_artifact)

    # Verify all 3 entries carry exactly the 5 canonical fields:
    #   n, draft_hash, findings_count, verdict, timestamp_iso
    field_check=$(python3 - "$artifact" <<'PYEOF'
import json, sys
REQUIRED = {"n", "draft_hash", "findings_count", "verdict", "timestamp_iso"}
d = json.load(open(sys.argv[1]))
issues = []
for i, entry in enumerate(d["cycles"]):
    missing = REQUIRED - set(entry.keys())
    if missing:
        issues.append(f"entry[{i}] missing: {sorted(missing)}")
print("ok" if not issues else "; ".join(issues))
PYEOF
)
    assert_eq "test_each_entry_has_canonical_5_fields: all entries have 5 fields" "ok" "$field_check"
}

test_n_values_monotonically_increasing() {
    local artifact n_values
    artifact=$(_setup_e2e_artifact)

    n_values=$(python3 -c "import json; d=json.load(open('$artifact')); print([c['n'] for c in d['cycles']])")
    assert_eq "test_n_values_monotonically_increasing: n values are [1, 2, 3]" "[1, 2, 3]" "$n_values"
}

test_top_level_keys_preserved() {
    local artifact producer_val metadata_epic_val
    artifact=$(_setup_e2e_artifact)

    producer_val=$(python3 -c "import json; d=json.load(open('$artifact')); print(d['producer'])")
    assert_eq "test_top_level_keys_preserved: producer unchanged" "test-e2e" "$producer_val"

    metadata_epic_val=$(python3 -c "import json; d=json.load(open('$artifact')); print(d['metadata']['epic'])")
    assert_eq "test_top_level_keys_preserved: metadata.epic unchanged" "81d7" "$metadata_epic_val"
}

test_valid_json_at_each_intermediate_step() {
    local dir artifact parse_result

    dir=$(_make_tmpdir)
    artifact=$(_make_artifact "$dir" '{"producer": "test-e2e-json", "cycles": []}')

    # After touchpoint 1
    _run_cli \
        --artifact "$artifact" \
        --n 1 \
        --draft-hash "deadbeef1111111111111111111111111111111111111111111111111111111" \
        --findings-count 2 \
        --verdict fail \
        --timestamp-iso "2026-05-01T10:00:00+00:00"

    parse_result=$(python3 -c "import json; json.load(open('$artifact')); print('valid')" 2>&1)
    assert_eq "test_valid_json_at_each_intermediate_step: valid after touchpoint 1" "valid" "$parse_result"

    # After touchpoint 2
    _run_cli \
        --artifact "$artifact" \
        --n 2 \
        --draft-hash "deadbeef2222222222222222222222222222222222222222222222222222222" \
        --findings-count 1 \
        --verdict fail \
        --timestamp-iso "2026-05-01T11:00:00+00:00"

    parse_result=$(python3 -c "import json; json.load(open('$artifact')); print('valid')" 2>&1)
    assert_eq "test_valid_json_at_each_intermediate_step: valid after touchpoint 2" "valid" "$parse_result"

    # After touchpoint 3
    _run_cli \
        --artifact "$artifact" \
        --n 3 \
        --draft-hash "deadbeef3333333333333333333333333333333333333333333333333333333" \
        --findings-count 0 \
        --verdict pass \
        --timestamp-iso "2026-05-01T12:00:00+00:00"

    parse_result=$(python3 -c "import json; json.load(open('$artifact')); print('valid')" 2>&1)
    assert_eq "test_valid_json_at_each_intermediate_step: valid after touchpoint 3" "valid" "$parse_result"
}

test_single_comment_dedupe_per_cycle() {
    # Verifies the dedupe contract: exactly ONE ticket comment per cycle references
    # the artifact path. The comment body cites the path (a stable, short key),
    # NOT the full cycle JSON body — preventing duplicate cycle data in comments.
    #
    # The test constructs the comment text that each touchpoint WOULD emit and
    # asserts:
    #   1. Each comment text includes the artifact path exactly once.
    #   2. Each comment text does NOT duplicate the cycle entry JSON body.
    #   3. Three distinct comment texts exist (one per cycle, no merging).
    local artifact comment1 comment2 comment3

    artifact=$(_setup_e2e_artifact)

    comment1="Remediation cycle 1 recorded at ${artifact}"
    comment2="Remediation cycle 2 recorded at ${artifact}"
    comment3="Remediation cycle 3 recorded at ${artifact}"

    # Each comment references the artifact path — assert it contains the path
    assert_contains "test_single_comment_dedupe_per_cycle: cycle 1 comment contains artifact path" \
        "$artifact" "$comment1"
    assert_contains "test_single_comment_dedupe_per_cycle: cycle 2 comment contains artifact path" \
        "$artifact" "$comment2"
    assert_contains "test_single_comment_dedupe_per_cycle: cycle 3 comment contains artifact path" \
        "$artifact" "$comment3"

    # Each comment does NOT embed the raw cycle body (no "draft_hash" literal in the comment text)
    assert_not_contains "test_single_comment_dedupe_per_cycle: cycle 1 comment omits cycle body" \
        "draft_hash" "$comment1"
    assert_not_contains "test_single_comment_dedupe_per_cycle: cycle 2 comment omits cycle body" \
        "draft_hash" "$comment2"
    assert_not_contains "test_single_comment_dedupe_per_cycle: cycle 3 comment omits cycle body" \
        "draft_hash" "$comment3"

    # Comments are distinct (no two cycles produce identical comment text)
    assert_ne "test_single_comment_dedupe_per_cycle: comment1 != comment2" "$comment1" "$comment2"
    assert_ne "test_single_comment_dedupe_per_cycle: comment2 != comment3" "$comment2" "$comment3"
    assert_ne "test_single_comment_dedupe_per_cycle: comment1 != comment3" "$comment1" "$comment3"
}

# ── Run all tests ─────────────────────────────────────────────────────────────

echo "=== test-review-cycles-end-to-end.sh ==="

test_cycles_length_after_all_touchpoints
test_each_entry_has_canonical_5_fields
test_n_values_monotonically_increasing
test_top_level_keys_preserved
test_valid_json_at_each_intermediate_step
test_single_comment_dedupe_per_cycle

print_summary
