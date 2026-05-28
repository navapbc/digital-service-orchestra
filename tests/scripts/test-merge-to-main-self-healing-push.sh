#!/usr/bin/env bash
# shellcheck disable=SC2164
# tests/scripts/test-merge-to-main-self-healing-push.sh
#
# Tests for bug cb31-3552 hardening:
#   - Defect A: PR-mode tail invokes _try_reset_stale_version_bump
#   - Defect C: _phase_push uses a self-healing rebase+retry helper
#   - Defect D: --help text reflects that bump defaults to patch when
#     version.file_path is configured
#   - H4: rebase-abort cleanliness on conflict during self-healing push
#
# Mix of structural assertions (for orchestration boundaries) and behavioral
# assertions (for the self-healing helper, which is process-local and
# unit-testable in isolation against a tiny fixture).
#
# Usage: bash tests/scripts/test-merge-to-main-self-healing-push.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
DIRECT_SCRIPT="$DSO_PLUGIN_DIR/scripts/merge-to-main-direct.sh"
PR_SCRIPT="$DSO_PLUGIN_DIR/scripts/merge-to-main-pr.sh"

# shellcheck source=../lib/assert.sh
source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-merge-to-main-self-healing-push.sh ==="

# =============================================================================
# Test D: --help mentions the bump default behavior (cb31-3552 Defect D)
# Prior text claimed "no version bump" but production defaults to --bump=patch
# when version.file_path is configured.
# =============================================================================
echo ""
echo "--- test_help_documents_bump_default_when_version_file_configured ---"
_snapshot_fail

_HELP_OUTPUT=$(bash "$DIRECT_SCRIPT" --help 2>&1 || true)
assert_contains "test_help_documents_bump_default_when_version_file_configured" \
    "defaults to --bump=patch" "$_HELP_OUTPUT"

assert_pass_if_clean "test_help_documents_bump_default_when_version_file_configured"

# Test A (formerly source-grepping for bump-before-push ordering) was deleted
# during the b6e3-e771 + bbba-123d remediation. The observable ordering claim
# (bump commit reaches origin/<branch> before the merge to main) is verified
# end-to-end by t_pr_version_bump_pushed_to_origin in test-merge-to-main-pr.sh.
# Per behavioral testing standard rule 3 (Behavioral Testing Standard
# skills/shared/prompts/behavioral-testing-standard.md), source-file grepping
# of merge-to-main-pr.sh for function-call ordering is a change-detector.

# =============================================================================
# Test C-structural: _phase_push_self_healing helper exists and _phase_push
# calls it instead of the bare retry_with_backoff git push (cb31-3552 Defect C).
# =============================================================================
echo ""
echo "--- test_phase_push_uses_self_healing_helper ---"
_snapshot_fail

# Helper must be defined
_HELPER_DEFINED=0
grep -qE '^_phase_push_self_healing\(\)' "$DIRECT_SCRIPT" && _HELPER_DEFINED=1
assert_eq "self_healing_helper_defined" "1" "$_HELPER_DEFINED"

