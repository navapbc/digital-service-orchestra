#!/usr/bin/env bash
# tests/scripts/test-check-ruleset-preflight.sh

#
# Tests cover 3 GitHub Ruleset validation conditions:
#   1. A Ruleset exists with session-* branch pattern
#   2. Sprint Story Review (or check_name from dso-config.conf) is in required_status_checks
#   3. No required_linear_history rule (would block sprint merge strategy)
#

# is implemented.
#
# Usage: bash tests/scripts/test-check-ruleset-preflight.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

# Do not use -e; we intentionally test non-zero exits from the script under test.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRIPT_UNDER_TEST="$REPO_ROOT/plugins/dso/scripts/sprint/check-ruleset-preflight.sh"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-check-ruleset-preflight.sh ==="

# ── Setup: shared temp dir, cleaned on exit ───────────────────────────────────
TMPDIR_BASE="$(mktemp -d "${TMPDIR:-/tmp}/test-ruleset-preflight.XXXXXX")"
trap 'rm -rf "$TMPDIR_BASE"' EXIT

# Helper: build a stub bin directory with a `gh` stub that returns the given
# JSON from `gh api .../rulesets`. Accepts optional extra JSON to return.
# Usage: _make_stub_bin <stub_name> <gh_api_json>
_make_stub_bin() {
    local name="$1" api_json="$2"
    local stub_bin="$TMPDIR_BASE/stub-bin-$name"
    mkdir -p "$stub_bin"

    cat > "$stub_bin/gh" <<STUB
#!/usr/bin/env bash
# Stub gh that returns fixed JSON for ruleset API calls
case "\$*" in
    api*rulesets*)
        printf '%s\n' '$api_json'
        exit 0
        ;;
    *)
        echo "STUB: unhandled gh command: \$*" >&2
        exit 1
        ;;
esac
STUB
    chmod +x "$stub_bin/gh"
    echo "$stub_bin"
}

# Helper: run the script under test with the given stub bin in PATH.
# Returns combined stdout+stderr. Caller captures exit code via $?.
_run_script() {
    local stub_bin="$1"; shift
    # remaining args passed to script
    local extra_env="${1:-}"
    local config_file="${2:-}"

    local env_args=()
    if [[ -n "$config_file" ]]; then
        env_args+=(DSO_CONFIG_FILE="$config_file")
    fi

    env PATH="$stub_bin:$PATH" "${env_args[@]+"${env_args[@]}"}" \
        bash "$SCRIPT_UNDER_TEST" 2>&1
}

# ── test_script_exists ────────────────────────────────────────────────────────

echo ""
echo "--- test_script_exists ---"
_snapshot_fail
if [[ -f "$SCRIPT_UNDER_TEST" ]]; then
    (( ++PASS ))
    echo "test_script_exists ... PASS"
else
    (( ++FAIL ))
    printf "FAIL: test_script_exists\n  expected: %s to exist\n  actual:   file not found\n" "$SCRIPT_UNDER_TEST" >&2
fi

# ── test_no_ruleset_exits_with_message ────────────────────────────────────────
# script doesn't exist, so this will fail with "not found" rather than

echo ""
echo "--- test_no_ruleset_exits_with_message ---"
_snapshot_fail

EMPTY_RULESETS_JSON='{"rulesets":[]}'
stub_bin_empty="$(_make_stub_bin "empty" "$EMPTY_RULESETS_JSON")"

no_ruleset_output=""
no_ruleset_exit=0
no_ruleset_output="$(env PATH="$stub_bin_empty:$PATH" bash "$SCRIPT_UNDER_TEST" 2>&1)" || no_ruleset_exit=$?

assert_ne "test_no_ruleset_exits_with_message: exits non-zero on empty rulesets" \
    "0" "$no_ruleset_exit"
assert_contains "test_no_ruleset_exits_with_message: output mentions session-* ruleset" \
    "session-*" "$no_ruleset_output"
