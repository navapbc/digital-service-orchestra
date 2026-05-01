#!/usr/bin/env bash
# tests/scripts/test-provision-ruleset.sh
# RED-phase behavioral tests for plugins/dso/scripts/onboarding/provision-ruleset.sh
#
# All tests that depend on provision-ruleset.sh will FAIL (RED) until
# plugins/dso/scripts/onboarding/provision-ruleset.sh is created.
# test_script_exists is the hard RED gate — it fails when the script is missing,
# establishing RED state before implementation.
#
# Tests covered:
#   1. test_script_exists                        — script missing → RED (hard gate)
#   2. test_required_checks_file_exists          — .github/required-checks.txt exists with entries
#   3. test_preflight_exits_nonzero_on_missing_gh — exits non-zero when gh not in PATH
#   4. test_dry_run_outputs_payload              — DSO_DRY_RUN=1 outputs JSON with required_status_checks
#   5. test_payload_includes_leg_names_from_required_checks — payload contains leg names from required-checks.txt
#
# Usage: bash tests/scripts/test-provision-ruleset.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PROVISION_SCRIPT="$REPO_ROOT/plugins/dso/scripts/onboarding/provision-ruleset.sh"
REQUIRED_CHECKS="$REPO_ROOT/.github/required-checks.txt"

# shellcheck source=../lib/assert.sh
source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-provision-ruleset.sh ==="

# ── test_script_exists ────────────────────────────────────────────────────────
# The provision-ruleset.sh script must exist and be executable.
# This is the RED gate — fails until the script is created.
_snapshot_fail
if [[ -f "$PROVISION_SCRIPT" && -x "$PROVISION_SCRIPT" ]]; then
    actual_exists="exists"
else
    actual_exists="missing"
fi
assert_eq "test_script_exists: file present and executable" "exists" "$actual_exists"
assert_pass_if_clean "test_script_exists"

# ── test_required_checks_file_exists ─────────────────────────────────────────
# .github/required-checks.txt must exist with at least one non-comment line.
# This test may PASS if the sibling task (705d-66d4) has already created the file.
_snapshot_fail
if [[ -f "$REQUIRED_CHECKS" ]]; then
    # Count non-comment, non-blank lines
    non_comment_lines=$(grep -c '^[^#]' "$REQUIRED_CHECKS" 2>/dev/null || echo "0")
    if [[ "$non_comment_lines" -ge 1 ]]; then
        actual_checks="has_entries"
    else
        actual_checks="empty_or_comments_only"
    fi
else
    actual_checks="missing"
fi
assert_eq "test_required_checks_file_exists: file exists with entries" "has_entries" "$actual_checks"
assert_pass_if_clean "test_required_checks_file_exists"

# ── test_preflight_exits_nonzero_on_missing_gh ───────────────────────────────
# When gh is not in PATH, provision-ruleset.sh must exit non-zero (pre-flight check)
# AND emit output indicating gh was not found.
# Verifying both the exit code AND the diagnostic message ensures the test passes
# for the right reason (gh-missing path), not due to an unrelated early failure
# (e.g., missing git or jq) that happens to also exit non-zero.
# This test fails RED until the script exists.
#
# PATH construction: we cannot use a fixed PATH like /usr/bin:/bin because on
# Ubuntu CI, gh is installed at /usr/bin/gh — the same directory as git. Instead:
# 1. Detect the directory containing gh (if present)
# 2. Create a temp dir with git (and other needed tools) symlinked but NOT gh
# 3. Build a PATH that includes the temp dir instead of gh's directory
_snapshot_fail
preflight_exit=0
preflight_output=""
# Use env -i to create a fully isolated environment where gh cannot be found.
# Path-filtering approaches (grep -v "^/usr/bin$") fail on Ubuntu where /bin is
# a symlink to /usr/bin — excluding /usr/bin still leaves gh accessible via /bin.
# env -i strips ALL environment variables; we provide only what provision-ruleset.sh
# needs before the gh pre-flight check (just git for REPO_ROOT detection).
_no_gh_tmpdir=$(mktemp -d)
# Symlink (never copy) the tools provision-ruleset.sh needs before the gh check:
# dirname (line 19 SCRIPT_DIR) and git (line 28 REPO_ROOT). cat is needed for the
# heredoc output if gh is missing. Symlinks preserve shared library paths on macOS.
for _tool in dirname git cat; do
    _tool_bin=$(command -v "$_tool" 2>/dev/null || true)
    [ -n "$_tool_bin" ] && ln -sf "$_tool_bin" "$_no_gh_tmpdir/$_tool" 2>/dev/null || true
