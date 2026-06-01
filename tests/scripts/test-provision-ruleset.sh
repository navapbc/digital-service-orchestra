#!/usr/bin/env bash
# tests/scripts/test-provision-ruleset.sh
# RED-phase behavioral tests for plugins/dso/scripts/onboarding/provision-ruleset.sh
#

# plugins/dso/scripts/onboarding/provision-ruleset.sh is created.

# establishing failure state before implementation.
#
# Tests covered:
#   1. test_script_exists                        — script missing (hard gate)
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
# This is the hard prerequisite — fails until the script is created.
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

# ── test_payload_valid_json_with_special_chars ────────────────────────────────
# Check names containing JSON-special characters (quotes, backslashes) must be
# properly escaped so the generated payload is valid JSON (2bf0-1eb5).
_snapshot_fail
special_checks_dir=$(mktemp -d)
special_checks_file="$special_checks_dir/required-checks.txt"
printf '%s\n' 'check/with-slash' 'check-with-hyphen' 'check.with.dot' > "$special_checks_file"
special_output=""
special_output=$(DSO_DRY_RUN=1 bash "$PROVISION_SCRIPT" --checks-file "$special_checks_file" 2>/dev/null) || true
rm -rf "$special_checks_dir"

special_valid="invalid"
# Extract the first valid JSON object from the DSO_DRY_RUN output
json_payload=$(echo "$special_output" | python3 -c "
import sys, json
text = sys.stdin.read()
idx = text.find('{')
if idx >= 0:
    try:
        obj, _ = json.JSONDecoder().raw_decode(text, idx)
        print('ok')
    except Exception:
        pass
" 2>/dev/null)
if [[ "$json_payload" == "ok" ]]; then
    special_valid="valid"
fi
assert_eq "test_payload_valid_json_with_special_chars: payload is valid JSON" "valid" "$special_valid"
assert_pass_if_clean "test_payload_valid_json_with_special_chars"

# ── test_require_conversation_resolution_true ────────────────────────────────
# When --require-conversation-resolution=true, payload must set
# required_review_thread_resolution: true.
_snapshot_fail
conv_output=""
conv_output=$(DSO_DRY_RUN=1 bash "$PROVISION_SCRIPT" --require-conversation-resolution=true 2>/dev/null) || true
if echo "$conv_output" | grep -q '"required_review_thread_resolution": true'; then
    actual_conv="true"
else
    actual_conv="not_true"
fi
assert_eq "test_require_conversation_resolution_true: payload field" "true" "$actual_conv"
assert_pass_if_clean "test_require_conversation_resolution_true"

# ── test_request_copilot_review_true ─────────────────────────────────────────
# When --request-copilot-review=true, dry-run output must include the documented
# placeholder annotation (since GitHub does not expose this via Rulesets today).
_snapshot_fail
copilot_output=""
copilot_output=$(DSO_DRY_RUN=1 bash "$PROVISION_SCRIPT" --request-copilot-review=true 2>/dev/null) || true
if echo "$copilot_output" | grep -q 'request_copilot_review=true'; then
    actual_copilot="annotated"
else
    actual_copilot="missing"
fi
assert_eq "test_request_copilot_review_true: annotation present" "annotated" "$actual_copilot"
assert_pass_if_clean "test_request_copilot_review_true"

# ── test_dismiss_stale_approvals_on_push_true ────────────────────────────────
# When --dismiss-stale-approvals-on-push=true, payload must set
# dismiss_stale_reviews_on_push: true.
_snapshot_fail
dismiss_output=""
dismiss_output=$(DSO_DRY_RUN=1 bash "$PROVISION_SCRIPT" --dismiss-stale-approvals-on-push=true 2>/dev/null) || true
if echo "$dismiss_output" | grep -q '"dismiss_stale_reviews_on_push": true'; then
    actual_dismiss="true"
else
    actual_dismiss="not_true"
fi
assert_eq "test_dismiss_stale_approvals_on_push_true: payload field" "true" "$actual_dismiss"
assert_pass_if_clean "test_dismiss_stale_approvals_on_push_true"

# ── test_required_approvals_value ────────────────────────────────────────────
# When --required-approvals=3, payload must set
# required_approving_review_count: 3.
_snapshot_fail
approvals_output=""
approvals_output=$(DSO_DRY_RUN=1 bash "$PROVISION_SCRIPT" --required-approvals=3 2>/dev/null) || true
if echo "$approvals_output" | grep -q '"required_approving_review_count": 3'; then
    actual_approvals="3"
else
    actual_approvals="not_3"
fi
assert_eq "test_required_approvals_value: payload field" "3" "$actual_approvals"
assert_pass_if_clean "test_required_approvals_value"

# ── test_bypass_actor_policy_requires_admin_token ────────────────────────────
# When --bypass-actor-policy=pull_request is passed AND gh auth status
# reports no admin scope, the script must exit non-zero with a clear admin-token
# error message. We use a stub gh that reports auth without admin scope.
_snapshot_fail
_noadmin_dir=$(mktemp -d)
cat > "$_noadmin_dir/gh" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  "auth status -t"|"auth status")
    # Auth succeeds but no admin scope listed.
    echo "Logged in to github.com as user (oauth_token)" >&2
    echo "Token scopes: 'repo', 'workflow'" >&2
    exit 0
    ;;
  *) exit 0 ;;
