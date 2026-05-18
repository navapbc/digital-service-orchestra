#!/usr/bin/env bash
# shellcheck disable=SC2030,SC2031  # Subshell isolation for test independence
# shellcheck disable=SC2164         # cd into known-valid mktemp dirs — cannot fail
# shellcheck disable=SC2155         # Declare-and-assign in subshell context — test-only pattern
# tests/scripts/test-local-review-workflow-e2e.sh
# RED E2E tests for plugins/dso/scripts/review-workflow.sh
#
# These tests exercise review-workflow.sh end-to-end by intercepting LLM
# dispatch via mock Python modules injected into PYTHONPATH. They use a temp
# WORKFLOW_PLUGIN_ARTIFACTS_DIR for each test and invoke review-workflow.sh
# directly as a shell subprocess.
#
# All 5 tests are expected to FAIL (RED state) because the full implementation
# of local_workflow.py is not yet complete — specifically:
#   - DSO_CI_REVIEW_MOCK env var for shim-controlled dispatch is not wired
#   - The arbiter-rulings.json sidecar schema fields (cycle_num, block in summary)
#     are not all present when dispatched from the loop's DISPATCH_ARBITER branch
#   - SHORT_CIRCUIT re-run guard does not yet check arbiter-rulings.json presence
#     reliably without a ledger pre-populated with matching commit SHA
#   - DROP defense store write to tracker is not yet verified E2E without ticket CLI
#   - Pre-commit hook extension to read arbiter-rulings.json is not yet active
#     in the E2E shell invocation path (it reads from the wrong artifacts dir)
#
# Tests:
#   test_e2e_three_cycles_then_arbiter_block
#   test_e2e_pass_branch_cycle_1
#   test_e2e_short_circuit_on_rerun_same_sha
#   test_e2e_max_cycles_arbiter
#   test_e2e_drop_writes_tracker_only
#
# Story: 7034-071c-82b1-4cae  Task: 33d3-cde4-0e54-4150

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
REVIEW_WORKFLOW="$DSO_PLUGIN_DIR/scripts/review-workflow.sh"
PLUGIN_SCRIPTS="$DSO_PLUGIN_DIR/scripts"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

# ── Cleanup on exit ──────────────────────────────────────────────────────────
_TEST_TMPDIRS=()
_cleanup_test_tmpdirs() {
    for d in "${_TEST_TMPDIRS[@]}"; do
        rm -rf "$d" 2>/dev/null || true
    done
}
trap _cleanup_test_tmpdirs EXIT

# ── Prerequisite checks ──────────────────────────────────────────────────────
if [[ ! -f "$REVIEW_WORKFLOW" ]]; then
    echo "SKIP: review-workflow.sh not found at $REVIEW_WORKFLOW"
    exit 0
fi

if [[ ! -x "$REVIEW_WORKFLOW" ]]; then
    echo "FAIL: review-workflow.sh is not executable"
    (( FAIL++ ))
fi

if ! command -v python3 >/dev/null 2>&1; then
    echo "SKIP: python3 not available"
    exit 0
fi

# ── Helper: make an isolated artifacts dir ───────────────────────────────────
make_artifacts_dir() {
    local tmpdir
    tmpdir=$(mktemp -d)
    _TEST_TMPDIRS+=("$tmpdir")
    echo "$tmpdir"
}

# ── Helper: make an isolated git repo ────────────────────────────────────────
make_test_repo() {
    local tmpdir
    tmpdir=$(mktemp -d)
    _TEST_TMPDIRS+=("$tmpdir")
    git -C "$tmpdir" init -q
    git -C "$tmpdir" config user.email "test@test.com"
    git -C "$tmpdir" config user.name "Test"
    echo "initial" > "$tmpdir/README.md"
    git -C "$tmpdir" add -A
    git -C "$tmpdir" commit -q -m "init"
    echo "$tmpdir"
}

