#!/usr/bin/env bash
# tests/scripts/test-validate-source-audit-integration.sh
# Integration tests verifying that validate.sh wires audit-closure-checks-source-consumers.sh
# correctly:
#   * validate.sh source contains a reference to the audit script
#   * the integration is conditional on VALIDATE_SKIP_PLUGIN_CHECKS=1 (skip path)
#   * the integration is conditional on the audit script's presence (backward-compat skip)
#   * the steady-state full-bucket comparison (gap finding 6): two consecutive
#     audit runs produce identical bucket counts (all 6 buckets +
#     `unbucketed_matches` + `dynamic_load_count` — 8 numeric fields total),
#     OR `reconciliation_status == "incomplete"`.
#   * the T2.5 contract doc exists at the expected path.
#
# Testing Mode: GREEN — validates T4 implementation against the existing audit
# script (T2 GREEN) and validate.sh integration (this commit).
#
# Story coverage: 7e2c-2f4c-cd95-4e60 (SC4 + SC5 source-file consumer audit),
# task cdd3-3c72-e1bf-46d9 (T4 validate.sh integration + docs).
#
# Gap-analysis findings encoded in this test:
#   Finding 5 — contract doc at plugins/dso/docs/contracts/
#               closure-checks-source-audit-output.md is owned by T2.5.
#               This test asserts its existence with a clear message pointing
#               to T2.5 when missing.
#   Finding 6 — steady-state full-bucket comparison across all 8 numeric fields.
#   Finding 7 — dry-run policy documented; validate.sh integration must NOT
#               invoke any recipe applier (this test asserts the audit script,
#               not apply-bucket-recipes.sh, is the script wired in validate.sh).
#
# Usage: bash tests/scripts/test-validate-source-audit-integration.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

VALIDATE_SH="$DSO_PLUGIN_DIR/scripts/validate.sh"
AUDIT_SCRIPT="$DSO_PLUGIN_DIR/scripts/audit-closure-checks-source-consumers.sh"
CONTRACT_DOC="$DSO_PLUGIN_DIR/docs/contracts/closure-checks-source-audit-output.md"

# Per-test cleanup tracking — each tempdir is removed via the EXIT trap.
_CLEANUP_DIRS=()
trap '_cleanup_all' EXIT
_cleanup_all() {
    for d in "${_CLEANUP_DIRS[@]:-}"; do
        [ -n "$d" ] && [ -d "$d" ] && rm -rf "$d" 2>/dev/null || true
    done
    return 0
}

echo "=== test-validate-source-audit-integration.sh ==="

# ─────────────────────────────────────────────────────────────────────────────
# Test 1: validate.sh source references the audit script
# Given: validate.sh exists
# When:  grep for audit-closure-checks-source-consumers
# Then:  at least one match
# ─────────────────────────────────────────────────────────────────────────────
test_validate_references_audit_script() {
    _snapshot_fail

    if grep -q 'audit-closure-checks-source-consumers' "$VALIDATE_SH" 2>/dev/null; then
        has_ref="yes"
    else
        has_ref="no"
    fi
    assert_eq "validate.sh references audit-closure-checks-source-consumers.sh" "yes" "$has_ref"

    assert_pass_if_clean "test_validate_references_audit_script"
}

