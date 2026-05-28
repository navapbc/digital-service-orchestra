#!/usr/bin/env bash
# shellcheck disable=SC2046,SC2329
# tests/scripts/test-merge-to-main-pr-story-base.sh
# Behavioral tests asserting merge-to-main-pr.sh opens story/* PRs with
# --base=<SESSION_BRANCH> (not --base=main) when STORY_PR_BASE is set.
#
# Tests (RED phase — all FAIL before implementation):
#   1. test_story_pr_uses_session_branch_as_base
#        When STORY_PR_BASE=session-20260515, gh pr create uses
#        --base session-20260515 (not --base main). Mock gh CLI. Verify via
#        captured argv log.
#   2. test_story_pr_base_unset_defaults_to_main
#        When STORY_PR_BASE is unset, gh pr create uses --base main (backward compat).
#   3. test_story_pr_base_empty_defaults_to_main
#        When STORY_PR_BASE="" (empty string), gh pr create uses --base main.
#
# Usage: bash tests/scripts/test-merge-to-main-pr-story-base.sh

set -uo pipefail

# Disable commit signing for temp test repos.
export GIT_CONFIG_COUNT=1        # isolation-ok: scoped to this test process
export GIT_CONFIG_KEY_0=commit.gpgsign  # isolation-ok
export GIT_CONFIG_VALUE_0=false  # isolation-ok

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git rev-parse --show-toplevel)"
DSO_PLUGIN_DIR="$REPO_ROOT/plugins/dso"
PR_SCRIPT="$DSO_PLUGIN_DIR/scripts/merge-to-main-pr.sh"

# Prevent env vars set by the dso shim from leaking into the fixture's git ops.
unset PROJECT_ROOT CLAUDE_PROJECT_DIR _MERGE_STATE_GIT_DIR

# Default LLM dispatch to no-ops so tests reach gh pr create without tripping
# fail-loud guards.
export _LLM_DISPATCH_CMD="${_LLM_DISPATCH_CMD:-/bin/true}"
export _RESOLVE_CONFLICTS_LLM_CMD="${_RESOLVE_CONFLICTS_LLM_CMD:-/bin/true}"
export _REMEDIATE_LLM_CMD="${_REMEDIATE_LLM_CMD:-/bin/true}"

# shellcheck source=../lib/assert.sh
source "$REPO_ROOT/tests/lib/assert.sh"

# ---------------------------------------------------------------------------
# Shared fixture builder
# Builds a minimal temp git repo + PATH-shimmed gh/git binaries.
# Usage: _build_story_pr_fixture <tmpdir> <branch>
# ---------------------------------------------------------------------------
_build_story_pr_fixture() {
    local tmpdir="$1" branch="$2"
    local bin="$tmpdir/bin"
    mkdir -p "$bin"

    local gh_argv_log="$tmpdir/gh-argv.log"

    # ---- gh shim: records argv and returns scripted success responses ----
    cat > "$bin/gh" <<GH_SHIM
#!/usr/bin/env bash
# Record full argv (one invocation per line, args space-separated)
printf '%s\n' "\$*" >> "$gh_argv_log"
case "\$1" in
  --version)
    echo "gh version 2.40.1 (2024-01-01)"
    exit 0
    ;;
  pr)
    case "\$2" in
      list)
        # Duplicate-PR guard — return empty (no existing PRs)
        exit 0
        ;;
      create)
        echo "https://github.com/x/y/pull/99"
        exit 0
        ;;
      view)
        if [[ "\$*" == *"--json state"* ]]; then
          echo "MERGED"
          exit 0
        fi
        if [[ "\$*" == *"--json headRefOid"* ]]; then
          echo ""
          exit 0
        fi
        if [[ "\$*" == *"comments,reviews,reviewThreads"* ]]; then
          echo "{}"
          exit 0
        fi
        echo '{"mergeable":"MERGEABLE","number":99,"url":"https://github.com/x/y/pull/99"}'
        exit 0
        ;;
      checks)
        echo '[{"name":"ci","state":"COMPLETED","conclusion":"SUCCESS"}]'
        exit 0
        ;;
      merge)
        exit 0
        ;;
      *) exit 0 ;;
    esac
    ;;
  api)
    if [[ "\$2" == "graphql" ]]; then
      echo '{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[]}}}}}'
      exit 0
    fi
    exit 0
    ;;
  repo)
    if [[ "\$2" == "view" ]]; then
      if [[ "\$*" == *"defaultBranchRef"* ]]; then
        echo "main"
        exit 0
      fi
      echo "x/y"
      exit 0
    fi
    exit 0
    ;;
  *) exit 0 ;;
