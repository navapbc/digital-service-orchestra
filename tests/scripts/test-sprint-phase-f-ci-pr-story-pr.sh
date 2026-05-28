#!/usr/bin/env bash
# tests/scripts/test-sprint-phase-f-ci-pr-story-pr.sh
# Behavioral tests for sprint Phase F ci-pr mode story-branch PR creation.
#
# TDD (RED) tests — all tests in this file expected to FAIL before implementation.
#
# Test scenarios:
#   3. test_dso_story_merge_trailer_contract_exists
#      Assert plugins/dso/docs/contracts/dso-story-merge-trailer.md exists.
#      FAILS before the contract file is created.
#
#   4. test_dso_story_merge_trailer_contract_has_required_fields
#      Parse the contract file and assert it documents:
#        - trailer name (DSO-Story-Merge)
#        - value format (story-id)
#        - line position (last line of commit message body)
#        - consumer reference (S5 provenance verifier)
#      FAILS before the contract file is created.
#
#   5. test_sprint_phase_f_sets_story_pr_base_from_resolve
#      Integration smoke: when GH_PR_VIEW_OVERRIDE=session-branch-name is set
#      and merge-to-main.sh is called with STORY_PR_BASE="$GH_PR_VIEW_OVERRIDE",
#      the emitted gh pr create (mocked) uses --base session-branch-name.
#      Exercises that SKILL.md Phase F orchestration plumbing resolves then
#      injects STORY_PR_BASE correctly.
#      FAILS before SKILL.md update (T5).
#
# Usage: bash tests/scripts/test-sprint-phase-f-ci-pr-story-pr.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
RESOLVE_SCRIPT="$REPO_ROOT/plugins/dso/scripts/resolve-session-branch.sh"
MERGE_TO_MAIN="$REPO_ROOT/plugins/dso/scripts/merge-to-main.sh"
CONTRACT_FILE="$REPO_ROOT/plugins/dso/docs/contracts/dso-story-merge-trailer.md"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-sprint-phase-f-ci-pr-story-pr.sh ==="

# =============================================================================
# Test 3: test_dso_story_merge_trailer_contract_exists
# Given the contracts directory exists
# When the dso-story-merge-trailer.md contract file does not exist
# Then this test FAILS (RED phase)
# =============================================================================
echo ""
echo "--- test_dso_story_merge_trailer_contract_exists ---"
_snapshot_fail

_T3_EXISTS="no"
if [[ -f "$CONTRACT_FILE" ]]; then
    _T3_EXISTS="yes"
fi

assert_eq \
    "test_dso_story_merge_trailer_contract_exists" \
    "yes" \
    "$_T3_EXISTS"

assert_pass_if_clean "test_dso_story_merge_trailer_contract_exists"

# =============================================================================
# Test 4: test_dso_story_merge_trailer_contract_has_required_fields
# Given the contract file exists (or not — this test handles both)
# When we parse the contract file
# Then it must document: trailer name, value format, line position, and consumer
# FAILS before contract file is created (file does not exist yet).
# =============================================================================
echo ""
echo "--- test_dso_story_merge_trailer_contract_has_required_fields ---"
_snapshot_fail

if [[ ! -f "$CONTRACT_FILE" ]]; then
    # Contract file missing — all 4 sub-assertions fail
    assert_eq \
        "test_contract_documents_trailer_name (file missing)" \
        "yes" \
        "no"
    assert_eq \
        "test_contract_documents_value_format (file missing)" \
        "yes" \
        "no"
    assert_eq \
        "test_contract_documents_line_position (file missing)" \
        "yes" \
        "no"
    assert_eq \
        "test_contract_documents_consumer_reference (file missing)" \
        "yes" \
        "no"
else
    _CONTRACT_CONTENT=$(cat "$CONTRACT_FILE")

    # 4a: Must document the trailer name "DSO-Story-Merge"
    _T4A_FOUND="no"
    if [[ "$_CONTRACT_CONTENT" == *"DSO-Story-Merge"* ]]; then
        _T4A_FOUND="yes"
    fi
    assert_eq \
        "test_contract_documents_trailer_name" \
        "yes" \
        "$_T4A_FOUND"

    # 4b: Must document the value format (story-id)
    _T4B_FOUND="no"
    if [[ "$_CONTRACT_CONTENT" == *"story-id"* ]] || \
       [[ "$_CONTRACT_CONTENT" == *"story_id"* ]] || \
       [[ "$_CONTRACT_CONTENT" == *"<story-id>"* ]]; then
        _T4B_FOUND="yes"
    fi
    assert_eq \
        "test_contract_documents_value_format" \
        "yes" \
        "$_T4B_FOUND"

    # 4c: Must document line position — last line of commit message body
    _T4C_FOUND="no"
    if [[ "$_CONTRACT_CONTENT" == *"last line"* ]] || \
       [[ "$_CONTRACT_CONTENT" == *"last-line"* ]] || \
       [[ "$_CONTRACT_CONTENT" == *"last line of"* ]] || \
       [[ "$_CONTRACT_CONTENT" == *"trailer"* && "$_CONTRACT_CONTENT" == *"commit message"* ]]; then
        _T4C_FOUND="yes"
    fi
    assert_eq \
        "test_contract_documents_line_position" \
        "yes" \
        "$_T4C_FOUND"

    # 4d: Must reference S5 provenance verifier as a consumer
    _T4D_FOUND="no"
    if [[ "$_CONTRACT_CONTENT" == *"S5"* ]] || \
       [[ "$_CONTRACT_CONTENT" == *"provenance"* ]] || \
       [[ "$_CONTRACT_CONTENT" == *"verifier"* ]]; then
        _T4D_FOUND="yes"
    fi
    assert_eq \
        "test_contract_documents_consumer_reference" \
        "yes" \
        "$_T4D_FOUND"
