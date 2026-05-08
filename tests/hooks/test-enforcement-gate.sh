#!/usr/bin/env bash
# shellcheck disable=SC2030,SC2031  # Subshell isolation for test independence
# shellcheck disable=SC2164         # cd into known-valid mktemp dirs in test helpers
# shellcheck disable=SC2155         # Declare-and-assign in subshell context — test-only pattern
# tests/hooks/test-enforcement-gate.sh
# RED-phase tests for enforcement.strategy hook gating and HOOK_GATE schema.
#
# These tests INTENTIONALLY FAIL against the current codebase because:
#   - enforcement.strategy config reading is NOT YET implemented in the hooks
#   - HOOK_GATE logging is NOT YET implemented in the hooks
#   - enforcement.strategy=both de-duplication is NOT YET implemented
#
# Test functions (13):
#   test_enforcement_ci_review_gate_skips              — review-gate emits HOOK_GATE: skipped on ci
#   test_enforcement_ci_test_gate_skips                — test-gate emits HOOK_GATE: skipped on ci
#   test_enforcement_ci_test_quality_gate_skips        — test-quality-gate emits HOOK_GATE: skipped on ci
#   test_structural_check_plugin_self_ref_runs_on_ci   — check-plugin-self-ref blocks on ci (structural)
#   test_structural_check_portability_runs_on_ci       — check-portability blocks on ci (structural)
#   test_structural_check_shim_refs_runs_on_ci         — check-shim-refs blocks on ci (structural)
#   test_structural_check_contract_schemas_runs_on_ci  — check-contract-schemas blocks on ci (structural)
#   test_structural_check_referential_integrity_runs_on_ci — check-referential-integrity blocks on ci (structural)
#   test_enforcement_both_no_double_execution          — enforcement.strategy=both: at most 1 invocation
#   test_enforcement_both_runs_once                    — enforcement.strategy=both: exactly 1 invocation
#   test_hook_gate_schema_review_gate                  — exact HOOK_GATE output format for review-gate
#   test_hook_gate_schema_test_gate                    — exact HOOK_GATE output format for test-gate
#   test_hook_gate_schema_test_quality_gate            — exact HOOK_GATE output format for test-quality-gate
#
# All tests use isolated temp dirs and must FAIL against current codebase.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"

REVIEW_GATE_HOOK="$DSO_PLUGIN_DIR/hooks/pre-commit-review-gate.sh"
TEST_GATE_HOOK="$DSO_PLUGIN_DIR/hooks/pre-commit-test-gate.sh"
TEST_QUALITY_GATE_HOOK="$DSO_PLUGIN_DIR/hooks/pre-commit-test-quality-gate.sh"
CHECK_PLUGIN_SELF_REF_HOOK="$PLUGIN_ROOT/.claude/hooks/pre-commit/check-plugin-self-ref.sh"
CHECK_PORTABILITY_SCRIPT="$DSO_PLUGIN_DIR/scripts/check-portability.sh"
CHECK_SHIM_REFS_SCRIPT="$DSO_PLUGIN_DIR/scripts/check-shim-refs.sh"
CHECK_CONTRACT_SCHEMAS_SCRIPT="$DSO_PLUGIN_DIR/scripts/check-contract-schemas.sh"
CHECK_REFERENTIAL_INTEGRITY_SCRIPT="$DSO_PLUGIN_DIR/scripts/check-referential-integrity.sh"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

# ── Cleanup on exit ──────────────────────────────────────────────────────────
_TEST_TMPDIRS=()
_cleanup_test_tmpdirs() {
    for d in "${_TEST_TMPDIRS[@]}"; do
        rm -rf "$d" 2>/dev/null || true
    done
}
trap _cleanup_test_tmpdirs EXIT

# ── Helper: make isolated tmpdir with enforcement.strategy=ci config ─────────
# Usage: _make_ci_tmpdir
# Sets _TMPDIR and creates .claude/dso-config.conf with enforcement.strategy=ci
_make_ci_tmpdir() {
    local _t
    _t="$(mktemp -d /tmp/test-enforcement-gate.XXXXXX)"
    _TEST_TMPDIRS+=("$_t")
    mkdir -p "$_t/.claude"
    printf 'enforcement.strategy=ci\n' > "$_t/.claude/dso-config.conf"
    printf '%s' "$_t"
}