assert_pass_if_clean "test_no_ruleset_exits_with_message"

# ── test_check_name_missing_exits_with_message ────────────────────────────────
# script doesn't exist yet.
echo ""
echo "--- test_check_name_missing_exits_with_message ---"
_snapshot_fail

# Ruleset has session-* pattern but NO Sprint Story Review in required_status_checks
MISSING_CHECK_JSON='{"rulesets":[{"name":"session-branch-rules","conditions":{"ref_name":{"include":["refs/heads/session-*"]}},"rules":[{"type":"required_status_checks","parameters":{"required_status_checks":[]}}]}]}'
stub_bin_missing_check="$(_make_stub_bin "missing_check" "$MISSING_CHECK_JSON")"

missing_check_output=""
missing_check_exit=0
missing_check_output="$(env PATH="$stub_bin_missing_check:$PATH" bash "$SCRIPT_UNDER_TEST" 2>&1)" || missing_check_exit=$?

assert_ne "test_check_name_missing_exits_with_message: exits non-zero when check missing" \
    "0" "$missing_check_exit"
assert_contains "test_check_name_missing_exits_with_message: output mentions Sprint Story Review" \
    "Sprint Story Review" "$missing_check_output"
assert_pass_if_clean "test_check_name_missing_exits_with_message"

# ── test_fully_configured_exits_zero ─────────────────────────────────────────
# script doesn't exist yet.
echo ""
echo "--- test_fully_configured_exits_zero ---"
_snapshot_fail

# Ruleset has session-* pattern, Sprint Story Review in status checks, and no linear_history rule
GOOD_RULESET_JSON='{"rulesets":[{"name":"session-branch-rules","conditions":{"ref_name":{"include":["refs/heads/session-*"]}},"rules":[{"type":"required_status_checks","parameters":{"required_status_checks":[{"context":"Sprint Story Review"}]}}]}]}'
stub_bin_good="$(_make_stub_bin "good" "$GOOD_RULESET_JSON")"

good_output=""
good_exit=0
good_output="$(env PATH="$stub_bin_good:$PATH" bash "$SCRIPT_UNDER_TEST" 2>&1)" || good_exit=$?

assert_eq "test_fully_configured_exits_zero: exits 0 when fully configured" \
    "0" "$good_exit"
assert_contains "test_fully_configured_exits_zero: output contains success message" \
    "success" "$good_output"
assert_pass_if_clean "test_fully_configured_exits_zero"

# ── test_reads_check_name_from_config ────────────────────────────────────────
# script doesn't exist yet.
echo ""
echo "--- test_reads_check_name_from_config ---"
_snapshot_fail

# Write a dso-config.conf with a custom check_name
custom_config="$TMPDIR_BASE/dso-config.conf"
printf 'dso.review.check_name=My_Custom_Check\n' > "$custom_config"

# Ruleset has session-* pattern; status check uses the custom name from config
CUSTOM_CHECK_JSON='{"rulesets":[{"name":"session-branch-rules","conditions":{"ref_name":{"include":["refs/heads/session-*"]}},"rules":[{"type":"required_status_checks","parameters":{"required_status_checks":[{"context":"My_Custom_Check"}]}}]}]}'
stub_bin_custom="$(_make_stub_bin "custom" "$CUSTOM_CHECK_JSON")"

custom_output=""
custom_exit=0
custom_output="$(env PATH="$stub_bin_custom:$PATH" DSO_CONFIG_FILE="$custom_config" bash "$SCRIPT_UNDER_TEST" 2>&1)" || custom_exit=$?

assert_eq "test_reads_check_name_from_config: exits 0 with custom check_name from config" \
    "0" "$custom_exit"
assert_contains "test_reads_check_name_from_config: output contains success message" \
    "success" "$custom_output"
assert_pass_if_clean "test_reads_check_name_from_config"

# ── Summary ──────────────────────────────────────────────────────────────────
print_summary