done
# Use the absolute path to bash (env PATH won't help find bash itself)
_bash_bin=$(command -v bash 2>/dev/null || echo "/bin/bash")
preflight_output=$(env PATH="$_no_gh_tmpdir" \
    "$_bash_bin" "$PROVISION_SCRIPT" 2>/dev/null) || preflight_exit=$?
rm -rf "$_no_gh_tmpdir"
# We expect a non-zero exit when gh is missing
if [[ $preflight_exit -ne 0 ]]; then
    actual_preflight="nonzero"
else
    actual_preflight="zero"
fi
# We also expect the output to contain the gh-specific diagnostic message,
# confirming the exit is due to gh missing — not some other earlier failure.
if echo "$preflight_output" | grep -q "gh.*CLI.*not found\|gh CLI was not found"; then
    actual_preflight_reason="gh_missing_message"
else
    actual_preflight_reason="no_gh_missing_message"
fi
assert_eq "test_preflight_exits_nonzero_on_missing_gh: exits non-zero" "nonzero" "$actual_preflight"
assert_eq "test_preflight_exits_nonzero_on_missing_gh: output indicates gh missing" "gh_missing_message" "$actual_preflight_reason"
assert_pass_if_clean "test_preflight_exits_nonzero_on_missing_gh"

# ── test_dry_run_outputs_payload ──────────────────────────────────────────────
# When DSO_DRY_RUN=1, the script must output a JSON payload containing
# "required_status_checks" to stdout and exit 0.
_snapshot_fail
dry_run_exit=0
dry_run_output=""
dry_run_output=$(DSO_DRY_RUN=1 bash "$PROVISION_SCRIPT" 2>/dev/null) || dry_run_exit=$?
# Check for the expected JSON key in the output
if echo "$dry_run_output" | grep -q '"required_status_checks"'; then
    actual_payload="has_key"
else
    actual_payload="missing_key"
fi
assert_eq "test_dry_run_outputs_payload: exit 0" "0" "$dry_run_exit"
assert_eq "test_dry_run_outputs_payload: output contains required_status_checks" "has_key" "$actual_payload"
assert_pass_if_clean "test_dry_run_outputs_payload"

# ── test_payload_includes_leg_names_from_required_checks ─────────────────────
# When DSO_DRY_RUN=1, the payload must include all leg names from
# .github/required-checks.txt (linux-bash4, macos-bash3, alpine-busybox).
_snapshot_fail
leg_output=""
leg_output=$(DSO_DRY_RUN=1 bash "$PROVISION_SCRIPT" 2>/dev/null) || true

leg_linux="missing"
leg_macos="missing"
leg_alpine="missing"
if echo "$leg_output" | grep -q 'linux-bash4'; then
    leg_linux="present"
fi
if echo "$leg_output" | grep -q 'macos-bash3'; then
    leg_macos="present"
fi
if echo "$leg_output" | grep -q 'alpine-busybox'; then
    leg_alpine="present"
fi

assert_eq "test_payload_includes_leg_names: linux-bash4 in payload" "present" "$leg_linux"
assert_eq "test_payload_includes_leg_names: macos-bash3 in payload" "present" "$leg_macos"
assert_eq "test_payload_includes_leg_names: alpine-busybox in payload" "present" "$leg_alpine"
assert_pass_if_clean "test_payload_includes_leg_names_from_required_checks"

# ── test_bypass_actor_policy_pull_request_only ────────────────────────────────
# When --bypass-actor-policy=pull_request_only is set, the dry-run payload
# must include "bypass_mode": "pull_request_only" in bypass_actors[].
_snapshot_fail
bap_output=""
bap_exit=0
bap_output=$(DSO_DRY_RUN=1 bash "$PROVISION_SCRIPT" --bypass-actor-policy=pull_request_only 2>/dev/null) || bap_exit=$?
if echo "$bap_output" | grep -q '"bypass_mode": "pull_request_only"'; then
    actual_bap="present"
else
    actual_bap="missing"
fi
assert_eq "test_bypass_actor_policy_pull_request_only: exit 0" "0" "$bap_exit"
assert_eq "test_bypass_actor_policy_pull_request_only: payload contains pull_request_only bypass_mode" "present" "$actual_bap"
assert_pass_if_clean "test_bypass_actor_policy_pull_request_only"

# ── test_require_conversation_resolution_true ─────────────────────────────────
# When --require-conversation-resolution=true is set, the dry-run payload
# must include "required_review_thread_resolution": true in pull_request.parameters.
_snapshot_fail
rcr_output=""
rcr_exit=0
rcr_output=$(DSO_DRY_RUN=1 bash "$PROVISION_SCRIPT" --require-conversation-resolution=true 2>/dev/null) || rcr_exit=$?
if echo "$rcr_output" | grep -q '"required_review_thread_resolution": true'; then
    actual_rcr="present"
else
    actual_rcr="missing"