esac
GH_SHIM
    chmod +x "$bin/gh"

    # ---- git shim: intercept push; pass everything else to real git ----
    local real_git
    real_git=$(command -v git)
    local git_push_log="$tmpdir/git-push.log"
    cat > "$bin/git" <<GIT_SHIM
#!/usr/bin/env bash
if [[ "\$1" == "push" ]]; then
  printf '%s\n' "\$*" >> "$git_push_log"
  exit 0
fi
exec "$real_git" "\$@"
GIT_SHIM
    chmod +x "$bin/git"

    # ---- Minimal git repo so rev-parse + branch detection resolve ----
    (
        cd "$tmpdir" || exit 1
        "$real_git" init -q -b main >/dev/null 2>&1
        "$real_git" config user.email "test@test.local"
        "$real_git" config user.name "test"
        echo "seed" > seed.txt
        "$real_git" add seed.txt
        "$real_git" commit -q -m "seed" >/dev/null
        "$real_git" checkout -q -b "$branch"
        echo "feature" > feature.txt
        "$real_git" add feature.txt
        "$real_git" commit -q -m "feature work" >/dev/null
    )
}

# ---------------------------------------------------------------------------
# Test 1: test_story_pr_uses_session_branch_as_base
# When STORY_PR_BASE=session-20260515 is set, gh pr create must use
# --base session-20260515, not --base main.
#
# RED: FAILS before implementation because merge-to-main-pr.sh currently
# hard-codes --base main in _phase_merge.
# ---------------------------------------------------------------------------
test_story_pr_uses_session_branch_as_base() {
    local _T branch _argv _has_session_base _has_main_base
    _T="$(mktemp -d "${TMPDIR:-/tmp}/dso-story-pr-test.XXXXXX")"
    # shellcheck disable=SC2064
    trap "rm -rf '$_T'" RETURN

    branch="story/d076-d35e/2abb-11b6"
    _build_story_pr_fixture "$_T" "$branch"

    (
        cd "$_T" || exit 1
        PATH="$_T/bin:$PATH" \
        CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" \
        MERGE_STRATEGY="pr" \
        STORY_PR_BASE="session-20260515" \
        PR_THREAD_LOOP_START_OVERRIDE_SECONDS=200 \
        PR_THREAD_LOOP_INTERVAL=0 \
        bash "$PR_SCRIPT" >/dev/null 2>&1
    ) || true

    _argv="$(cat "$_T/gh-argv.log" 2>/dev/null || echo '')"

    # Assert: --base session-20260515 appears in the pr create invocation
    _has_session_base="false"
    if echo "$_argv" | grep -qE "^[[:space:]]*pr create .*--base session-20260515"; then
        _has_session_base="true"
    elif echo "$_argv" | grep -qE "^[[:space:]]*pr create .*--base=session-20260515"; then
        _has_session_base="true"
    fi

    # Assert: --base main does NOT appear in the pr create invocation
    _has_main_base="false"
    if echo "$_argv" | grep -qE "^[[:space:]]*pr create .*--base main"; then
        _has_main_base="true"
    elif echo "$_argv" | grep -qE "^[[:space:]]*pr create .*--base=main"; then
        _has_main_base="true"
    fi

    assert_eq "test_story_pr_uses_session_branch_as_base:uses_session_branch" \
              "true" "$_has_session_base"
    assert_eq "test_story_pr_uses_session_branch_as_base:not_main" \
              "false" "$_has_main_base"
}
test_story_pr_uses_session_branch_as_base