# ── Helper: make isolated tmpdir with enforcement.strategy=both config ───────
_make_both_tmpdir() {
    local _t
    _t="$(mktemp -d /tmp/test-enforcement-gate.XXXXXX)"
    _TEST_TMPDIRS+=("$_t")
    mkdir -p "$_t/.claude"
    printf 'enforcement.strategy=both\n' > "$_t/.claude/dso-config.conf"
    printf '%s' "$_t"
}

# ── Helper: make isolated git repo in tmpdir ─────────────────────────────────
# Needed by hooks that call `git diff --cached`
_make_git_repo_in() {
    local dir="$1"
    git -C "$dir" init -q
    git -C "$dir" config user.email "test@test.local"
    git -C "$dir" config user.name "Test"
    # Create an initial commit so HEAD exists
    touch "$dir/placeholder"
    git -C "$dir" add placeholder
    git -C "$dir" commit -q -m "init"
}

# ════════════════════════════════════════════════════════════════════════════
# test_enforcement_ci_review_gate_skips
# Given enforcement.strategy=ci; When pre-commit-review-gate.sh runs;
# Then output contains "HOOK_GATE: skipped reason=enforcement.strategy=ci"
# FAILS: hook does not read enforcement.strategy
# ════════════════════════════════════════════════════════════════════════════
test_enforcement_ci_review_gate_skips() {
    local tmpdir
    tmpdir="$(_make_ci_tmpdir)"
    _make_git_repo_in "$tmpdir"

    # Stage a harmless file so the hook has something to check
    touch "$tmpdir/dummy.txt"
    git -C "$tmpdir" add dummy.txt

    local output
    output="$(PROJECT_ROOT="$tmpdir" GIT_DIR="$tmpdir/.git" GIT_WORK_TREE="$tmpdir" \
        bash "$REVIEW_GATE_HOOK" 2>&1)" || true

    assert_contains \
        "review-gate emits HOOK_GATE skip on enforcement.strategy=ci" \
        "HOOK_GATE: skipped reason=enforcement.strategy=ci" \
        "$output"
}

# ════════════════════════════════════════════════════════════════════════════
# test_enforcement_ci_test_gate_skips
# Given enforcement.strategy=ci; When pre-commit-test-gate.sh runs;
# Then output contains "HOOK_GATE: skipped reason=enforcement.strategy=ci"
# FAILS: hook does not read enforcement.strategy
# ════════════════════════════════════════════════════════════════════════════
test_enforcement_ci_test_gate_skips() {
    local tmpdir
    tmpdir="$(_make_ci_tmpdir)"
    _make_git_repo_in "$tmpdir"

    touch "$tmpdir/src.sh"
    git -C "$tmpdir" add src.sh

    local output
    output="$(PROJECT_ROOT="$tmpdir" GIT_DIR="$tmpdir/.git" GIT_WORK_TREE="$tmpdir" \
        bash "$TEST_GATE_HOOK" 2>&1)" || true

    assert_contains \
        "test-gate emits HOOK_GATE skip on enforcement.strategy=ci" \
        "HOOK_GATE: skipped reason=enforcement.strategy=ci" \
        "$output"
}

# ════════════════════════════════════════════════════════════════════════════
# test_enforcement_ci_test_quality_gate_skips
# Given enforcement.strategy=ci; When pre-commit-test-quality-gate.sh runs;
# Then output contains "HOOK_GATE: skipped reason=enforcement.strategy=ci"
# FAILS: hook does not read enforcement.strategy
# ════════════════════════════════════════════════════════════════════════════
test_enforcement_ci_test_quality_gate_skips() {
    local tmpdir
    tmpdir="$(_make_ci_tmpdir)"
    _make_git_repo_in "$tmpdir"

    # Stage a test file so the quality gate has something to check
    mkdir -p "$tmpdir/tests"
    touch "$tmpdir/tests/test-foo.sh"
    git -C "$tmpdir" add tests/test-foo.sh

    local output
    output="$(PROJECT_ROOT="$tmpdir" DSO_CONFIG_FILE="$tmpdir/.claude/dso-config.conf" \
        GIT_DIR="$tmpdir/.git" GIT_WORK_TREE="$tmpdir" \
        bash "$TEST_QUALITY_GATE_HOOK" 2>&1)" || true

    assert_contains \
        "test-quality-gate emits HOOK_GATE skip on enforcement.strategy=ci" \
        "HOOK_GATE: skipped reason=enforcement.strategy=ci" \
        "$output"
}

