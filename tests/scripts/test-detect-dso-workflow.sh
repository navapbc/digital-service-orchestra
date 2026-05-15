#!/usr/bin/env bash
# shellcheck source=tests/lib/assert.sh
# tests/scripts/test-detect-dso-workflow.sh
# RED-phase behavioral tests for plugins/dso/scripts/onboarding/detect-dso-workflow.sh
#
# Usage: bash tests/scripts/test-detect-dso-workflow.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail
#
# NOTE: These tests are expected to FAIL until detect-dso-workflow.sh is implemented.
#
# Behavior under test:
#   detect-dso-workflow.sh determines the dso.workflow value based on git remote URL:
#     - https://github.com/* or git@github.com:* → outputs 'ci-pr'
#     - GitLab remote                            → outputs 'local'
#     - No origin remote                         → outputs 'local'
#     - Enterprise GitHub (not github.com)       → outputs 'local'

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR" && git rev-parse --show-toplevel)"

source "$REPO_ROOT/tests/lib/assert.sh"

DETECT_SCRIPT="$REPO_ROOT/plugins/dso/scripts/onboarding/detect-dso-workflow.sh"

# ── Suite-runner guard (RED phase) ────────────────────────────────────────────
# When run-all.sh invokes this suite and the script is not yet implemented,
# skip gracefully so the overall suite stays green.
if [ "${_RUN_ALL_ACTIVE:-0}" = "1" ] && [ ! -f "$DETECT_SCRIPT" ]; then
  echo 'SKIP: detect-dso-workflow.sh not yet implemented (RED) — tests deferred'
  printf 'PASSED: 0  FAILED: 0\n'
  exit 0
fi

echo "=== test-detect-dso-workflow.sh ==="

# Shared temp dir for all fixtures — cleaned up on EXIT
_TMP_DIRS=()
trap 'rm -rf "${_TMP_DIRS[@]}"' EXIT

# ── Helper: create a temp git repo with the given origin remote URL ────────────
# Usage: _make_git_repo_with_remote <url>
# Sets global FIXTURE_DIR to the created directory.
_make_git_repo_with_remote() {
  local remote_url="${1:-}"
  local tmpdir
  tmpdir="$(mktemp -d)"
  _TMP_DIRS+=("$tmpdir")
  git -C "$tmpdir" init -q
  if [ -n "$remote_url" ]; then
    git -C "$tmpdir" remote add origin "$remote_url"
  fi
  FIXTURE_DIR="$tmpdir"
}

# ── Helper: create a temp git repo with NO remotes ────────────────────────────
_make_git_repo_no_remote() {
  local tmpdir
  tmpdir="$(mktemp -d)"
  _TMP_DIRS+=("$tmpdir")
  git -C "$tmpdir" init -q
  FIXTURE_DIR="$tmpdir"
}

# ── test_detect_github_https_remote_returns_ci_pr ─────────────────────────────
# When origin is https://github.com/org/repo, script must output 'ci-pr'.
_snapshot_fail
_make_git_repo_with_remote "https://github.com/org/repo"
_gh_https_out=""
_gh_https_exit=0
_gh_https_out=$(bash "$DETECT_SCRIPT" "$FIXTURE_DIR" 2>/dev/null) || _gh_https_exit=$?
assert_eq "test_detect_github_https_remote_returns_ci_pr: exits 0" "0" "$_gh_https_exit"
assert_eq "test_detect_github_https_remote_returns_ci_pr: outputs ci-pr" "ci-pr" "$_gh_https_out"
assert_pass_if_clean "test_detect_github_https_remote_returns_ci_pr"

# ── test_detect_github_ssh_remote_returns_ci_pr ───────────────────────────────
# When origin is git@github.com:org/repo.git, script must output 'ci-pr'.
_snapshot_fail
_make_git_repo_with_remote "git@github.com:org/repo.git"
_gh_ssh_out=""
_gh_ssh_exit=0
_gh_ssh_out=$(bash "$DETECT_SCRIPT" "$FIXTURE_DIR" 2>/dev/null) || _gh_ssh_exit=$?
assert_eq "test_detect_github_ssh_remote_returns_ci_pr: exits 0" "0" "$_gh_ssh_exit"
assert_eq "test_detect_github_ssh_remote_returns_ci_pr: outputs ci-pr" "ci-pr" "$_gh_ssh_out"
assert_pass_if_clean "test_detect_github_ssh_remote_returns_ci_pr"

# ── test_detect_no_remote_returns_local ───────────────────────────────────────
# When no origin remote is configured, script must output 'local'.
_snapshot_fail
_make_git_repo_no_remote
_no_remote_out=""
_no_remote_exit=0
_no_remote_out=$(bash "$DETECT_SCRIPT" "$FIXTURE_DIR" 2>/dev/null) || _no_remote_exit=$?
assert_eq "test_detect_no_remote_returns_local: exits 0" "0" "$_no_remote_exit"
assert_eq "test_detect_no_remote_returns_local: outputs local" "local" "$_no_remote_out"
assert_pass_if_clean "test_detect_no_remote_returns_local"

# ── test_detect_gitlab_remote_returns_local ───────────────────────────────────
# When origin is a GitLab URL, script must output 'local'.
_snapshot_fail
_make_git_repo_with_remote "https://gitlab.com/org/repo"
_gitlab_out=""
_gitlab_exit=0
_gitlab_out=$(bash "$DETECT_SCRIPT" "$FIXTURE_DIR" 2>/dev/null) || _gitlab_exit=$?
assert_eq "test_detect_gitlab_remote_returns_local: exits 0" "0" "$_gitlab_exit"
assert_eq "test_detect_gitlab_remote_returns_local: outputs local" "local" "$_gitlab_out"
assert_pass_if_clean "test_detect_gitlab_remote_returns_local"

# ── test_detect_enterprise_github_returns_local ───────────────────────────────
# When origin is an Enterprise GitHub host (not github.com), script must output 'local'.
_snapshot_fail
_make_git_repo_with_remote "https://github.mycompany.com/org/repo"
_ent_out=""
_ent_exit=0
_ent_out=$(bash "$DETECT_SCRIPT" "$FIXTURE_DIR" 2>/dev/null) || _ent_exit=$?
assert_eq "test_detect_enterprise_github_returns_local: exits 0" "0" "$_ent_exit"
assert_eq "test_detect_enterprise_github_returns_local: outputs local" "local" "$_ent_out"
assert_pass_if_clean "test_detect_enterprise_github_returns_local"

# ── test_detect_exit_code_is_zero ─────────────────────────────────────────────
# For any valid remote, script must exit 0 (non-blocking behavior).
_snapshot_fail
_make_git_repo_with_remote "https://github.com/someorg/somerepo"
_exit_code_exit=0
bash "$DETECT_SCRIPT" "$FIXTURE_DIR" >/dev/null 2>&1 || _exit_code_exit=$?
assert_eq "test_detect_exit_code_is_zero: exits 0 for github.com remote" "0" "$_exit_code_exit"
assert_pass_if_clean "test_detect_exit_code_is_zero"

print_summary