# _phase_push body must call it
_PUSH_CALLS_HELPER=$(awk '
    /^_phase_push\(\) \{/ { in_func = 1; next }
    in_func && /^\}$/ { in_func = 0 }
    in_func && /_phase_push_self_healing/ { print "calls_helper"; exit }
' "$DIRECT_SCRIPT")
assert_eq "phase_push_calls_self_healing_helper" "calls_helper" "$_PUSH_CALLS_HELPER"

# _phase_push body must NOT call the bare retry_with_backoff for git push anymore
_PUSH_HAS_BARE_RETRY=$(awk '
    /^_phase_push\(\) \{/ { in_func = 1; next }
    in_func && /^\}$/ { in_func = 0 }
    in_func && /retry_with_backoff.*git push/ { print "still_bare"; exit }
' "$DIRECT_SCRIPT")
assert_eq "phase_push_no_bare_retry_with_backoff" "" "$_PUSH_HAS_BARE_RETRY"

assert_pass_if_clean "test_phase_push_uses_self_healing_helper"

# =============================================================================
# Test C-behavioral: _phase_push_self_healing succeeds on first attempt when
# push works (happy path).
# Fixture: tiny local + bare-remote pair; the bump commit pushes cleanly.
# =============================================================================
echo ""
echo "--- test_self_healing_push_succeeds_when_push_clean ---"
_snapshot_fail

_TEST_BASE=$(mktemp -d "${TMPDIR:-/tmp}/dso-self-healing-clean.XXXXXX")
trap 'rm -rf "$_TEST_BASE"' EXIT

(
    set -e
    cd "$_TEST_BASE" || return
    git init --bare -q --initial-branch=main bare.git 2>/dev/null || git init --bare -q bare.git
    git clone -q bare.git work
    cd work
    git config user.email "t@t.com"
    git config user.name "T"
    echo "1.0.0" > version.txt
    git add version.txt
    git commit -q -m "initial"
    # Force branch name to "main" regardless of init.defaultBranch on the runner
    git branch -M main 2>/dev/null || git checkout -B main 2>/dev/null
    git push -q origin main
    # Now bump locally
    echo "1.0.1" > version.txt
    git add version.txt
    git commit -q -m "bump"
)

# Extract and source the helper
_HELPER_FN=$(awk '
    /^_phase_push_self_healing\(\) \{/ { in_func = 1 }
    in_func { print }
    in_func && /^\}/ { exit }
' "$DIRECT_SCRIPT")

# Fail-fast: if extraction produced an empty body, the function-call assertions
# below would be meaningless (eval of "" succeeds, _phase_push_self_healing
# would later fail as "command not found" rather than as a real behavioral
# failure). llm-review f-i9j0k1l2 / f-h8i9j0k1.
if [[ -z "$_HELPER_FN" ]] || ! grep -q "^_phase_push_self_healing" <<< "$_HELPER_FN"; then
    echo "FATAL: failed to extract _phase_push_self_healing from $DIRECT_SCRIPT" >&2
    echo "       Function signature may have changed; AWK pattern expects: '^_phase_push_self_healing() {'" >&2
    exit 1
fi

_SH_RC=0
_SH_OUT=$(
    cd "$_TEST_BASE/work"
    eval "$_HELPER_FN"
    _phase_push_self_healing 2>&1
) || _SH_RC=$?

assert_eq "self_healing_clean_push_exits_0" "0" "$_SH_RC"

assert_pass_if_clean "test_self_healing_push_succeeds_when_push_clean"
rm -rf "$_TEST_BASE"

# =============================================================================
# Test H4: _phase_push_self_healing returns nonzero AND aborts rebase cleanly
# when origin/main has a conflicting commit on the same file (concurrent
# version bump scenario). Working tree must be left clean (no REBASE_HEAD).
# =============================================================================
echo ""
echo "--- test_self_healing_push_aborts_rebase_on_conflict ---"
_snapshot_fail

_TEST_BASE=$(mktemp -d "${TMPDIR:-/tmp}/dso-self-healing-conflict.XXXXXX")
trap 'rm -rf "$_TEST_BASE"' EXIT

# set -e inside the subshell so a failed cd/git command aborts the fixture
# rather than silently running subsequent commands in the wrong directory
# (llm-review f-g7h8i9j0: prior fixture suppressed stderr and had no -e, so
# a cd failure would silently corrupt the fixture and produce a misleading
# test result).
(
    set -e
    cd "$_TEST_BASE" || return
    git init --bare -q --initial-branch=main bare.git 2>/dev/null || git init --bare -q bare.git
    git clone -q bare.git work
    cd work
    git config user.email "t@t.com"
    git config user.name "T"
    echo "1.0.0" > version.txt
    git add version.txt
    git commit -q -m "initial"
    git branch -M main 2>/dev/null || git checkout -B main 2>/dev/null
    git push -q origin main

    # Simulate a concurrent foreign version bump on origin/main:
    # clone the bare repo separately, push a divergent commit touching version.txt.
    cd "$_TEST_BASE" || return
    git clone -q bare.git foreign
    cd foreign
    git config user.email "f@f.com"
    git config user.name "F"
    echo "2.0.0" > version.txt  # different value → conflict with local 1.0.1
    git add version.txt
    git commit -q -m "foreign bump"
    git branch -M main 2>/dev/null || git checkout -B main 2>/dev/null
    git push -q origin main

    # Now local creates its own bump
    cd "$_TEST_BASE/work"
    echo "1.0.1" > version.txt
    git add version.txt
    git commit -q -m "local bump"
)

_HELPER_FN=$(awk '
    /^_phase_push_self_healing\(\) \{/ { in_func = 1 }
    in_func { print }
    in_func && /^\}/ { exit }
' "$DIRECT_SCRIPT")

# Fail-fast on empty extraction (llm-review f-i9j0k1l2 / f-h8i9j0k1)
if [[ -z "$_HELPER_FN" ]] || ! grep -q "^_phase_push_self_healing" <<< "$_HELPER_FN"; then
    echo "FATAL: failed to extract _phase_push_self_healing from $DIRECT_SCRIPT" >&2
    exit 1
fi

_SH_RC=0
_SH_OUT=$(
    cd "$_TEST_BASE/work"
    eval "$_HELPER_FN"
    _phase_push_self_healing 2>&1
) || _SH_RC=$?

# Assert: exit code is nonzero
assert_ne "self_healing_conflict_exits_nonzero" "0" "$_SH_RC"

# Assert: no leftover REBASE_HEAD (rebase was aborted cleanly)
_LEFTOVER_REBASE_HEAD="absent"
if [[ -f "$_TEST_BASE/work/.git/REBASE_HEAD" ]] || [[ -d "$_TEST_BASE/work/.git/rebase-merge" ]] || [[ -d "$_TEST_BASE/work/.git/rebase-apply" ]]; then
    _LEFTOVER_REBASE_HEAD="present"
fi
assert_eq "self_healing_conflict_aborts_rebase_cleanly" "absent" "$_LEFTOVER_REBASE_HEAD"

# Assert: error message mentions manual recovery
assert_contains "self_healing_conflict_emits_recovery_hint" "Manual recovery" "$_SH_OUT"

assert_pass_if_clean "test_self_healing_push_aborts_rebase_on_conflict"
rm -rf "$_TEST_BASE"
trap - EXIT

print_summary