# ─────────────────────────────────────────────────────────────────────────────
# Test 2: integration is skipped under VALIDATE_SKIP_PLUGIN_CHECKS=1
# Given: validate.sh source
# When:  inspect the launch + reporting blocks
# Then:  the audit-source-consumers wiring sits inside a VALIDATE_SKIP_PLUGIN_CHECKS
#        guard block (along with the other plugin checks).
# ─────────────────────────────────────────────────────────────────────────────
test_integration_respects_skip_plugin_checks() {
    _snapshot_fail

    # The audit wiring must appear inside a VALIDATE_SKIP_PLUGIN_CHECKS-guarded
    # block. We assert the structural co-location by checking that, between the
    # nearest VALIDATE_SKIP_PLUGIN_CHECKS guard and the next `fi` that closes
    # it, the audit script reference is present.
    #
    # Use python to do a robust structural scan — three guard blocks contain
    # plugin checks (LAUNCHED_CHECKS, parallel-launch, non-verbose-report,
    # verbose-tally). All four must reference the audit-source-consumers wiring.
    local result
    result=$(python3 - "$VALIDATE_SH" <<'PYEOF'
import re
import sys

src = open(sys.argv[1], "r", encoding="utf-8").read()
lines = src.splitlines()

# Find every `if [ "${VALIDATE_SKIP_PLUGIN_CHECKS:-}" != "1" ]; then` block.
guarded_blocks = []
i = 0
while i < len(lines):
    if re.search(r'VALIDATE_SKIP_PLUGIN_CHECKS:-.*!=\s*"1"', lines[i]):
        # Find matching `fi` at the same nesting depth.
        depth = 1
        start = i
        j = i + 1
        while j < len(lines) and depth > 0:
            s = lines[j].strip()
            # Track nested if/fi.
            if re.match(r'^if\s|^if$', s) or s.endswith(" then") or s == "then":
                if re.match(r'^if\b', s):
                    depth += 1
            if s == "fi":
                depth -= 1
            j += 1
        guarded_blocks.append((start, j))
        i = j
    else:
        i += 1

audit_blocks = 0
for start, end in guarded_blocks:
    body = "\n".join(lines[start:end])
    if "audit-closure-checks-source-consumers" in body or "audit-source-consumers" in body:
        audit_blocks += 1

# We expect the audit wiring in at least three guarded blocks:
#   1. LAUNCHED_CHECKS extension
#   2. parallel-launch invocation
#   3. report_check (non-verbose) AND tally_check (verbose) — either one or
#      both may live inside a shared verbose-mode guard nested in the outer
#      VALIDATE_SKIP_PLUGIN_CHECKS block, so 3 is the floor.
print(audit_blocks)
PYEOF
)
    # Accept >= 3 guarded blocks (LAUNCHED_CHECKS, parallel-launch, report+tally combo).
    local audit_blocks="${result:-0}"
    local meets_floor="no"
    if [ "$audit_blocks" -ge 3 ] 2>/dev/null; then
        meets_floor="yes"
    fi
    assert_eq "audit wiring is inside VALIDATE_SKIP_PLUGIN_CHECKS guards (>=3 blocks; got $audit_blocks)" "yes" "$meets_floor"

    assert_pass_if_clean "test_integration_respects_skip_plugin_checks"
}

# ─────────────────────────────────────────────────────────────────────────────
# Test 3: integration is conditional on audit script presence (backward-compat)
# Given: validate.sh source
# When:  inspect the wiring
# Then:  every audit-script reference is gated on `[ -f "$PLUGIN_SCRIPTS/audit-closure-checks-source-consumers.sh" ]`
#        so older plugin checkouts that lack the audit script continue to work.
# ─────────────────────────────────────────────────────────────────────────────
test_integration_respects_audit_script_presence() {
    _snapshot_fail

    # Count audit references that are gated on a `-f ... audit-closure-checks-source-consumers.sh` guard.
    local total_refs gated_refs
    total_refs=$(grep -c 'audit-source-consumers\|audit-closure-checks-source-consumers' "$VALIDATE_SH" || true)
    gated_refs=$(grep -cE '\[ -f .*audit-closure-checks-source-consumers\.sh.*\]' "$VALIDATE_SH" || true)
    : "${total_refs:=0}" "${gated_refs:=0}"

    # We expect at least three gating guards (LAUNCHED_CHECKS, parallel launch,
    # report+tally). Each pairs with at least one reference on the same line or
    # in its body.
    local has_gating="no"
    if [ "$gated_refs" -ge 3 ] 2>/dev/null; then
        has_gating="yes"
    fi
    assert_eq "audit references are gated on script-presence (>=3 -f guards; got $gated_refs of $total_refs refs)" "yes" "$has_gating"

    assert_pass_if_clean "test_integration_respects_audit_script_presence"
}

# ─────────────────────────────────────────────────────────────────────────────
# Test 4: validate.sh does NOT invoke a recipe applier (dry-run policy)
# Given: validate.sh source
# When:  grep for apply-bucket-recipes or --apply flags
# Then:  no recipe-applier invocation appears (per dry-run policy / gap finding 7)
# ─────────────────────────────────────────────────────────────────────────────
test_validate_does_not_invoke_recipe_applier() {
    _snapshot_fail

    # The recipe applier (T3 scope) MUST NOT be wired into validate.sh.
    # Specifically: no `apply-bucket-recipes` reference and no `--apply` flag.
    local applier_refs apply_flag_refs
    applier_refs=$(grep -c 'apply-bucket-recipes' "$VALIDATE_SH" || true)
    apply_flag_refs=$(grep -cE '[^-]--apply([[:space:]]|$)' "$VALIDATE_SH" || true)
    : "${applier_refs:=0}" "${apply_flag_refs:=0}"

    assert_eq "validate.sh does NOT invoke apply-bucket-recipes" "0" "$applier_refs"
    assert_eq "validate.sh does NOT pass --apply flag anywhere" "0" "$apply_flag_refs"

    assert_pass_if_clean "test_validate_does_not_invoke_recipe_applier"
}