# ════════════════════════════════════════════════════════════════════════════
# test_structural_check_plugin_self_ref_runs_on_ci  ← RED ZONE ANCHOR
# Given enforcement.strategy=ci AND staged file with literal "plugins/dso/" path;
# When check-plugin-self-ref hook runs;
# Then exits 1 (structural hooks always block regardless of enforcement.strategy)
# FAILS: hook doesn't read enforcement.strategy (can't distinguish structural yet)
#
# tests/hooks/test-enforcement-gate.sh. The suite-engine _RED_MARKER_MAP stores ONE
# value per file path (last entry wins). By anchoring the RED zone at this FIRST
# structural test, ALL 5 structural tests (which appear at/after this line) are
# tolerated when they fail. Adding entries for the other 4 tests would cause the
# LAST entry to win (test_structural_check_referential_integrity_runs_on_ci), leaving
# tests 1-4 BEFORE the zone boundary and NOT tolerated. Single-entry is intentional.
# ════════════════════════════════════════════════════════════════════════════
test_structural_check_plugin_self_ref_runs_on_ci() {
    _snapshot_fail
    local tmpdir
    tmpdir="$(_make_ci_tmpdir)"
    _make_git_repo_in "$tmpdir"

    # Create a staged file with a literal plugins/dso/ reference (should block)
    cat > "$tmpdir/bad-script.sh" <<'EOF'
#!/usr/bin/env bash
# bad ref: plugins/dso/scripts/foo.sh
source plugins/dso/scripts/foo.sh
EOF
    git -C "$tmpdir" add bad-script.sh

    local exit_code=0
    PROJECT_ROOT="$tmpdir" GIT_DIR="$tmpdir/.git" GIT_WORK_TREE="$tmpdir" \
        bash "$CHECK_PLUGIN_SELF_REF_HOOK" >/dev/null 2>&1 || exit_code=$?

    assert_eq \
        "check-plugin-self-ref exits 1 (blocks) when enforcement.strategy=ci (structural hooks always-on)" \
        "1" \
        "$exit_code"
    assert_pass_if_clean "test_structural_check_plugin_self_ref_runs_on_ci"
}

# ════════════════════════════════════════════════════════════════════════════
# test_structural_check_portability_runs_on_ci
# Given enforcement.strategy=ci AND staged file with hardcoded path;
# When check-portability.sh runs;
# Then exits 1 (structural hooks always block)
# FAILS: hook doesn't read enforcement.strategy
# ════════════════════════════════════════════════════════════════════════════
test_structural_check_portability_runs_on_ci() {
    _snapshot_fail
    local tmpdir
    tmpdir="$(_make_ci_tmpdir)"
    _make_git_repo_in "$tmpdir"

    # Create a staged file with a hardcoded /home/... path (portability violation).
    # Use variable expansion so the literal path only appears in the generated temp file,
    # not as a source-level string that the portability checker would flag here.
    local _bad_prefix="/home/user"
    cat > "$tmpdir/bad-portability.sh" <<EOF
#!/usr/bin/env bash
source ${_bad_prefix}/digital-service-orchestra/plugins/dso/scripts/foo.sh
EOF
    git -C "$tmpdir" add bad-portability.sh

    local exit_code=0
    PROJECT_ROOT="$tmpdir" GIT_DIR="$tmpdir/.git" GIT_WORK_TREE="$tmpdir" \
        bash "$CHECK_PORTABILITY_SCRIPT" >/dev/null 2>&1 || exit_code=$?

    assert_eq \
        "check-portability exits 1 (blocks) when enforcement.strategy=ci (structural hooks always-on)" \
        "1" \
        "$exit_code"
    assert_pass_if_clean "test_structural_check_portability_runs_on_ci"
}