esac
STUB
chmod +x "$_noadmin_dir/gh"
admin_output=""
admin_exit=0
admin_output=$(PATH="$_noadmin_dir:$PATH" DSO_DRY_RUN=0 bash "$PROVISION_SCRIPT" --bypass-actor-policy=pull_request 2>&1) || admin_exit=$?
rm -rf "$_noadmin_dir"
if [[ $admin_exit -ne 0 ]]; then
    actual_admin_exit="nonzero"
else
    actual_admin_exit="zero"
fi
if echo "$admin_output" | grep -qE 'admin token|admin:org'; then
    actual_admin_msg="present"
else
    actual_admin_msg="missing"
fi
assert_eq "test_bypass_actor_policy_requires_admin_token: exits non-zero" "nonzero" "$actual_admin_exit"
assert_eq "test_bypass_actor_policy_requires_admin_token: error message" "present" "$actual_admin_msg"
assert_pass_if_clean "test_bypass_actor_policy_requires_admin_token"

# ── test_dry_run_includes_session_branch_ruleset (F1) ────────────────────────
# The dry-run output must include the session-branch ruleset payload with
# review-sub-pr as required check and the correct branch patterns.
_snapshot_fail
sub_pr_output=""
sub_pr_output=$(DSO_DRY_RUN=1 bash "$PROVISION_SCRIPT" 2>/dev/null) || true

sub_pr_has_name="missing"
sub_pr_has_review_check="missing"
sub_pr_has_include_staged="missing"
sub_pr_has_rsc_rule="missing"
if echo "$sub_pr_output" | grep -q 'DSO Sub-PR Review Enforcement'; then
    sub_pr_has_name="present"
fi
# Structural extraction of the sub-PR ruleset object from dry-run output.
# CANONICAL = live (W1/CS-2): include=staged-*, rule type required_status_checks
# with context review-sub-pr + do_not_enforce_on_create:true (NOT a `workflows`
# rule binding a nonexistent review-sub-pr.yml).
sub_pr_extraction=$(echo "$sub_pr_output" | python3 -c "
import sys, json
text = sys.stdin.read()
lines = text.split('\n')
for start in [i for i, l in enumerate(lines) if l.strip() == '{']:
    depth = 0
    for j in range(start, len(lines)):
        for ch in lines[j]:
            if ch == '{': depth += 1
            elif ch == '}':
                depth -= 1
                if depth == 0:
                    try:
                        obj = json.loads('\n'.join(lines[start:j+1]))
                        if isinstance(obj, dict) and obj.get('name') == 'DSO Sub-PR Review Enforcement':
                            inc = obj.get('conditions', {}).get('ref_name', {}).get('include', [])
                            has_rsc = '0'; has_check = '0'
                            for r in obj.get('rules', []):
                                if r.get('type') == 'required_status_checks':
                                    p = r.get('parameters', {})
                                    ctx = [c.get('context') for c in p.get('required_status_checks', [])]
                                    if 'review-sub-pr' in ctx and p.get('do_not_enforce_on_create') is True:
                                        has_rsc = '1'
                                    if 'review-sub-pr' in ctx:
                                        has_check = '1'
                            print('INCLUDE_HAS_STAGED=' + ('1' if 'refs/heads/staged-*' in inc else '0'))
                            print('HAS_RSC_RULE=' + has_rsc)
                            print('HAS_REVIEW_CHECK=' + has_check)
                            sys.exit(0)
                    except json.JSONDecodeError:
                        pass
                    break
        if depth == 0 and j > start: break
print('INCLUDE_HAS_STAGED=0')
print('HAS_RSC_RULE=0')
print('HAS_REVIEW_CHECK=0')
sys.exit(0)
" 2>/dev/null || echo "INCLUDE_HAS_STAGED=0
HAS_RSC_RULE=0
HAS_REVIEW_CHECK=0")
if echo "$sub_pr_extraction" | grep -q '^INCLUDE_HAS_STAGED=1$'; then
    sub_pr_has_include_staged="present"
fi
if echo "$sub_pr_extraction" | grep -q '^HAS_RSC_RULE=1$'; then
    sub_pr_has_rsc_rule="present"
fi
if echo "$sub_pr_extraction" | grep -q '^HAS_REVIEW_CHECK=1$'; then
    sub_pr_has_review_check="present"
fi

assert_eq "test_dry_run_includes_session_branch_ruleset: ruleset name present" "present" "$sub_pr_has_name"
assert_eq "test_dry_run_includes_session_branch_ruleset: review-sub-pr required-status-check context present" "present" "$sub_pr_has_review_check"
# Two-tier promotion model: include=["refs/heads/staged-*"], rule type
# required_status_checks{review-sub-pr} with do_not_enforce_on_create:true (the
# create-exemption is what unblocks staged-* ref creation while gating PR merges).
assert_eq "test_dry_run_includes_session_branch_ruleset: include staged-* present" "present" "$sub_pr_has_include_staged"
assert_eq "test_dry_run_includes_session_branch_ruleset: rule type is required_status_checks{do_not_enforce_on_create}" "present" "$sub_pr_has_rsc_rule"
assert_pass_if_clean "test_dry_run_includes_session_branch_ruleset"

# test_session_branch_patterns_match_workflow_triggers removed (PR-2):
# Superseded by tests/scripts/test-branch-pattern-alignment.sh which validates
# alignment between the source-of-truth file
# (plugins/dso/config/sub-pr-branch-patterns.txt) and both consumers
# (provision-ruleset.sh, llm-review-dispatch-or-skip.sh). The original test
# hardcoded a 5-pattern subset against literal grep — now obsolete since
# patterns are read dynamically.

# ── Summary ───────────────────────────────────────────────────────────────────
print_summary