# ---------------------------------------------------------------------------
# Test 2: test_story_pr_base_unset_defaults_to_main
# When STORY_PR_BASE is unset, gh pr create must still use --base main
# (backward compatibility preserved).
#
# GREEN even before implementation because current code already defaults to
# main — this test validates backward compat is not broken by the new feature.
# ---------------------------------------------------------------------------
test_story_pr_base_unset_defaults_to_main() {
    local _T branch _argv _has_main_base
    _T="$(mktemp -d "${TMPDIR:-/tmp}/dso-story-pr-test.XXXXXX")"
    # shellcheck disable=SC2064
    trap "rm -rf '$_T'" RETURN

    branch="story/d076-d35e/2abb-1234"
    _build_story_pr_fixture "$_T" "$branch"

    (
        cd "$_T" || exit 1
        unset STORY_PR_BASE
        PATH="$_T/bin:$PATH" \
        CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" \
        MERGE_STRATEGY="pr" \
        PR_THREAD_LOOP_START_OVERRIDE_SECONDS=200 \
        PR_THREAD_LOOP_INTERVAL=0 \
        bash "$PR_SCRIPT" >/dev/null 2>&1
    ) || true

    _argv="$(cat "$_T/gh-argv.log" 2>/dev/null || echo '')"

    _has_main_base="false"
    if echo "$_argv" | grep -qE "^[[:space:]]*pr create .*--base main"; then
        _has_main_base="true"
    elif echo "$_argv" | grep -qE "^[[:space:]]*pr create .*--base=main"; then
        _has_main_base="true"
    fi

    assert_eq "test_story_pr_base_unset_defaults_to_main" \
              "true" "$_has_main_base"
}
test_story_pr_base_unset_defaults_to_main

# ---------------------------------------------------------------------------
# Test 3: test_story_pr_base_empty_defaults_to_main
# When STORY_PR_BASE="" (empty string), gh pr create must use --base main.
#
# RED: FAILS before implementation if empty string is not handled gracefully
# and falls through to an empty --base value.
# ---------------------------------------------------------------------------
test_story_pr_base_empty_defaults_to_main() {
    local _T branch _argv _has_main_base _has_empty_base
    _T="$(mktemp -d "${TMPDIR:-/tmp}/dso-story-pr-test.XXXXXX")"
    # shellcheck disable=SC2064
    trap "rm -rf '$_T'" RETURN

    branch="story/d076-d35e/2abb-5678"
    _build_story_pr_fixture "$_T" "$branch"

    (
        cd "$_T" || exit 1
        PATH="$_T/bin:$PATH" \
        CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" \
        MERGE_STRATEGY="pr" \
        STORY_PR_BASE="" \
        PR_THREAD_LOOP_START_OVERRIDE_SECONDS=200 \
        PR_THREAD_LOOP_INTERVAL=0 \
        bash "$PR_SCRIPT" >/dev/null 2>&1
    ) || true

    _argv="$(cat "$_T/gh-argv.log" 2>/dev/null || echo '')"

    # Empty STORY_PR_BASE must resolve to main (not --base "")
    _has_main_base="false"
    if echo "$_argv" | grep -qE "^[[:space:]]*pr create .*--base main"; then
        _has_main_base="true"
    elif echo "$_argv" | grep -qE "^[[:space:]]*pr create .*--base=main"; then
        _has_main_base="true"
    fi

    # Verify --base with empty value does NOT appear
    _has_empty_base="false"
    if echo "$_argv" | grep -qE "^[[:space:]]*pr create .*--base $"; then
        _has_empty_base="true"
    elif echo "$_argv" | grep -qE "^[[:space:]]*pr create .*--base=\s*$"; then
        _has_empty_base="true"
    fi

    assert_eq "test_story_pr_base_empty_defaults_to_main:uses_main" \
              "true" "$_has_main_base"
    assert_eq "test_story_pr_base_empty_defaults_to_main:not_empty_base" \
              "false" "$_has_empty_base"
}
test_story_pr_base_empty_defaults_to_main

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
print_summary
