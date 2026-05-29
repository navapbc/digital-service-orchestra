#!/usr/bin/env bash
# tests/scripts/test-match-session-branch.sh
#
# Behavioral tests for plugins/dso/scripts/ci/match-session-branch.sh (F4 fix).
#
# Verifies that the gate correctly accepts every session-branch shape in
# sub-pr-branch-patterns.txt and rejects non-session refs.
#
# Usage: bash tests/scripts/test-match-session-branch.sh

set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRIPT="$REPO_ROOT/plugins/dso/scripts/ci/match-session-branch.sh"

source "$REPO_ROOT/tests/lib/assert.sh"

_CLEANUP_DIRS=()
_cleanup_all() {
    local _d
    for _d in "${_CLEANUP_DIRS[@]+"${_CLEANUP_DIRS[@]}"}"; do
        rm -rf "$_d" 2>/dev/null || true
    done
}
trap _cleanup_all EXIT

echo "=== test-match-session-branch.sh ==="

# ── test_script_exists ────────────────────────────────────────────────────────
_snapshot_fail
if [[ -f "$SCRIPT" && -x "$SCRIPT" ]]; then
    actual="exists"
else
    actual="missing"
fi
assert_eq "test_script_exists: present and executable" "exists" "$actual"
assert_pass_if_clean "test_script_exists"

# ── test_shellcheck_clean ─────────────────────────────────────────────────────
_snapshot_fail
sc_rc=0
shellcheck "$SCRIPT" >/dev/null 2>&1 || sc_rc=$?
assert_eq "test_shellcheck_clean: shellcheck exits 0" "0" "$sc_rc"
assert_pass_if_clean "test_shellcheck_clean"

# ── test_help_outputs_usage ───────────────────────────────────────────────────
_snapshot_fail
help_out="$(bash "$SCRIPT" -h 2>&1)"
help_rc=$?
assert_eq "test_help_outputs_usage: exit 0" "0" "$help_rc"
assert_contains "test_help_outputs_usage: includes Usage:" "Usage:" "$help_out"
assert_pass_if_clean "test_help_outputs_usage"

# ── test_missing_branch_arg_exits_2 ───────────────────────────────────────────
_snapshot_fail
mb_rc=0
bash "$SCRIPT" >/dev/null 2>&1 || mb_rc=$?
assert_eq "test_missing_branch_arg_exits_2: exit 2" "2" "$mb_rc"
assert_pass_if_clean "test_missing_branch_arg_exits_2"

# ── test_missing_patterns_file_exits_2 ────────────────────────────────────────
_snapshot_fail
mf_rc=0
bash "$SCRIPT" --patterns-file /nonexistent/patterns.txt worktree-foo >/dev/null 2>&1 || mf_rc=$?
assert_eq "test_missing_patterns_file_exits_2: exit 2" "2" "$mf_rc"
assert_pass_if_clean "test_missing_patterns_file_exits_2"

# ── test_empty_patterns_file_exits_2 ──────────────────────────────────────────
_snapshot_fail
ep_tmp="$(mktemp -d "${TMPDIR:-/tmp}/match-session-empty.XXXXXX")"
_CLEANUP_DIRS+=("$ep_tmp")
cat > "$ep_tmp/patterns.txt" <<'EOF'
# comments only — no active patterns
EOF
ep_rc=0
bash "$SCRIPT" --patterns-file "$ep_tmp/patterns.txt" worktree-foo >/dev/null 2>&1 || ep_rc=$?
assert_eq "test_empty_patterns_file_exits_2: exit 2" "2" "$ep_rc"
assert_pass_if_clean "test_empty_patterns_file_exits_2"

# ── test_known_session_branches_match ─────────────────────────────────────────
# Every shape in the live patterns file must match.
_snapshot_fail
declare -a _MATCHES=(
    "session/foo"
    "session-bar"
    "session_baz"
    "worktree-test"
    "worktree-agent-x"
    "bug-batch/2026-05-28"
    "feat-z"
    "feat/q"
    "story-a"
    "story/b"
    "fix-c"
    "fix/d"
)
all_matched="yes"
for B in "${_MATCHES[@]}"; do
    rc=0
    bash "$SCRIPT" "$B" >/dev/null 2>&1 || rc=$?
    if [[ "$rc" -ne 0 ]]; then
        echo "  MISS: $B (got exit $rc)" >&2
        all_matched="no"
    fi
done
assert_eq "test_known_session_branches_match: every shape in patterns file matches" \
    "yes" "$all_matched"
assert_pass_if_clean "test_known_session_branches_match"

# ── test_non_session_branches_reject ──────────────────────────────────────────
_snapshot_fail
declare -a _REJECTS=(
    "main"
    "master"
    "trunk"
    "develop"
    "random-branch"
    "release/v2"
    "hotfix-urgent"
)
all_rejected="yes"
for B in "${_REJECTS[@]}"; do
    rc=0
    bash "$SCRIPT" "$B" >/dev/null 2>&1 || rc=$?
    if [[ "$rc" -ne 1 ]]; then
        echo "  FALSE-MATCH: $B (got exit $rc, expected 1)" >&2
        all_rejected="no"
    fi
done
assert_eq "test_non_session_branches_reject: non-session refs exit 1" \
    "yes" "$all_rejected"
assert_pass_if_clean "test_non_session_branches_reject"

# ── test_custom_patterns_file ─────────────────────────────────────────────────
_snapshot_fail
cp_tmp="$(mktemp -d "${TMPDIR:-/tmp}/match-session-custom.XXXXXX")"
_CLEANUP_DIRS+=("$cp_tmp")
cat > "$cp_tmp/patterns.txt" <<'EOF'
# custom host conventions
release/**
hotfix-**
EOF
match_rc=0
bash "$SCRIPT" --patterns-file "$cp_tmp/patterns.txt" "release/v2" >/dev/null 2>&1 || match_rc=$?
assert_eq "test_custom_patterns_file: release/v2 matches custom pattern" "0" "$match_rc"
reject_rc=0
bash "$SCRIPT" --patterns-file "$cp_tmp/patterns.txt" "feat-foo" >/dev/null 2>&1 || reject_rc=$?
assert_eq "test_custom_patterns_file: feat-foo rejected when not in custom file" "1" "$reject_rc"
assert_pass_if_clean "test_custom_patterns_file"

print_summary