# ── Helper: write an arbiter-rulings.json sidecar ────────────────────────────
write_arbiter_rulings() {
    local artifacts_dir="$1"
    local commit_sha="$2"
    local ruling="$3"
    local block_count="$4"
    local cycle_num="${5:-1}"
    mkdir -p "$artifacts_dir"
    printf '{"schema_version":"1.0.0","cycle_num":%s,"commit_sha":"%s","rulings":[{"ruling":"%s","rationale":"test rationale"}],"summary":{"block_count":%s,"drop_count":0,"defer_count":0,"total":1}}\n' \
        "$cycle_num" "$commit_sha" "$ruling" "$block_count" \
        > "$artifacts_dir/arbiter-rulings.json"
}

# ── Helper: write a cycle ledger ─────────────────────────────────────────────
write_cycle_ledger() {
    local artifacts_dir="$1"
    local commit_sha="$2"
    local halt_reason="${3:-STABLE_HALT}"
    mkdir -p "$artifacts_dir"
    printf '{"cycles":[{"cycle_num":1,"commit_sha":"%s","findings":[],"findings_hash":"abc123","halt_reason":"%s","timestamp_utc":"2026-01-01T00:00:00Z"}]}\n' \
        "$commit_sha" "$halt_reason" > "$artifacts_dir/cycle-ledger.json"
}

# ── Helper: create a mock dispatch module injected via PYTHONPATH ─────────────
# Writes a dso_ci_review/dispatch.py shim into a temp dir that returns
# pre-baked findings without making real LLM calls.
# This is the E2E intercept surface: review-workflow.sh → Python → dispatch.py
make_mock_dispatch_module() {
    local tmpdir findings_json
    tmpdir=$(mktemp -d)
    _TEST_TMPDIRS+=("$tmpdir")
    findings_json="${1:-[]}"
    mkdir -p "$tmpdir/dso_ci_review"

    # Write a minimal __init__.py so Python treats it as a package
    cat > "$tmpdir/dso_ci_review/__init__.py" << 'PYEOF'
# Mock dso_ci_review package — intercepts dispatch for E2E tests
PYEOF

    # Write a stub dispatch.py that returns pre-baked findings
    cat > "$tmpdir/dso_ci_review/dispatch.py" << PYEOF
"""Mock dispatch module: returns pre-baked findings for E2E tests."""
import json, os

_FINDINGS = json.loads(os.environ.get("DSO_E2E_MOCK_FINDINGS", "${findings_json}"))

def dispatch_review(diff_text="", provider_chain=None, **kwargs):
    return {"findings": _FINDINGS, "review_tier": "standard"}
PYEOF

    echo "$tmpdir"
}

# ── Helper: invoke review-workflow.sh in an isolated repo ────────────────────
# Usage: _run_review_workflow <repo_dir> <artifacts_dir> [<extra_pythonpath>]
# Echoes exit code; suppresses stdout/stderr.
_run_review_workflow() {
    local repo_dir="$1"
    local artifacts_dir="$2"
    local extra_pythonpath="${3:-}"
    local exit_code=0
    local python_path="$PLUGIN_SCRIPTS"
    if [[ -n "$extra_pythonpath" ]]; then
        python_path="$extra_pythonpath:$python_path"
    fi
    (
        cd "$repo_dir"
        export WORKFLOW_PLUGIN_ARTIFACTS_DIR="$artifacts_dir"
        export PYTHONPATH="$python_path${PYTHONPATH:+:${PYTHONPATH}}"
        bash "$REVIEW_WORKFLOW" 2>/dev/null
    ) || exit_code=$?
    echo "$exit_code"
}

# Same but capture stderr
_run_review_workflow_stderr() {
    local repo_dir="$1"
    local artifacts_dir="$2"
    local extra_pythonpath="${3:-}"
    local python_path="$PLUGIN_SCRIPTS"
    if [[ -n "$extra_pythonpath" ]]; then
        python_path="$extra_pythonpath:$python_path"
    fi
    (
        cd "$repo_dir"
        export WORKFLOW_PLUGIN_ARTIFACTS_DIR="$artifacts_dir"
        export PYTHONPATH="$python_path${PYTHONPATH:+:${PYTHONPATH}}"
        bash "$REVIEW_WORKFLOW" >/dev/null 2>&1
    ) || true
}

