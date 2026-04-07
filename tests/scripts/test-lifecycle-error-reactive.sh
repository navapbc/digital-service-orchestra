#!/usr/bin/env bash
# tests/scripts/test-lifecycle-error-reactive.sh
# RED tests for _check_rate_limit_error() in agent-batch-lifecycle.sh.
#
# _check_rate_limit_error() does NOT exist yet — all tests must FAIL (RED phase).
#
# Behavioral contract under test:
#   _check_rate_limit_error <text>
#     - Matches "rate.limit", "usage.limit", or "quota.exceeded" (case-insensitive)
#       in <text> and creates the sentinel file at $RATE_LIMIT_SENTINEL path.
#     - Returns 0 when a match is found (sentinel written), non-zero when no match.
#     - "HTTP 429" alone (without quota keywords) does NOT trigger the sentinel.
#     - When called with no matching input, leaves sentinel absent.
#
#   cmd_pre_check (integration):
#     - When RATE_LIMIT_SENTINEL file exists and is ≤5 minutes old,
#       MAX_AGENTS output is forced to 1 regardless of check-usage.sh verdict.
#     - When RATE_LIMIT_SENTINEL is older than 5 minutes, it is ignored
#       (treated as absent) and MAX_AGENTS falls back to the normal check-usage.sh result.
#
# Sentinel injection:
#   RATE_LIMIT_SENTINEL env var overrides the sentinel path, enabling test isolation
#   without touching production /tmp paths.
#
# Test approach:
#   Each test sources agent-batch-lifecycle.sh, calls _check_rate_limit_error()
#   or runs cmd_pre_check via the script, then asserts on sentinel presence/absence
#   and function return code or stdout.
#
# Usage: bash tests/scripts/test-lifecycle-error-reactive.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail (RED: expect exit 1)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR" && git rev-parse --show-toplevel)"
LIFECYCLE="$REPO_ROOT/plugins/dso/scripts/agent-batch-lifecycle.sh"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-lifecycle-error-reactive.sh ==="

# ── Cleanup registry ──────────────────────────────────────────────────────────
_TEST_TMPDIRS=()
_cleanup_tmpdirs() {
    for d in "${_TEST_TMPDIRS[@]:-}"; do
        rm -rf "$d"
    done
}
trap '_cleanup_tmpdirs' EXIT

# ── Helper: make an isolated temp dir ────────────────────────────────────────
_make_tmp() {
    local d
    d="$(mktemp -d)"
    _TEST_TMPDIRS+=("$d")
    echo "$d"
}

# ── Helper: source lifecycle with RATE_LIMIT_SENTINEL injected ───────────────
# Runs a no-op subcommand (cleanup-stale-containers with absent infrastructure
# config) so the dispatch block exits cleanly, loading all function definitions
# into the current shell.
_source_lifecycle() {
    local sentinel="$1"
    WORKFLOW_CONFIG=/dev/null \
    RATE_LIMIT_SENTINEL="$sentinel" \
        source "$LIFECYCLE" cleanup-stale-containers 2>/dev/null
}

# ── Helper: mock check-usage.sh ──────────────────────────────────────────────
_make_mock_usage() {
    local exit_code="${1:-0}"
    local d
    d="$(_make_tmp)"
    cat > "$d/check-usage.sh" <<MOCKEOF
#!/usr/bin/env bash
exit $exit_code
MOCKEOF
    chmod +x "$d/check-usage.sh"
    echo "$d"
}

# ═════════════════════════════════════════════════════════════════════════════
# test_rate_limit_detected
# Input containing "rate.limit" → sentinel file MUST be created, return 0.
# ═════════════════════════════════════════════════════════════════════════════
_snapshot_fail
_tmp=$(_make_tmp)
_sentinel="$_tmp/rate-limit.sentinel"
_source_lifecycle "$_sentinel"
_rc=0
_check_rate_limit_error "Error: Anthropic rate.limit exceeded for this session" 2>/dev/null || _rc=$?
assert_eq "test_rate_limit_detected: return code 0 on match" "0" "$_rc"
assert_eq "test_rate_limit_detected: sentinel created" "true" "$([ -f "$_sentinel" ] && echo true || echo false)"
assert_pass_if_clean "test_rate_limit_detected"

# ═════════════════════════════════════════════════════════════════════════════
# test_usage_limit_detected
# Input containing "usage.limit" → sentinel file MUST be created, return 0.
# ═════════════════════════════════════════════════════════════════════════════
_snapshot_fail
_tmp=$(_make_tmp)
_sentinel="$_tmp/rate-limit.sentinel"
_source_lifecycle "$_sentinel"
_rc=0
_check_rate_limit_error "Claude usage.limit reached — please try again later" 2>/dev/null || _rc=$?
assert_eq "test_usage_limit_detected: return code 0 on match" "0" "$_rc"
assert_eq "test_usage_limit_detected: sentinel created" "true" "$([ -f "$_sentinel" ] && echo true || echo false)"
assert_pass_if_clean "test_usage_limit_detected"

# ═════════════════════════════════════════════════════════════════════════════
# test_quota_exceeded_detected
# Input containing "quota.exceeded" → sentinel file MUST be created, return 0.
# ═════════════════════════════════════════════════════════════════════════════
_snapshot_fail
_tmp=$(_make_tmp)
_sentinel="$_tmp/rate-limit.sentinel"
_source_lifecycle "$_sentinel"
_rc=0
_check_rate_limit_error "Your API quota.exceeded the monthly limit" 2>/dev/null || _rc=$?
assert_eq "test_quota_exceeded_detected: return code 0 on match" "0" "$_rc"
assert_eq "test_quota_exceeded_detected: sentinel created" "true" "$([ -f "$_sentinel" ] && echo true || echo false)"
assert_pass_if_clean "test_quota_exceeded_detected"