# ─────────────────────────────────────────────────────────────────────────────
# Test 5: steady-state full-bucket comparison (gap finding 6)
#
# Run the audit twice against a frozen fixture tree; the two consecutive runs'
# bucket counts (all six buckets + `unbucketed_matches` + `dynamic_load_count`)
# must be identical (8 numeric fields), OR `reconciliation_status == "incomplete"`.
#
# This is the contract the recipe applier and any post-migration tool rely on:
# in steady state the audit output is reproducible bucket-by-bucket.
# ─────────────────────────────────────────────────────────────────────────────
test_steady_state_full_bucket_comparison() {
    _snapshot_fail

    if [ ! -f "$AUDIT_SCRIPT" ]; then
        assert_eq "audit script exists (prereq)" "exists" "missing"
        return
    fi

    local tempdir
    tempdir=$(mktemp -d "${TMPDIR:-/tmp}/test-validate-source-audit-steady.XXXXXX")
    _CLEANUP_DIRS+=("$tempdir")

    # Fixture tree spanning multiple buckets so the comparison exercises
    # a non-empty count for each bucket where reasonable.
    mkdir -p "$tempdir/plugins" "$tempdir/tests" "$tempdir/docs"

    # section-name-reference + user-facing-copy (markdown prose)
    printf '%s\n' "## Closure Checks" "" "Error: please add a closure-chk item before closing." \
        > "$tempdir/plugins/a.md"

    # semantic-consumer (parser keyword on a line with the literal)
    printf '%s\n' "# parses '## Closure Checks' section" \
        > "$tempdir/plugins/parser.py"

    # test-asserting-on-structure
    printf '%s\n' "assert_contains 'Closure Checks' \"\$output\"" \
        > "$tempdir/tests/t.sh"

    # file-path-reference (mention known-schema-consumer file)
    printf '%s\n' "See coherence-walk.sh for Closure Checks gating." \
        > "$tempdir/docs/refs.md"

    # migration-in-progress (file with MIGRATION-IN-PROGRESS marker)
    printf '%s\n' "MIGRATION-IN-PROGRESS" "## Closure Checks" \
        > "$tempdir/plugins/migrating.md"

    # ── Run 1 ────────────────────────────────────────────────────────────────
    bash "$AUDIT_SCRIPT" --target "$tempdir" > /dev/null 2>&1 || true
    local json1
    # shellcheck disable=SC2012  # ls -1t for mtime sort; artifact names controlled.
    json1=$(ls -1t "$tempdir/plugins/dso/.audit-output"/closure-checks-migration-*.json 2>/dev/null | head -1)

    if [ -z "$json1" ] || [ ! -f "$json1" ]; then
        assert_eq "Run 1 produced a JSON artifact" "yes" "no"
        return
    fi

    # ── Run 2 ────────────────────────────────────────────────────────────────
    sleep 1  # ensure timestamp uniqueness; the audit script uses sub-second nano fallback but we belt-and-braces here
    bash "$AUDIT_SCRIPT" --target "$tempdir" > /dev/null 2>&1 || true
    local json2
    # shellcheck disable=SC2012
    json2=$(ls -1t "$tempdir/plugins/dso/.audit-output"/closure-checks-migration-*.json 2>/dev/null | head -1)

    if [ -z "$json2" ] || [ ! -f "$json2" ] || [ "$json1" = "$json2" ]; then
        assert_eq "Run 2 produced a distinct JSON artifact" "yes" "no"
        return
    fi

    # ── Compare across all 8 numeric fields ──────────────────────────────────
    # 6 bucket counts + unbucketed_matches + dynamic_load_count.
    # If steady-state holds, the diff is zero across the tuple.
    # If reconciliation_status is "incomplete" for either run, the test passes
    # by virtue of the documented alternative path.
    local comparison
    comparison=$(python3 - "$json1" "$json2" <<'PYEOF'
import json, sys

a = json.load(open(sys.argv[1]))
b = json.load(open(sys.argv[2]))

BUCKETS = (
    "migration-in-progress",
    "test-asserting-on-structure",
    "semantic-consumer",
    "user-facing-copy",
    "section-name-reference",
    "file-path-reference",
)

def tup(env):
    return (
        *[len(env.get("buckets", {}).get(b, [])) for b in BUCKETS],
        len(env.get("unbucketed_matches", [])),
        env.get("dynamic_load_count", 0),
    )

ta = tup(a)
tb = tup(b)

if a.get("reconciliation_status") == "incomplete" or b.get("reconciliation_status") == "incomplete":
    print("INCOMPLETE_OK")
elif ta == tb:
    print("STEADY_STATE_OK")
else:
    diffs = []
    fields = list(BUCKETS) + ["unbucketed_matches", "dynamic_load_count"]
    for name, x, y in zip(fields, ta, tb):
        if x != y:
            diffs.append(f"{name}: run1={x} run2={y}")
    print("DRIFT: " + "; ".join(diffs))
PYEOF
)

    case "$comparison" in
        "STEADY_STATE_OK"|"INCOMPLETE_OK")
            assert_eq "steady-state full-bucket comparison" "ok" "ok"
            ;;
        *)
            assert_eq "steady-state full-bucket comparison ($comparison)" "ok" "drift"
            ;;
    esac

    assert_pass_if_clean "test_steady_state_full_bucket_comparison"
}