fi

assert_pass_if_clean "test_dso_story_merge_trailer_contract_has_required_fields"

# =============================================================================
# Test 5: test_sprint_phase_f_sets_story_pr_base_from_resolve
# Given:
#   - GH_PR_VIEW_OVERRIDE is set to a session branch name (simulates resolve)
#   - merge-to-main.sh is called with STORY_PR_BASE injected from resolve result
# When:
#   - resolve-session-branch.sh is called (uses GH_PR_VIEW_OVERRIDE shortcut)
#   - The result is passed as --base to the mocked gh pr create
# Then:
#   - gh pr create must be called with --base <session-branch>
# FAILS before SKILL.md Phase F is updated to inject STORY_PR_BASE.
#
# Strategy: mock gh, run resolve-session-branch.sh, capture STORY_PR_BASE,
# then run a minimal orchestration stub that calls gh pr create with --base.
# The test verifies that the --base value matches the resolved session branch.
# =============================================================================
echo ""
echo "--- test_sprint_phase_f_sets_story_pr_base_from_resolve ---"
_snapshot_fail

_T5_TMP_BIN="$(mktemp -d "${TMPDIR:-/tmp}/test-sprint-phase-f-bin.XXXXXX")"
_T5_GH_CALL_LOG="$(mktemp "${TMPDIR:-/tmp}/test-sprint-phase-f-calls.XXXXXX")"

_cleanup_t5() {
    rm -rf "$_T5_TMP_BIN" "$_T5_GH_CALL_LOG" 2>/dev/null || true
}
trap _cleanup_t5 EXIT

# Build a gh stub that logs all invocations
cat > "$_T5_TMP_BIN/gh" << GHSTUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$_T5_GH_CALL_LOG"
case "\$1" in
  "--version")
    # merge-to-main-pr.sh version gate requires "gh version X.Y.Z" on line 1
    echo "gh version 2.40.1 (2024-01-01)"
    exit 0
    ;;
esac
case "\$1 \$2" in
  "pr create")
    echo "https://github.com/example/repo/pull/42"
    exit 0
    ;;
  "pr view")
    # resolve-session-branch.sh calls gh pr view --json headRefName
    # The script has GH_PR_VIEW_OVERRIDE so this path is not reached in test
    echo "{\"headRefName\":\"test-session-branch\"}"
    exit 0
    ;;
  "pr list")
    # merge-to-main.sh may call gh pr list — return empty (no existing PR)
    echo "[]"
    exit 0
    ;;
  "api")
    # merge-to-main.sh may call gh api for repo vars
    echo "{\"value\":\"\"}"
    exit 0
    ;;
esac
exit 0
GHSTUB
chmod +x "$_T5_TMP_BIN/gh"

# Build a git stub that returns predictable values without needing a real repo
cat > "$_T5_TMP_BIN/git" << 'GITSTUB'
#!/usr/bin/env bash
# Strip leading -C <path> argument if present so downstream case matching works
_args=("$@")
if [[ "${_args[0]:-}" == "-C" ]]; then
    shift 2
fi
case "$1 $2" in
  "remote get-url")
    echo "https://github.com/example/test-repo.git"
    exit 0
    ;;
  "rev-parse --abbrev-ref")
    echo "story/test-epic/test-story-001"
    exit 0
    ;;
  "rev-parse --show-toplevel")
    # Return actual repo root so scripts can find their deps
    echo "REPO_ROOT_PLACEHOLDER"
    exit 0
    ;;
  "branch --show-current")
    echo "story/test-epic/test-story-001"
    exit 0
    ;;
  "push -u")
    # Stub out push — no real remote needed in test
    exit 0
    ;;
  "fetch origin")
    # Stub fetch — no-op in test
    exit 0
    ;;
  "log -1")
    echo "Test commit message"
    exit 0
    ;;
  "merge-base --is-ancestor")
    # Pretend local is already up-to-date (ancestor check passes) so no rebase needed
    exit 0
    ;;
esac
case "$1" in
  "push")
    # Catch all push variants — no real remote needed in test
    exit 0
    ;;
  "fetch")
    # Catch all fetch variants — no-op in test
    exit 0
    ;;
  "pull")
    # Catch all pull variants — no-op in test
    exit 0
    ;;
  "rebase")
    # Stub rebase — no-op in test
    exit 0
    ;;
