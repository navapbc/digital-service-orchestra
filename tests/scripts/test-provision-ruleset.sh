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
_snapshot_fail
preflight_exit=0
preflight_output=""
preflight_output=$(env PATH=/usr/bin:/bin bash "$PROVISION_SCRIPT" 2>/dev/null) || preflight_exit=$?
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

# ── Summary ───────────────────────────────────────────────────────────────────
print_summary