# ─────────────────────────────────────────────────────────────────────────────
# Test 6: T2.5 contract doc exists
# Gap finding 5 — closure-checks-source-audit-output.md is owned by T2.5.
# When T2.5 has not yet landed this test fails with a clear pointer.
# ─────────────────────────────────────────────────────────────────────────────
test_contract_doc_exists() {
    _snapshot_fail

    local exists="no"
    if [ -f "$CONTRACT_DOC" ]; then
        exists="yes"
    fi
    # Clear failure message: when missing, points at T2.5.
    if [ "$exists" != "yes" ]; then
        echo "  NOTE: $CONTRACT_DOC is missing." >&2
        echo "  Expected deliverable: T2.5 of story 7e2c-2f4c-cd95-4e60 — closure-checks source-audit JSON output contract." >&2
    fi
    assert_eq "T2.5 contract doc closure-checks-source-audit-output.md exists" "yes" "$exists"

    assert_pass_if_clean "test_contract_doc_exists"
}

# ─────────────────────────────────────────────────────────────────────────────
# Test 7: design doc has source-audit + bucket recipes + dry-run policy sections
# ─────────────────────────────────────────────────────────────────────────────
test_design_doc_sections_present() {
    _snapshot_fail

    local design_doc="$PLUGIN_ROOT/docs/designs/closure-checks/README.md"
    local has_source_audit has_bucket_recipes has_dry_run
    has_source_audit="no"; has_bucket_recipes="no"; has_dry_run="no"

    if [ -f "$design_doc" ]; then
        grep -qE '^##.*Source-file consumer audit' "$design_doc" && has_source_audit="yes"
        grep -qE '^##.*Bucket recipes' "$design_doc" && has_bucket_recipes="yes"
        grep -qE '^##.*Dry-run policy' "$design_doc" && has_dry_run="yes"
    fi

    assert_eq "design doc has 'Source-file consumer audit' section" "yes" "$has_source_audit"
    assert_eq "design doc has 'Bucket recipes' section" "yes" "$has_bucket_recipes"
    assert_eq "design doc has 'Dry-run policy' section" "yes" "$has_dry_run"

    assert_pass_if_clean "test_design_doc_sections_present"
}

# ─────────────────────────────────────────────────────────────────────────────
# Test 8: audit-output dir is gitignored
# ─────────────────────────────────────────────────────────────────────────────
test_audit_output_gitignored() {
    _snapshot_fail

    local gitignore="$PLUGIN_ROOT/.gitignore"
    local has_entry="no"
    if [ -f "$gitignore" ] && grep -qE '^plugins/dso/\.audit-output/?$' "$gitignore"; then
        has_entry="yes"
    fi
    assert_eq "root .gitignore contains plugins/dso/.audit-output/" "yes" "$has_entry"

    assert_pass_if_clean "test_audit_output_gitignored"
}

# ─────────────────────────────────────────────────────────────────────────────
# Run all tests
# ─────────────────────────────────────────────────────────────────────────────
test_validate_references_audit_script
test_integration_respects_skip_plugin_checks
test_integration_respects_audit_script_presence
test_validate_does_not_invoke_recipe_applier
test_steady_state_full_bucket_comparison
test_contract_doc_exists
test_design_doc_sections_present
test_audit_output_gitignored

print_summary