# ============================================================
# test_e2e_three_cycles_then_arbiter_block
#
# E2E: review-workflow.sh, when given a mock dispatch module that returns
# a critical finding every cycle, must run multiple cycles, invoke the
# cycle-end arbiter, write arbiter-rulings.json with block_count >= 1,
# and exit 1.
#
# RED: fails because dispatch_review mock interception via PYTHONPATH shadowing
# is not yet supported — review-workflow.sh does not check DSO_E2E_MOCK_FINDINGS
# in the dispatch module, so the mock findings are ignored and the workflow
# attempts a real LLM call, which fails with an import/agent-file error rather
# than the expected BLOCK exit code.
# ============================================================
test_e2e_three_cycles_then_arbiter_block() {
    local _repo _artifacts _mock_pp
    _repo=$(make_test_repo)
    _artifacts=$(make_artifacts_dir)

    # Mock findings: a critical finding that should trigger DISPATCH_ARBITER
    local critical_finding='[{"severity":"critical","file":"x.py","line_range":"1-5","category":"correctness","message":"e2e test block finding","id":"e2e-1"}]'
    _mock_pp=$(make_mock_dispatch_module "$critical_finding")

    # Set max_cycles=2 via environment so arbiter fires quickly
    local exit_code=0
    (
        cd "$_repo"
        export WORKFLOW_PLUGIN_ARTIFACTS_DIR="$_artifacts"
        export PYTHONPATH="$_mock_pp:$PLUGIN_SCRIPTS${PYTHONPATH:+:${PYTHONPATH}}"
        export DSO_E2E_MOCK_FINDINGS="$critical_finding"
        export DSO_REVIEW_MAX_CYCLES=2
        bash "$REVIEW_WORKFLOW" 2>/dev/null
    ) || exit_code=$?

    # Expect exit 1 (BLOCK ruling from arbiter after max cycles)
    assert_eq "test_e2e_three_cycles_then_arbiter_block: exit code is 1 (BLOCK)" "1" "$exit_code"

    # arbiter-rulings.json must exist in the artifacts dir
    local rulings_file="$_artifacts/arbiter-rulings.json"
    local rulings_exist=0
    [[ -f "$rulings_file" ]] && rulings_exist=1
    assert_eq "test_e2e_three_cycles_then_arbiter_block: arbiter-rulings.json written" "1" "$rulings_exist"

    # block_count in summary must be >= 1
    if [[ -f "$rulings_file" ]]; then
        local block_count
        block_count=$(python3 -c "import json; d=json.load(open('$rulings_file')); print(d.get('summary',{}).get('block_count',0))" 2>/dev/null || echo "0")
        assert_ne "test_e2e_three_cycles_then_arbiter_block: block_count >= 1" "0" "$block_count"
    fi
}

# ============================================================
# test_e2e_pass_branch_cycle_1
#
# E2E: review-workflow.sh, given a mock dispatch module that returns zero
# findings, must exit 0 (PASS) after a single cycle without invoking the
# arbiter, and must write cycle-ledger.json with halt_reason STABLE_HALT.
#
# RED: fails because the mock dispatch interception via PYTHONPATH shadowing
# is not yet wired — the workflow attempts a real LLM call that fails with a
# RuntimeError (agent file not found), rather than exiting 0 cleanly.
# ============================================================
test_e2e_pass_branch_cycle_1() {
    local _repo _artifacts _mock_pp
    _repo=$(make_test_repo)
    _artifacts=$(make_artifacts_dir)
    _mock_pp=$(make_mock_dispatch_module "[]")

    local exit_code=0
    (
        cd "$_repo"
        export WORKFLOW_PLUGIN_ARTIFACTS_DIR="$_artifacts"
        export PYTHONPATH="$_mock_pp:$PLUGIN_SCRIPTS${PYTHONPATH:+:${PYTHONPATH}}"
        export DSO_E2E_MOCK_FINDINGS="[]"
        bash "$REVIEW_WORKFLOW" 2>/dev/null
    ) || exit_code=$?

    assert_eq "test_e2e_pass_branch_cycle_1: exit code is 0 (PASS)" "0" "$exit_code"

    # cycle-ledger.json must be written
    local ledger_file="$_artifacts/cycle-ledger.json"
    local ledger_exist=0
    [[ -f "$ledger_file" ]] && ledger_exist=1
    assert_eq "test_e2e_pass_branch_cycle_1: cycle-ledger.json written" "1" "$ledger_exist"

    # arbiter-rulings.json must NOT exist (arbiter not invoked on PASS)
    local rulings_exist=0
    [[ -f "$_artifacts/arbiter-rulings.json" ]] && rulings_exist=1
    assert_eq "test_e2e_pass_branch_cycle_1: arbiter-rulings.json NOT written on PASS" "0" "$rulings_exist"
}

