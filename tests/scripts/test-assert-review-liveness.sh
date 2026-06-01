#!/usr/bin/env bash
# tests/scripts/test-assert-review-liveness.sh
#
# Behavioral tests for plugins/dso/scripts/ci/assert-review-liveness.sh
# (F3 fix). Covers:
#
#   Path A (code_changed=true):
#     - findings.json missing → exit 1
#     - findings.json empty → exit 1
#     - findings.json malformed (not an object, wrong key shape) → exit 1
#     - findings.json valid → exit 0
#
#   Path B (code_changed=false, trust-but-verify cross-check):
#     - skip-review-check agrees (diff is allowlisted-only) → exit 0
#     - skip-review-check disagrees (reviewable file in diff) → exit 1
#     - cannot determine BASE/HEAD → exit 1
#
# Usage: bash tests/scripts/test-assert-review-liveness.sh

set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRIPT="$REPO_ROOT/plugins/dso/scripts/ci/assert-review-liveness.sh"

source "$REPO_ROOT/tests/lib/assert.sh"

_CLEANUP_DIRS=()
_CLEANUP_FILES=()
_cleanup() {
    for _d in "${_CLEANUP_DIRS[@]+"${_CLEANUP_DIRS[@]}"}"; do rm -rf "$_d" 2>/dev/null || true; done
    for _f in "${_CLEANUP_FILES[@]+"${_CLEANUP_FILES[@]}"}"; do rm -f "$_f" 2>/dev/null || true; done
}
trap _cleanup EXIT

echo "=== test-assert-review-liveness.sh ==="

# ── test_script_exists ────────────────────────────────────────────────────────
_snapshot_fail
if [[ -f "$SCRIPT" && -x "$SCRIPT" ]]; then
    actual="exists"
else
    actual="missing"
fi
assert_eq "test_script_exists" "exists" "$actual"
assert_pass_if_clean "test_script_exists"

# ── test_shellcheck_clean ─────────────────────────────────────────────────────
_snapshot_fail
sc_rc=0
shellcheck "$SCRIPT" >/dev/null 2>&1 || sc_rc=$?
assert_eq "test_shellcheck_clean" "0" "$sc_rc"
assert_pass_if_clean "test_shellcheck_clean"

# ── Path A: code_changed=true ─────────────────────────────────────────────────

# Missing findings file → exit 1.
_snapshot_fail
ma_rc=0
DSO_CI_REVIEW_FINDINGS_PATH=/tmp/nonexistent.$$.$RANDOM CODE_CHANGED=true \
    bash "$SCRIPT" >/dev/null 2>&1 || ma_rc=$?
assert_eq "test_pathA_missing_findings_exits_1" "1" "$ma_rc"
assert_pass_if_clean "test_pathA_missing_findings_exits_1"

# Empty findings file → exit 1.
_snapshot_fail
ef_tmp="$(mktemp -d "${TMPDIR:-/tmp}/review-liveness-empty.XXXXXX")"
_CLEANUP_DIRS+=("$ef_tmp")
: > "$ef_tmp/findings.json"
ef_rc=0
DSO_CI_REVIEW_FINDINGS_PATH="$ef_tmp/findings.json" CODE_CHANGED=true \
    bash "$SCRIPT" >/dev/null 2>&1 || ef_rc=$?
assert_eq "test_pathA_empty_findings_exits_1" "1" "$ef_rc"
assert_pass_if_clean "test_pathA_empty_findings_exits_1"

# Malformed (findings is not an array) → exit 1.
_snapshot_fail
malformed_tmp="$(mktemp -d "${TMPDIR:-/tmp}/review-liveness-malformed.XXXXXX")"
_CLEANUP_DIRS+=("$malformed_tmp")
echo '{"findings": {"not": "array"}}' > "$malformed_tmp/findings.json"
mm_rc=0
DSO_CI_REVIEW_FINDINGS_PATH="$malformed_tmp/findings.json" CODE_CHANGED=true \
    bash "$SCRIPT" >/dev/null 2>&1 || mm_rc=$?
assert_eq "test_pathA_malformed_findings_exits_1" "1" "$mm_rc"
assert_pass_if_clean "test_pathA_malformed_findings_exits_1"

# Valid empty-findings.json → exit 0.
_snapshot_fail
valid_tmp="$(mktemp -d "${TMPDIR:-/tmp}/review-liveness-valid.XXXXXX")"
_CLEANUP_DIRS+=("$valid_tmp")
echo '{"findings": []}' > "$valid_tmp/findings.json"
v_rc=0
v_out="$(DSO_CI_REVIEW_FINDINGS_PATH="$valid_tmp/findings.json" CODE_CHANGED=true \
    bash "$SCRIPT" 2>&1)" || v_rc=$?
assert_eq "test_pathA_valid_findings_exits_0" "0" "$v_rc"
assert_contains "test_pathA_valid_findings_message" "review liveness: ok" "$v_out"
assert_pass_if_clean "test_pathA_valid_findings"

# TS-1: laundering skip stub (skip_reason=all_scope_already_merged) → exit 1.
# The dispatcher SKIPPED review because in-scope SHAs were filtered as
# reachable-from-main — reachability is NOT review evidence (P9). Liveness must
# fail closed even though the findings array is a valid (empty) shape.
_snapshot_fail
launder_tmp="$(mktemp -d "${TMPDIR:-/tmp}/review-liveness-launder.XXXXXX")"
_CLEANUP_DIRS+=("$launder_tmp")
echo '{"findings": [], "skip_reason": "all_scope_already_merged", "scope_size": 3}' > "$launder_tmp/findings.json"
ls_rc=0
ls_out="$(DSO_CI_REVIEW_FINDINGS_PATH="$launder_tmp/findings.json" CODE_CHANGED=true \
    bash "$SCRIPT" 2>&1)" || ls_rc=$?
