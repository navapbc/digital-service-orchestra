#!/usr/bin/env bash
# Behavioral regression tests for _check_duplicate_pr consumer-compat after isDraft amendment
#
# These tests verify that _check_duplicate_pr correctly filters draft PRs for each
# known caller workflow:
#
#   Scenario 1 (sprint):      gh returns one draft PR (isDraft:true)  → exit 0 (guard passes)
#   Scenario 2 (fix-bug/debug): gh returns no PRs (empty array [])   → exit 0 (guard passes)
#   Scenario 3 (blocked):     gh returns one non-draft PR (isDraft:false) → exit non-zero
#
# Strategy: PATH-prepended gh stub; source merge-to-main-pr.sh via PR_LIB_MODE=1
# to expose _check_duplicate_pr without running the full pipeline.
#
# Usage: bash tests/scripts/test-merge-to-main-pr-consumer-compat.sh

set -uo pipefail
PASS=0; FAIL=0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git rev-parse --show-toplevel)"
DSO_PLUGIN_DIR="$REPO_ROOT/plugins/dso"
PR_SCRIPT="$DSO_PLUGIN_DIR/scripts/merge-to-main-pr.sh"

# Isolate from ambient host-project env vars (mirrors test-merge-to-main-pr.sh pattern).
unset PROJECT_ROOT CLAUDE_PROJECT_DIR _MERGE_STATE_GIT_DIR

# ---------------------------------------------------------------------------
# Shared fixture builder
# ---------------------------------------------------------------------------
# _build_consumer_fixture <tmpdir> <PR_LIST_MODE>
#   Writes a gh stub + minimal git repo into <tmpdir>/bin + <tmpdir>.
#   PR_LIST_MODE controls what gh pr list emits:
#     draft     → [{isDraft:true,  number:1, url:".../pull/1"}]
#     non_draft → [{isDraft:false, number:2, url:".../pull/2"}]
#     empty     → []  (gh returns empty, no PRs)
# ---------------------------------------------------------------------------
_build_consumer_fixture() {
    local tmpdir="$1" pr_list_mode="$2"
    local bin="$tmpdir/bin"
    mkdir -p "$bin"

    local real_git
    real_git=$(command -v git)

    # gh stub: pr list returns payload driven by PR_LIST_MODE env var.
    # The stub emits the raw JSON array, then pipes it through any --jq filter
    # argument so it behaves like real gh (which processes --jq internally).
    # This ensures the isDraft filter in _check_duplicate_pr is exercised.
    cat > "$bin/gh" <<'GH_STUB_EOF'
#!/usr/bin/env bash
case "$1" in
  --version)
    echo "gh version 2.40.1 (2024-01-01)"
    exit 0
    ;;
  pr)
    case "$2" in
      list)
        # Extract --jq filter value from args (any position after "pr list")
        _jq_filter=""
        _prev=""
        for _a in "$@"; do
          if [[ "$_prev" == "--jq" ]]; then
            _jq_filter="$_a"
          fi
          _prev="$_a"
        done

        case "${PR_LIST_MODE:-empty}" in
          draft)
            _payload='[{"number":1,"url":"https://github.com/test/repo/pull/1","isDraft":true}]'
            ;;
          non_draft)
            _payload='[{"number":2,"url":"https://github.com/test/repo/pull/2","isDraft":false}]'
            ;;
          empty)
            _payload='[]'
            ;;
          *)
            _payload='[]'
            ;;
        esac

        if [[ -n "$_jq_filter" ]]; then
          printf '%s' "$_payload" | jq -r "$_jq_filter" 2>/dev/null
        else
          printf '%s\n' "$_payload"
        fi
        exit 0
        ;;
      *) exit 0 ;;
    esac
    ;;
  *) exit 0 ;;
esac
GH_STUB_EOF
    chmod +x "$bin/gh"

    # git stub: intercept push, delegate everything else to real git.
    cat > "$bin/git" <<GIT_STUB_EOF
#!/usr/bin/env bash
if [[ "\$1" == "push" ]]; then
  exit 0
fi
exec "$real_git" "\$@"
GIT_STUB_EOF
    chmod +x "$bin/git"

    # Minimal git repo so rev-parse and branch detection resolve correctly.
    (
        cd "$tmpdir" || exit 1
        "$real_git" init -q -b main >/dev/null 2>&1
        "$real_git" config user.email "test@test.local"
        "$real_git" config user.name "test"
        echo "seed" > seed.txt
        "$real_git" add seed.txt
        "$real_git" commit -q -m "seed" >/dev/null
        "$real_git" checkout -q -b "feature-consumer-compat"
        echo "work" > work.txt
        "$real_git" add work.txt
        "$real_git" commit -q -m "work" >/dev/null
    )
}

# ---------------------------------------------------------------------------
# Helper: source merge-to-main-pr.sh in PR_LIB_MODE=1 and call _check_duplicate_pr.
# Returns the exit code of _check_duplicate_pr.
# ---------------------------------------------------------------------------
_run_check_dup() {
    local tmpdir="$1" pr_list_mode="$2"
    local wrapper
    wrapper="$(mktemp /tmp/dso-consumer-compat-wrapper.XXXXXX)"
    cat > "$wrapper" <<WRAPPER_EOF
#!/usr/bin/env bash
set +e
# shellcheck disable=SC1090
PR_LIB_MODE=1 source "$PR_SCRIPT" 2>/dev/null
_check_duplicate_pr 2>/dev/null
exit \$?
WRAPPER_EOF
    chmod +x "$wrapper"
    (
        cd "$tmpdir" || exit 1
        PATH="$tmpdir/bin:$PATH" \
        CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" \
        MERGE_STRATEGY="pr" \
        BRANCH="feature-consumer-compat" \
        PR_LIST_MODE="$pr_list_mode" \
        bash "$wrapper"
    )
    local _ec=$?
    rm -f "$wrapper"
    return "$_ec"
}