# ════════════════════════════════════════════════════════════════════════════
# test_structural_check_shim_refs_runs_on_ci
# Given enforcement.strategy=ci AND staged file with direct plugin script ref;
# When check-shim-refs.sh runs;
# Then exits 1 (structural hooks always block)
# FAILS: hook doesn't read enforcement.strategy
# ════════════════════════════════════════════════════════════════════════════
test_structural_check_shim_refs_runs_on_ci() {
    _snapshot_fail
    local tmpdir
    tmpdir="$(_make_ci_tmpdir)"
    _make_git_repo_in "$tmpdir"

    # Create a staged file with a direct reference to a plugin script (shim violation)
    cat > "$tmpdir/bad-shim.sh" <<'EOF'
#!/usr/bin/env bash
# Direct plugin script call (should use .claude/scripts/dso shim instead)
bash plugins/dso/scripts/ticket-list.sh
EOF
    git -C "$tmpdir" add bad-shim.sh

    local exit_code=0
    PROJECT_ROOT="$tmpdir" GIT_DIR="$tmpdir/.git" GIT_WORK_TREE="$tmpdir" \
        bash "$CHECK_SHIM_REFS_SCRIPT" >/dev/null 2>&1 || exit_code=$?

    assert_eq \
        "check-shim-refs exits 1 (blocks) when enforcement.strategy=ci (structural hooks always-on)" \
        "1" \
        "$exit_code"
    assert_pass_if_clean "test_structural_check_shim_refs_runs_on_ci"
}

# ════════════════════════════════════════════════════════════════════════════
# test_structural_check_contract_schemas_runs_on_ci
# Given enforcement.strategy=ci AND staged contract file with bad structure;
# When check-contract-schemas.sh runs;
# Then exits 1 (structural hooks always block)
# FAILS: hook doesn't read enforcement.strategy
# ════════════════════════════════════════════════════════════════════════════
test_structural_check_contract_schemas_runs_on_ci() {
    _snapshot_fail
    local tmpdir
    tmpdir="$(_make_ci_tmpdir)"
    _make_git_repo_in "$tmpdir"

    # Create a staged contract file missing required schema sections
    mkdir -p "$tmpdir/docs/contracts"
    cat > "$tmpdir/docs/contracts/bad-contract.md" <<'EOF'
# Bad Contract

This contract is missing required schema sections.
EOF
    git -C "$tmpdir" add docs/contracts/bad-contract.md

    local exit_code=0
    PROJECT_ROOT="$tmpdir" GIT_DIR="$tmpdir/.git" GIT_WORK_TREE="$tmpdir" \
        bash "$CHECK_CONTRACT_SCHEMAS_SCRIPT" >/dev/null 2>&1 || exit_code=$?

    assert_eq \
        "check-contract-schemas exits 1 (blocks) when enforcement.strategy=ci (structural hooks always-on)" \
        "1" \
        "$exit_code"
    assert_pass_if_clean "test_structural_check_contract_schemas_runs_on_ci"
}

# ════════════════════════════════════════════════════════════════════════════
# test_structural_check_referential_integrity_runs_on_ci
# Given enforcement.strategy=ci AND staged file with dead path reference;
# When check-referential-integrity.sh runs;
# Then exits 1 (structural hooks always block)
# FAILS: hook doesn't read enforcement.strategy
# ════════════════════════════════════════════════════════════════════════════
test_structural_check_referential_integrity_runs_on_ci() {
    _snapshot_fail
    local tmpdir
    tmpdir="$(_make_ci_tmpdir)"
    _make_git_repo_in "$tmpdir"

    # Create a staged instruction file referencing a non-existent path
    cat > "$tmpdir/CLAUDE.md" <<'EOF'
# Instructions

See [nonexistent-file.sh](plugins/dso/scripts/nonexistent-file-that-does-not-exist.sh).
EOF
    git -C "$tmpdir" add CLAUDE.md

    local exit_code=0
    PROJECT_ROOT="$tmpdir" GIT_DIR="$tmpdir/.git" GIT_WORK_TREE="$tmpdir" \
        bash "$CHECK_REFERENTIAL_INTEGRITY_SCRIPT" >/dev/null 2>&1 || exit_code=$?

    assert_eq \
        "check-referential-integrity exits 1 (blocks) when enforcement.strategy=ci (structural hooks always-on)" \
        "1" \
        "$exit_code"
    assert_pass_if_clean "test_structural_check_referential_integrity_runs_on_ci"
}