# ============================================================
# test_e2e_short_circuit_on_rerun_same_sha
#
# E2E: When a prior cycle ledger with the same commit SHA and a prior
# arbiter-rulings.json (DROP, block_count=0) are already in the artifacts
# dir, review-workflow.sh must SHORT_CIRCUIT and exit 0 without re-running
# any reviewer dispatch. The cycle-ledger.json cycle count must not increase.
#
# RED: fails because the SHORT_CIRCUIT path in local_workflow.main() does not
# yet correctly detect the pre-existing arbiter-rulings.json when the ledger
# contains a matching SHA cycle — the mock dispatch is still called.
# ============================================================
test_e2e_short_circuit_on_rerun_same_sha() {
    local _repo _artifacts _mock_pp
    _repo=$(make_test_repo)
    _artifacts=$(make_artifacts_dir)
    _mock_pp=$(make_mock_dispatch_module "[]")

    local commit_sha
    commit_sha=$(git -C "$_repo" rev-parse HEAD)

    # Pre-populate: ledger shows cycle 1 already completed with this SHA
    write_cycle_ledger "$_artifacts" "$commit_sha" "STABLE_HALT"

    # Pre-populate: arbiter-rulings.json with DROP ruling (no block)
    write_arbiter_rulings "$_artifacts" "$commit_sha" "DROP" "0" "1"

    local exit_code=0
    (
        cd "$_repo"
        export WORKFLOW_PLUGIN_ARTIFACTS_DIR="$_artifacts"
        export PYTHONPATH="$_mock_pp:$PLUGIN_SCRIPTS${PYTHONPATH:+:${PYTHONPATH}}"
        export DSO_E2E_MOCK_FINDINGS="[]"
        bash "$REVIEW_WORKFLOW" 2>/dev/null
    ) || exit_code=$?

    # Must exit 0 (prior ruling was DROP, not BLOCK)
    assert_eq "test_e2e_short_circuit_on_rerun_same_sha: exit code is 0 (SHORT_CIRCUIT, no block)" "0" "$exit_code"

    # Ledger must still have exactly 1 cycle (no new cycle appended)
    local ledger_file="$_artifacts/cycle-ledger.json"
    if [[ -f "$ledger_file" ]]; then
        local cycle_count
        cycle_count=$(python3 -c "import json; d=json.load(open('$ledger_file')); print(len([c for c in d.get('cycles',[]) if not c.get('_placeholder')]))" 2>/dev/null || echo "-1")
        assert_eq "test_e2e_short_circuit_on_rerun_same_sha: cycle count stays at 1" "1" "$cycle_count"
    else
        assert_eq "test_e2e_short_circuit_on_rerun_same_sha: ledger file present" "present" "missing"
    fi
}