assert_eq "test_pathA_laundering_skip_stub_exits_1" "1" "$ls_rc"
assert_contains "test_pathA_laundering_skip_stub_message" "laundering skip stub" "$ls_out"
assert_pass_if_clean "test_pathA_laundering_skip_stub"

# TS-1: a provenanced skip stub (skip_reason=all_commits_provenanced) is NOT
# rejected — it comes from the verifier's G3 covering-PR review check, which is
# genuine review evidence. Must still exit 0.
_snapshot_fail
prov_tmp="$(mktemp -d "${TMPDIR:-/tmp}/review-liveness-prov.XXXXXX")"
_CLEANUP_DIRS+=("$prov_tmp")
echo '{"findings": [], "skip_reason": "all_commits_provenanced"}' > "$prov_tmp/findings.json"
pv_rc=0
pv_out="$(DSO_CI_REVIEW_FINDINGS_PATH="$prov_tmp/findings.json" CODE_CHANGED=true \
    bash "$SCRIPT" 2>&1)" || pv_rc=$?
assert_eq "test_pathA_provenanced_skip_stub_exits_0" "0" "$pv_rc"
assert_contains "test_pathA_provenanced_skip_stub_message" "review liveness: ok" "$pv_out"
assert_pass_if_clean "test_pathA_provenanced_skip_stub"

# ── Path B: code_changed=false ────────────────────────────────────────────────
# These tests build a small git repo with two commits and varying diffs,
# then invoke the script in that working directory with PR-event-style env
# vars. The skip-review-check.sh script is sourced from the live plugin
# tree — it's the SAME logic CI uses.

_make_repo_with_diff() {
    local _files_csv="$1"
    local _tmp
    _tmp=$(mktemp -d "${TMPDIR:-/tmp}/review-liveness-pathB.XXXXXX")
    _CLEANUP_DIRS+=("$_tmp")
    (
        cd "$_tmp" || exit 1
        git init -q
        git config user.email test@test.com
        git config user.name Test
        git config commit.gpgsign false
        echo "seed" > seed.txt
        git add seed.txt
        git commit -q -m "seed"
        local _base
        _base=$(git rev-parse HEAD)
        IFS=',' read -r -a _files <<< "$_files_csv"
        for _f in "${_files[@]}"; do
            mkdir -p "$(dirname "$_f")"
            echo "content" > "$_f"
            git add "$_f"
        done
        git commit -q -m "diff"
        local _head
        _head=$(git rev-parse HEAD)
        echo "$_tmp $_base $_head"
    )
}

# Path B success: code_changed=false and the diff is genuinely allowlisted
# (only a .tickets-tracker file changed, which skip-review-check classifies
# as non-reviewable).
_snapshot_fail
read -r ok_tmp ok_base ok_head <<< "$(_make_repo_with_diff '.tickets-tracker/abc.md')"
ok_rc=0
ok_out="$(cd "$ok_tmp" && CODE_CHANGED=false DSO_BASE_SHA="$ok_base" DSO_SESSION_HEAD="$ok_head" \
    CLAUDE_PLUGIN_ROOT="$REPO_ROOT/plugins/dso" \
    bash "$SCRIPT" 2>&1)" || ok_rc=$?
assert_eq "test_pathB_allowlisted_diff_exits_0" "0" "$ok_rc"
assert_contains "test_pathB_allowlisted_diff_message" "code_changed=false confirmed" "$ok_out"
assert_pass_if_clean "test_pathB_allowlisted_diff"

# Path B fail: code_changed=false but the diff contains a reviewable file
# (a real .py source file). The cross-check must catch the upstream lie.
_snapshot_fail
read -r fail_tmp fail_base fail_head <<< "$(_make_repo_with_diff 'src/important.py')"
fail_rc=0
fail_out="$(cd "$fail_tmp" && CODE_CHANGED=false DSO_BASE_SHA="$fail_base" DSO_SESSION_HEAD="$fail_head" \
    CLAUDE_PLUGIN_ROOT="$REPO_ROOT/plugins/dso" \
    bash "$SCRIPT" 2>&1)" || fail_rc=$?
assert_eq "test_pathB_reviewable_diff_exits_1" "1" "$fail_rc"
assert_contains "test_pathB_reviewable_diff_message" "cross-check says reviewable files are present" "$fail_out"
assert_pass_if_clean "test_pathB_reviewable_diff"

# Path B unresolvable SHAs: missing both env vars and GITHUB_BASE_REF → exit 1.
_snapshot_fail
nu_tmp=$(mktemp -d "${TMPDIR:-/tmp}/review-liveness-nosha.XXXXXX")
_CLEANUP_DIRS+=("$nu_tmp")
(
    cd "$nu_tmp" || exit 1
    git init -q
)
nu_rc=0
# Clear all SHA-related env vars to force the unresolvable path.
nu_out="$(cd "$nu_tmp" && env -u DSO_BASE_SHA -u DSO_SESSION_HEAD -u GITHUB_BASE_REF \
    CODE_CHANGED=false CLAUDE_PLUGIN_ROOT="$REPO_ROOT/plugins/dso" \
    bash "$SCRIPT" 2>&1)" || nu_rc=$?
assert_eq "test_pathB_unresolvable_shas_exits_1" "1" "$nu_rc"
assert_contains "test_pathB_unresolvable_shas_message" "cannot determine BASE/HEAD" "$nu_out"
assert_pass_if_clean "test_pathB_unresolvable_shas"

print_summary