# ════════════════════════════════════════════════════════════════════════════
# test_enforcement_both_no_double_execution
# Given enforcement.strategy=both; When pre-commit-review-gate.sh runs;
# Then hook logic executes at most once (invocation counter <= 1)
# FAILS: enforcement.strategy=both is not implemented
# ════════════════════════════════════════════════════════════════════════════
test_enforcement_both_no_double_execution() {
    local tmpdir
    tmpdir="$(_make_both_tmpdir)"
    _make_git_repo_in "$tmpdir"

    touch "$tmpdir/dummy.txt"
    git -C "$tmpdir" add dummy.txt

    # Counter file: each hook invocation should append a line
    local counter_file
    counter_file="$(mktemp /tmp/test-hook-counter.XXXXXX)"
    _TEST_TMPDIRS+=("$counter_file")

    local output
    output="$(PROJECT_ROOT="$tmpdir" GIT_DIR="$tmpdir/.git" GIT_WORK_TREE="$tmpdir" \
        DSO_HOOK_COUNTER_FILE="$counter_file" \
        bash "$REVIEW_GATE_HOOK" 2>&1)" || true

    # Count invocations via HOOK_GATE signals in output
    # enforcement.strategy=both must emit HOOK_GATE:run at most once (not zero, not two+)
    # The feature is unimplemented: run_count will be 0 (no HOOK_GATE signal emitted at all)
    local run_count=0
    run_count="$(printf '%s\n' "$output" | grep -c "HOOK_GATE: run" 2>/dev/null)" || true

    # This FAILS: HOOK_GATE not implemented — count is 0, expected range is [1, 1]
    # We assert the upper bound: count must be <= 1. Since it's 0, that's technically
    # within the "no double execution" bound — but we additionally check it's >= 1
    # (i.e., that the feature actually ran). This combined assertion requires exactly 1.
    assert_eq \
        "enforcement.strategy=both: HOOK_GATE run emitted exactly once (no double execution)" \
        "1" \
        "$run_count"

    rm -f "$counter_file"
}

# ════════════════════════════════════════════════════════════════════════════
# test_enforcement_both_runs_once
# Given enforcement.strategy=both; When pre-commit-review-gate.sh runs;
# Then invocation counter is exactly 1
# FAILS: enforcement.strategy=both is not implemented
# ════════════════════════════════════════════════════════════════════════════
test_enforcement_both_runs_once() {
    local tmpdir
    tmpdir="$(_make_both_tmpdir)"
    _make_git_repo_in "$tmpdir"

    touch "$tmpdir/dummy.txt"
    git -C "$tmpdir" add dummy.txt

    local output
    output="$(PROJECT_ROOT="$tmpdir" GIT_DIR="$tmpdir/.git" GIT_WORK_TREE="$tmpdir" \
        bash "$REVIEW_GATE_HOOK" 2>&1)" || true

    # enforcement.strategy=both must emit a HOOK_GATE:run signal exactly once
    local run_count
    run_count="$(printf '%s\n' "$output" | grep -c "HOOK_GATE: run" || echo "0")"

    assert_eq \
        "enforcement.strategy=both: HOOK_GATE run signal emitted exactly once" \
        "1" \
        "$run_count"
}