# ============================================================
# test_e2e_max_cycles_arbiter
#
# E2E: With max_cycles=1 and a critical finding returned each cycle, the
# workflow must dispatch the arbiter immediately after cycle 1, write
# arbiter-rulings.json with schema_version=1.0.0 and block_count >= 1,
# and exit 1.
#
# RED: fails because the mock dispatch shim injection does not yet intercept
# the LLM call inside dispatch_review — real dispatch fails with RuntimeError
# before the arbiter is ever reached.
# ============================================================
test_e2e_max_cycles_arbiter() {
    local _repo _artifacts _mock_pp
    _repo=$(make_test_repo)
    _artifacts=$(make_artifacts_dir)

    local critical_finding='[{"severity":"critical","file":"lib.py","line_range":"10","category":"correctness","message":"persistent critical finding","id":"e2e-2"}]'
    _mock_pp=$(make_mock_dispatch_module "$critical_finding")

    local exit_code=0
    (
        cd "$_repo"
        export WORKFLOW_PLUGIN_ARTIFACTS_DIR="$_artifacts"
        export PYTHONPATH="$_mock_pp:$PLUGIN_SCRIPTS${PYTHONPATH:+:${PYTHONPATH}}"
        export DSO_E2E_MOCK_FINDINGS="$critical_finding"
        export DSO_REVIEW_MAX_CYCLES=1
        bash "$REVIEW_WORKFLOW" 2>/dev/null
    ) || exit_code=$?

    # Expect exit 1 from arbiter BLOCK after 1 cycle
    assert_eq "test_e2e_max_cycles_arbiter: exit code is 1 (arbiter block at max cycles)" "1" "$exit_code"

    # arbiter-rulings.json must exist with correct schema_version
    local rulings_file="$_artifacts/arbiter-rulings.json"
    local schema_version="absent"
    if [[ -f "$rulings_file" ]]; then
        schema_version=$(python3 -c "import json; print(json.load(open('$rulings_file')).get('schema_version','missing'))" 2>/dev/null || echo "parse-error")
    fi
    assert_eq "test_e2e_max_cycles_arbiter: arbiter-rulings.json schema_version=1.0.0" "1.0.0" "$schema_version"
}

# ============================================================
# test_e2e_drop_writes_tracker_only
#
# E2E: When the arbiter issues a DROP ruling (finding is noise, no BLOCK),
# review-workflow.sh must:
#   (a) exit 0
#   (b) write arbiter-rulings.json with block_count=0
#   (c) NOT create a blocking entry in the pre-commit gate check
#
# RED: fails because the mock dispatch module injection is not intercepted
# by the local workflow; the workflow fails at LLM dispatch before the arbiter
# side-effects (DROP tracker write, sidecar block_count=0) can be verified.
# ============================================================
test_e2e_drop_writes_tracker_only() {
    local _repo _artifacts _mock_pp
    _repo=$(make_test_repo)
    _artifacts=$(make_artifacts_dir)

    # Minor finding that the arbiter would DROP (noise)
    local minor_finding='[{"severity":"minor","file":"readme.md","line_range":"1","category":"docs","message":"noise doc comment","id":"e2e-3"}]'
    _mock_pp=$(make_mock_dispatch_module "$minor_finding")

    local exit_code=0
    (
        cd "$_repo"
        export WORKFLOW_PLUGIN_ARTIFACTS_DIR="$_artifacts"
        export PYTHONPATH="$_mock_pp:$PLUGIN_SCRIPTS${PYTHONPATH:+:${PYTHONPATH}}"
        export DSO_E2E_MOCK_FINDINGS="$minor_finding"
        export DSO_REVIEW_MAX_CYCLES=1
        # Signal arbiter to DROP findings (mock arbiter behavior)
        export DSO_E2E_ARBITER_RULING="DROP"
        bash "$REVIEW_WORKFLOW" 2>/dev/null
    ) || exit_code=$?

    # Must exit 0 (DROP ruling = allow commit)
    assert_eq "test_e2e_drop_writes_tracker_only: exit code is 0 (DROP ruling, no block)" "0" "$exit_code"

    # arbiter-rulings.json must exist with block_count=0
    local rulings_file="$_artifacts/arbiter-rulings.json"
    local block_count="absent"
    if [[ -f "$rulings_file" ]]; then
        block_count=$(python3 -c "import json; print(json.load(open('$rulings_file')).get('summary',{}).get('block_count','missing'))" 2>/dev/null || echo "parse-error")
    fi
    assert_eq "test_e2e_drop_writes_tracker_only: arbiter-rulings.json block_count=0" "0" "$block_count"
}

# ── Run all tests ────────────────────────────────────────────────────────────
test_e2e_three_cycles_then_arbiter_block
test_e2e_pass_branch_cycle_1
test_e2e_short_circuit_on_rerun_same_sha
test_e2e_max_cycles_arbiter
test_e2e_drop_writes_tracker_only

print_summary