# ---------------------------------------------------------------------------
# Test helpers
# ---------------------------------------------------------------------------
_pass() { printf "PASS: %s\n" "$1"; (( ++PASS )); }
_fail() { printf "FAIL: %s\n" "$1" >&2; (( ++FAIL )); }

# ---------------------------------------------------------------------------
# Scenario 1: Sprint workflow — gh returns a draft PR (isDraft:true)
#
# Given: gh pr list returns one draft PR entry (isDraft:true), simulating an
#        active sprint PR created in Phase A of sprint/SKILL.md.
# When:  _check_duplicate_pr runs (called via merge-to-main.sh from end-session).
# Then:  exit 0 — draft PR must be filtered out; guard must pass so the sprint
#        merge proceeds without a false-positive duplicate-PR error.
# ---------------------------------------------------------------------------
t_sprint_draft_pr_guard_passes() {
    local _T _ec
    _T="$(mktemp -d /tmp/dso-consumer-compat.XXXXXX)"
    # shellcheck disable=SC2064
    trap "rm -rf '$_T'" RETURN

    _build_consumer_fixture "$_T" "draft"

    _run_check_dup "$_T" "draft"
    _ec=$?

    if [[ "$_ec" -eq 0 ]]; then
        _pass "t_sprint_draft_pr_guard_passes: exits 0 when only draft PR exists"
    else
        _fail "t_sprint_draft_pr_guard_passes: expected exit 0, got $_ec"
    fi
}
t_sprint_draft_pr_guard_passes

# ---------------------------------------------------------------------------
# Scenario 2: fix-bug/debug workflow — gh returns no PRs (empty array)
#
# Given: gh pr list returns [] (no open PRs exist), simulating the typical
#        fix-bug/debug-everything flow where no PR has been created yet.
# When:  _check_duplicate_pr runs (called via merge-to-main.sh from end-session).
# Then:  exit 0 — guard must pass when no open PR exists for the branch.
# ---------------------------------------------------------------------------
t_fixbug_debug_no_pr_guard_passes() {
    local _T _ec
    _T="$(mktemp -d /tmp/dso-consumer-compat.XXXXXX)"
    # shellcheck disable=SC2064
    trap "rm -rf '$_T'" RETURN

    _build_consumer_fixture "$_T" "empty"

    _run_check_dup "$_T" "empty"
    _ec=$?

    if [[ "$_ec" -eq 0 ]]; then
        _pass "t_fixbug_debug_no_pr_guard_passes: exits 0 when no open PRs exist"
    else
        _fail "t_fixbug_debug_no_pr_guard_passes: expected exit 0, got $_ec"
    fi
}
t_fixbug_debug_no_pr_guard_passes

# ---------------------------------------------------------------------------
# Scenario 3: Blocked case — gh returns a non-draft PR (isDraft:false)
#
# Given: gh pr list returns one non-draft PR entry (isDraft:false), simulating
#        a situation where a reviewer-visible PR was already opened for the branch.
# When:  _check_duplicate_pr runs.
# Then:  exits non-zero AND stderr contains "non-draft PR already exists".
#        The guard must block to prevent creating a duplicate reviewer-visible PR.
# ---------------------------------------------------------------------------
t_non_draft_pr_guard_blocked() {
    local _T _ec _stderr
    _T="$(mktemp -d /tmp/dso-consumer-compat.XXXXXX)"
    # shellcheck disable=SC2064
    trap "rm -rf '$_T'" RETURN

    _build_consumer_fixture "$_T" "non_draft"

    local wrapper
    wrapper="$(mktemp /tmp/dso-consumer-compat-wrapper2.XXXXXX)"
    cat > "$wrapper" <<WRAPPER2_EOF
#!/usr/bin/env bash
set +e
# shellcheck disable=SC1090
PR_LIB_MODE=1 source "$PR_SCRIPT" 2>/dev/null
_check_duplicate_pr
exit \$?
WRAPPER2_EOF
    chmod +x "$wrapper"

    local _err_out
    _err_out="$(mktemp /tmp/dso-consumer-compat-err.XXXXXX)"
    (
        cd "$_T" || exit 1
        PATH="$_T/bin:$PATH" \
        CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" \
        MERGE_STRATEGY="pr" \
        BRANCH="feature-consumer-compat" \
        PR_LIST_MODE="non_draft" \
        bash "$wrapper" 2>"$_err_out"
    )
    _ec=$?
    _stderr="$(cat "$_err_out")"
    rm -f "$wrapper" "$_err_out"

    local _exit_ok="false" _msg_ok="false"
    [[ "$_ec" -ne 0 ]] && _exit_ok="true"
    [[ "$_stderr" == *"non-draft PR already exists"* ]] && _msg_ok="true"

    if [[ "$_exit_ok" == "true" ]]; then
        _pass "t_non_draft_pr_guard_blocked: exits non-zero when non-draft PR exists"
    else
        _fail "t_non_draft_pr_guard_blocked: expected non-zero exit, got 0"
    fi

    if [[ "$_msg_ok" == "true" ]]; then
        _pass "t_non_draft_pr_guard_blocked: stderr contains 'non-draft PR already exists'"
    else
        _fail "t_non_draft_pr_guard_blocked: stderr missing expected message; got: '$_stderr'"
    fi
}
t_non_draft_pr_guard_blocked

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
printf "\nPASSED: %d  FAILED: %d\n" "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