fi
assert_eq "test_require_conversation_resolution_true: exit 0" "0" "$rcr_exit"
assert_eq "test_require_conversation_resolution_true: payload contains required_review_thread_resolution true" "present" "$actual_rcr"
assert_pass_if_clean "test_require_conversation_resolution_true"

# ── test_request_copilot_review_true ──────────────────────────────────────────
# When --request-copilot-review=true is set, the dry-run output must contain
# a 'request_copilot_review' annotation/note (the implementation contract
# allows a placeholder note since GitHub Rulesets may not directly support this).
_snapshot_fail
rcp_output=""
rcp_exit=0
rcp_output=$(DSO_DRY_RUN=1 bash "$PROVISION_SCRIPT" --request-copilot-review=true 2>/dev/null) || rcp_exit=$?
if echo "$rcp_output" | grep -q 'request_copilot_review'; then
    actual_rcp="present"
else
    actual_rcp="missing"
fi
assert_eq "test_request_copilot_review_true: exit 0" "0" "$rcp_exit"
assert_eq "test_request_copilot_review_true: dry-run output references request_copilot_review" "present" "$actual_rcp"
assert_pass_if_clean "test_request_copilot_review_true"

# ── test_dismiss_stale_approvals_on_push_true ────────────────────────────────
# When --dismiss-stale-approvals-on-push=true is set, the dry-run payload
# must include "dismiss_stale_reviews_on_push": true in pull_request.parameters.
_snapshot_fail
dsa_output=""
dsa_exit=0
dsa_output=$(DSO_DRY_RUN=1 bash "$PROVISION_SCRIPT" --dismiss-stale-approvals-on-push=true 2>/dev/null) || dsa_exit=$?
if echo "$dsa_output" | grep -q '"dismiss_stale_reviews_on_push": true'; then
    actual_dsa="present"
else
    actual_dsa="missing"
fi
assert_eq "test_dismiss_stale_approvals_on_push_true: exit 0" "0" "$dsa_exit"
assert_eq "test_dismiss_stale_approvals_on_push_true: payload contains dismiss_stale_reviews_on_push true" "present" "$actual_dsa"
assert_pass_if_clean "test_dismiss_stale_approvals_on_push_true"

# ── test_required_approvals_value ─────────────────────────────────────────────
# When --required-approvals=2 is set, the dry-run payload must include
# "required_approving_review_count": 2 in pull_request.parameters.
_snapshot_fail
ra_output=""
ra_exit=0
ra_output=$(DSO_DRY_RUN=1 bash "$PROVISION_SCRIPT" --required-approvals=2 2>/dev/null) || ra_exit=$?
if echo "$ra_output" | grep -q '"required_approving_review_count": 2'; then
    actual_ra="present"
else
    actual_ra="missing"
fi
assert_eq "test_required_approvals_value: exit 0" "0" "$ra_exit"
assert_eq "test_required_approvals_value: payload contains required_approving_review_count 2" "present" "$actual_ra"
assert_pass_if_clean "test_required_approvals_value"

# ── test_bypass_actor_policy_requires_admin_token ─────────────────────────────
# When --bypass-actor-policy is non-default (e.g. always or pull_request_only)
# AND admin scope is unavailable (mocked here by setting GH_TOKEN to an obviously
# invalid value so `gh auth status` fails the admin-scope check), the script
# must exit non-zero (1) with a message referencing the admin token requirement.
#
# This is a non-dry-run path: the admin-scope guard must fire BEFORE any
# network call. We invoke without DSO_DRY_RUN to exercise the real preflight,
# but expect the script to exit before making API calls because the token is
# invalid.
_snapshot_fail
bap_admin_exit=0
bap_admin_output=""
bap_admin_output=$(GH_TOKEN="invalid-token-for-test" \
    bash "$PROVISION_SCRIPT" --bypass-actor-policy=always --non-interactive --repo=fake-owner/fake-repo 2>&1) \
    || bap_admin_exit=$?
if [[ $bap_admin_exit -eq 1 ]]; then
    actual_bap_admin_exit="exit_1"
else
    actual_bap_admin_exit="exit_${bap_admin_exit}"
fi
if echo "$bap_admin_output" | grep -qiE 'admin.*token|admin.*scope|token.*admin'; then
    actual_bap_admin_msg="references_admin_token"
else
    actual_bap_admin_msg="no_admin_reference"
fi
assert_eq "test_bypass_actor_policy_requires_admin_token: exits 1 on insufficient privs" "exit_1" "$actual_bap_admin_exit"
assert_eq "test_bypass_actor_policy_requires_admin_token: error message references admin token" "references_admin_token" "$actual_bap_admin_msg"
assert_pass_if_clean "test_bypass_actor_policy_requires_admin_token"

# ── Summary ───────────────────────────────────────────────────────────────────
print_summary