esac
# Fall through to real git for anything else
exec /usr/bin/git "${_args[@]}"
GITSTUB
# Portable in-place replacement: BSD sed needs '' suffix; GNU sed does not accept it
if sed --version 2>/dev/null | grep -q GNU; then
    sed -i "s|REPO_ROOT_PLACEHOLDER|$REPO_ROOT|g" "$_T5_TMP_BIN/git"
else
    sed -i '' "s|REPO_ROOT_PLACEHOLDER|$REPO_ROOT|g" "$_T5_TMP_BIN/git"
fi
chmod +x "$_T5_TMP_BIN/git"

# Step 1: Resolve session branch via resolve-session-branch.sh
# GH_PR_VIEW_OVERRIDE simulates the ci-pr environment where PR head = session branch
_T5_RESOLVED_BRANCH=""
_T5_RESOLVE_RC=0
if [[ -f "$RESOLVE_SCRIPT" ]]; then
    _T5_RESOLVED_BRANCH=$(
        PATH="$_T5_TMP_BIN:$PATH" \
        GH_PR_VIEW_OVERRIDE="worktree-20260515-200444" \
        bash "$RESOLVE_SCRIPT" 2>/dev/null
    ) || _T5_RESOLVE_RC=$?
else
    # Script does not exist — fail cleanly
    _T5_RESOLVE_RC=1
fi

assert_eq \
    "test_resolve_session_branch_exits_0" \
    "0" \
    "$_T5_RESOLVE_RC"

assert_eq \
    "test_resolve_session_branch_returns_session_name" \
    "worktree-20260515-200444" \
    "$_T5_RESOLVED_BRANCH"

# Step 2: Verify STORY_PR_BASE injection — the orchestrator must pass the resolved
# branch as STORY_PR_BASE and ultimately as --base to gh pr create.
# We simulate the SKILL.md Phase F orchestration snippet:
#   SESSION_BRANCH=$(resolve-session-branch.sh)
#   STORY_PR_BASE="$SESSION_BRANCH"
#   ... call merge-to-main.sh or gh pr create with --base "$STORY_PR_BASE" ...
#
# Since merge-to-main.sh does not yet accept STORY_PR_BASE (T5 not yet implemented),
# this assertion checks that the orchestration contract (STORY_PR_BASE env var is
# used as --base) is ABSENT — i.e., the test FAILS in RED phase.

_T5_GH_CALLS=$(cat "$_T5_GH_CALL_LOG" 2>/dev/null || echo "")

# Simulate Phase F: call gh pr create directly with STORY_PR_BASE injection
# (represents what merge-to-main.sh SHOULD do after T5 is implemented)
_T5_STORY_PR_BASE="${_T5_RESOLVED_BRANCH}"
_T5_PR_RC=0

if [[ -f "$MERGE_TO_MAIN" ]]; then
    # merge-to-main.sh exists: check whether it accepts STORY_PR_BASE and uses it
    # as --base for story PRs. Before T5, it does NOT accept STORY_PR_BASE — the
    # PR base will default to main, not the session branch.
    #
    # Run merge-to-main.sh with STORY_PR_BASE set and a BRANCH (story branch).
    # Capture the gh pr create call from the log and check the --base argument.
    _T5_CALL_LOG_BEFORE=$(wc -l < "$_T5_GH_CALL_LOG" 2>/dev/null || echo "0")

    (
        PATH="$_T5_TMP_BIN:$PATH" \
        STORY_PR_BASE="$_T5_STORY_PR_BASE" \
        BRANCH="story/test-epic/test-story-001" \
        SPRINT_MODE="ci-pr" \
        bash "$MERGE_TO_MAIN" 2>/dev/null
    ) || _T5_PR_RC=$?

    _T5_GH_CALLS_AFTER=$(cat "$_T5_GH_CALL_LOG" 2>/dev/null || echo "")

    # Check whether gh pr create was called with --base session-branch
    # Before T5: merge-to-main.sh ignores STORY_PR_BASE → uses main as base
    # After T5:  merge-to-main.sh reads STORY_PR_BASE → uses session branch as base
    _T5_BASE_CORRECT="no"
    if echo "$_T5_GH_CALLS_AFTER" | grep -q -- "--base ${_T5_STORY_PR_BASE}"; then
        _T5_BASE_CORRECT="yes"
    fi

    assert_eq \
        "test_sprint_phase_f_story_pr_base_is_session_branch" \
        "yes" \
        "$_T5_BASE_CORRECT"
else
    # merge-to-main.sh not found — assertion fails in RED
    assert_eq \
        "test_sprint_phase_f_story_pr_base_is_session_branch (merge-to-main.sh missing)" \
        "yes" \
        "no"
fi

assert_pass_if_clean "test_sprint_phase_f_sets_story_pr_base_from_resolve"

# Cleanup
rm -rf "$_T5_TMP_BIN" "$_T5_GH_CALL_LOG" 2>/dev/null || true
trap - EXIT

# =============================================================================
print_summary