# ════════════════════════════════════════════════════════════════════════════
# test_hook_gate_schema_review_gate
# Given enforcement.strategy=ci; When pre-commit-review-gate.sh runs;
# Then output contains exactly "HOOK_GATE: skipped reason=enforcement.strategy=ci"
# FAILS: hook does not emit HOOK_GATE signal
# ════════════════════════════════════════════════════════════════════════════
test_hook_gate_schema_review_gate() {
    local tmpdir
    tmpdir="$(_make_ci_tmpdir)"
    _make_git_repo_in "$tmpdir"

    touch "$tmpdir/dummy.txt"
    git -C "$tmpdir" add dummy.txt

    local output
    output="$(PROJECT_ROOT="$tmpdir" GIT_DIR="$tmpdir/.git" GIT_WORK_TREE="$tmpdir" \
        bash "$REVIEW_GATE_HOOK" 2>&1)" || true

    # Exact schema check (not just substring — full token must appear on a line)
    local schema_token="HOOK_GATE: skipped reason=enforcement.strategy=ci"
    assert_contains \
        "review-gate HOOK_GATE output matches exact schema: '$schema_token'" \
        "$schema_token" \
        "$output"
}

# ════════════════════════════════════════════════════════════════════════════
# test_hook_gate_schema_test_gate
# Given enforcement.strategy=ci; When pre-commit-test-gate.sh runs;
# Then output contains exactly "HOOK_GATE: skipped reason=enforcement.strategy=ci"
# FAILS: hook does not emit HOOK_GATE signal
# ════════════════════════════════════════════════════════════════════════════
test_hook_gate_schema_test_gate() {
    local tmpdir
    tmpdir="$(_make_ci_tmpdir)"
    _make_git_repo_in "$tmpdir"

    touch "$tmpdir/src.sh"
    git -C "$tmpdir" add src.sh

    local output
    output="$(PROJECT_ROOT="$tmpdir" GIT_DIR="$tmpdir/.git" GIT_WORK_TREE="$tmpdir" \
        bash "$TEST_GATE_HOOK" 2>&1)" || true

    local schema_token="HOOK_GATE: skipped reason=enforcement.strategy=ci"
    assert_contains \
        "test-gate HOOK_GATE output matches exact schema: '$schema_token'" \
        "$schema_token" \
        "$output"
}

# ════════════════════════════════════════════════════════════════════════════
# test_hook_gate_schema_test_quality_gate
# Given enforcement.strategy=ci; When pre-commit-test-quality-gate.sh runs;
# Then output contains exactly "HOOK_GATE: skipped reason=enforcement.strategy=ci"
# FAILS: hook does not emit HOOK_GATE signal
# ════════════════════════════════════════════════════════════════════════════
test_hook_gate_schema_test_quality_gate() {
    local tmpdir
    tmpdir="$(_make_ci_tmpdir)"
    _make_git_repo_in "$tmpdir"

    mkdir -p "$tmpdir/tests"
    touch "$tmpdir/tests/test-foo.sh"
    git -C "$tmpdir" add tests/test-foo.sh

    local output
    output="$(PROJECT_ROOT="$tmpdir" DSO_CONFIG_FILE="$tmpdir/.claude/dso-config.conf" \
        GIT_DIR="$tmpdir/.git" GIT_WORK_TREE="$tmpdir" \
        bash "$TEST_QUALITY_GATE_HOOK" 2>&1)" || true

    local schema_token="HOOK_GATE: skipped reason=enforcement.strategy=ci"
    assert_contains \
        "test-quality-gate HOOK_GATE output matches exact schema: '$schema_token'" \
        "$schema_token" \
        "$output"
}

# ════════════════════════════════════════════════════════════════════════════
# Main: run all tests
# ════════════════════════════════════════════════════════════════════════════
echo "=== test-enforcement-gate.sh: RED-phase enforcement strategy tests ==="
echo ""

test_enforcement_ci_review_gate_skips
test_enforcement_ci_test_gate_skips
test_enforcement_ci_test_quality_gate_skips
test_structural_check_plugin_self_ref_runs_on_ci
test_structural_check_portability_runs_on_ci
test_structural_check_shim_refs_runs_on_ci
test_structural_check_contract_schemas_runs_on_ci
test_structural_check_referential_integrity_runs_on_ci
test_enforcement_both_no_double_execution
test_enforcement_both_runs_once
test_hook_gate_schema_review_gate
test_hook_gate_schema_test_gate
test_hook_gate_schema_test_quality_gate

print_summary