# ═════════════════════════════════════════════════════════════════════════════
# test_transient_429_not_matched
# Input containing only "HTTP 429" (no quota keyword) → no sentinel, return non-zero.
# The function must exist (return code must NOT be 127 = command not found).
# ═════════════════════════════════════════════════════════════════════════════
_snapshot_fail
_tmp=$(_make_tmp)
_sentinel="$_tmp/rate-limit.sentinel"
_source_lifecycle "$_sentinel"
_rc=0
_check_rate_limit_error "The request failed: HTTP 429 Too Many Requests" 2>/dev/null || _rc=$?
# 127 = command not found (function absent) — must not equal 127 in GREEN
assert_ne "test_transient_429_not_matched: function must exist (not 127)" "127" "$_rc"
assert_ne "test_transient_429_not_matched: return code non-zero on 429-only input" "0" "$_rc"
assert_eq "test_transient_429_not_matched: sentinel NOT created" "false" "$([ -f "$_sentinel" ] && echo true || echo false)"
assert_pass_if_clean "test_transient_429_not_matched"

# ═════════════════════════════════════════════════════════════════════════════
# test_no_match
# Clean (non-error) input → no sentinel, return non-zero.
# The function must exist (return code must NOT be 127 = command not found).
# ═════════════════════════════════════════════════════════════════════════════
_snapshot_fail
_tmp=$(_make_tmp)
_sentinel="$_tmp/rate-limit.sentinel"
_source_lifecycle "$_sentinel"
_rc=0
_check_rate_limit_error "Task completed successfully. No errors detected." 2>/dev/null || _rc=$?
# 127 = command not found (function absent) — must not equal 127 in GREEN
assert_ne "test_no_match: function must exist (not 127)" "127" "$_rc"
assert_ne "test_no_match: return code non-zero on clean input" "0" "$_rc"
assert_eq "test_no_match: sentinel NOT created" "false" "$([ -f "$_sentinel" ] && echo true || echo false)"
assert_pass_if_clean "test_no_match"

# ═════════════════════════════════════════════════════════════════════════════
# test_sentinel_overrides_pre_check
# When a fresh sentinel exists, cmd_pre_check MUST emit MAX_AGENTS: 1
# regardless of check-usage.sh verdict (unlimited).
# ═════════════════════════════════════════════════════════════════════════════
_snapshot_fail
_tmp=$(_make_tmp)
_sentinel="$_tmp/rate-limit.sentinel"
# Create a fresh sentinel (timestamp = now)
touch "$_sentinel"
_mock_dir=$(_make_mock_usage 0)  # check-usage.sh exits 0 → "unlimited" without sentinel
_output=""
_output=$(
    PATH="$_mock_dir:$PATH" \
    WORKFLOW_CONFIG=/dev/null \
    RATE_LIMIT_SENTINEL="$_sentinel" \
        bash "$LIFECYCLE" pre-check 2>/dev/null
) || true
assert_contains "test_sentinel_overrides_pre_check: MAX_AGENTS: 1" "MAX_AGENTS: 1" "$_output"
assert_pass_if_clean "test_sentinel_overrides_pre_check"

# ═════════════════════════════════════════════════════════════════════════════
# test_sentinel_ttl_expired
# Sentinel older than 5 minutes → ignored; MAX_AGENTS falls back to
# check-usage.sh result (unlimited here), NOT forced to 1.
#
# This test has two phases:
#   Phase A — fresh sentinel: cmd_pre_check MUST emit MAX_AGENTS: 1
#             (establishes that sentinel-reading logic exists in cmd_pre_check)
#   Phase B — expired sentinel: cmd_pre_check MUST emit MAX_AGENTS: unlimited
#             (establishes that TTL expiry restores normal behavior)
# Both phases must pass for the test to be GREEN. Phase A fails RED because
# cmd_pre_check does not yet implement sentinel logic.
# ═════════════════════════════════════════════════════════════════════════════
_snapshot_fail
_tmp=$(_make_tmp)
_sentinel="$_tmp/rate-limit.sentinel"
_mock_dir=$(_make_mock_usage 0)  # check-usage.sh exits 0 → "unlimited" without sentinel

# Phase A: fresh sentinel → cmd_pre_check must output MAX_AGENTS: 1
touch "$_sentinel"
_output_fresh=""
_output_fresh=$(
    PATH="$_mock_dir:$PATH" \
    WORKFLOW_CONFIG=/dev/null \
    RATE_LIMIT_SENTINEL="$_sentinel" \
        bash "$LIFECYCLE" pre-check 2>/dev/null
) || true
assert_contains "test_sentinel_ttl_expired phase-A: fresh sentinel forces MAX_AGENTS: 1" "MAX_AGENTS: 1" "$_output_fresh"

# Phase B: expire sentinel (backdate to 6 minutes ago)
# 360 seconds past the 5-minute TTL boundary
touch -t "$(date -v -360S '+%Y%m%d%H%M.%S' 2>/dev/null || date -d '6 minutes ago' '+%Y%m%d%H%M.%S' 2>/dev/null)" "$_sentinel" 2>/dev/null || true
_output_expired=""
_output_expired=$(
    PATH="$_mock_dir:$PATH" \
    WORKFLOW_CONFIG=/dev/null \
    RATE_LIMIT_SENTINEL="$_sentinel" \
        bash "$LIFECYCLE" pre-check 2>/dev/null
) || true
# Expired sentinel is ignored — falls back to check-usage.sh unlimited verdict
assert_contains "test_sentinel_ttl_expired phase-B: expired sentinel → MAX_AGENTS: unlimited" "MAX_AGENTS: unlimited" "$_output_expired"
assert_pass_if_clean "test_sentinel_ttl_expired"

print_summary
