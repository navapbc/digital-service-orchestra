#!/usr/bin/env bash
# tests/scripts/test-lifecycle-max-agents.sh
# RED tests for _compute_max_agents() in agent-batch-lifecycle.sh.
#
# _compute_max_agents() does NOT exist yet — all tests must FAIL (RED phase).
#
# Behavioral contract under test:
#   - Call check-usage.sh and capture exit code:
#       0 = unlimited
#       1 = throttled → MAX_AGENTS=1
#       2 = paused    → MAX_AGENTS=0 (always wins)
#   - Read orchestration.max_agents config via _read_cfg()
#   - Apply config cap: min(verdict_value, config_value)
#   - Paused (exit 2) always produces "0" regardless of config
#   - When CLAUDE_CONTEXT_WINDOW_USAGE >= 0.90 (context-check exit 11), cap to "1"
#   - When check-usage.sh prints USAGE_SOURCE: no-credentials, treat as unlimited
#   - When config is absent, fall back to unlimited (backward compatible)
#   - Outputs final value to stdout as a bare string (e.g. "unlimited", "1", "3")
#
# Test approach:
#   1. Each test creates a mock check-usage.sh in a temp dir.
#   2. That temp dir is prepended to PATH so lifecycle picks up the mock.
#   3. A minimal WORKFLOW_CONFIG is written to control orchestration.max_agents.
#   4. The lifecycle script is sourced with a safe no-op subcommand to load
#      function definitions without running the main dispatch block.
#   5. _compute_max_agents() is called; output is asserted.
#
# Usage: bash tests/scripts/test-lifecycle-max-agents.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail (RED: expect exit 1)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR" && git rev-parse --show-toplevel)"
LIFECYCLE="$REPO_ROOT/plugins/dso/scripts/agent-batch-lifecycle.sh"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-lifecycle-max-agents.sh ==="

# ── Cleanup registry ──────────────────────────────────────────────────────────
_TEST_TMPDIRS=()
_cleanup_tmpdirs() {
    for d in "${_TEST_TMPDIRS[@]:-}"; do
        rm -rf "$d"
    done
}
trap '_cleanup_tmpdirs' EXIT

# ── Sourcing helper ───────────────────────────────────────────────────────────
# Source agent-batch-lifecycle.sh using a safe no-op subcommand so the main
# dispatch block runs a real subcommand (cleanup-stale-containers exits 0
# quickly when infrastructure config is absent) rather than hitting the *) case
# which would exit 2 and terminate our test shell.
#
# After sourcing, all internal functions including _compute_max_agents() are
# available in the current shell.
_source_lifecycle() {
    local cfg="${1:-/dev/null}"
    WORKFLOW_CONFIG="$cfg" source "$LIFECYCLE" cleanup-stale-containers 2>/dev/null
}

# ── Mock factory ──────────────────────────────────────────────────────────────
# _make_mock_dir <exit_code> [extra_stdout]
# Creates a temp dir containing a check-usage.sh mock that exits with <exit_code>
# and optionally prints <extra_stdout> to stdout.
# Sets _MOCK_DIR to the created directory.
_make_mock_dir() {
    local exit_code="$1"
    local extra_stdout="${2:-}"
    local d
    d="$(mktemp -d)"
    _TEST_TMPDIRS+=("$d")

    cat > "$d/check-usage.sh" <<MOCKEOF
#!/usr/bin/env bash
${extra_stdout:+echo "$extra_stdout"}
exit $exit_code
MOCKEOF
    chmod +x "$d/check-usage.sh"
    _MOCK_DIR="$d"
}

# ── Config factory ────────────────────────────────────────────────────────────
# _make_cfg [max_agents_value]
# Writes a minimal dso-config.conf to a temp file. If max_agents_value is given,
# sets orchestration.max_agents=<value>. Returns the path in _CFG_FILE.
_make_cfg() {
    local max_agents="${1:-}"
    local d
    d="$(mktemp -d)"
    _TEST_TMPDIRS+=("$d")
    local cfg="$d/dso-config.conf"
    if [ -n "$max_agents" ]; then
        printf 'orchestration.max_agents=%s\n' "$max_agents" > "$cfg"
    else
        printf '# no orchestration.max_agents key\n' > "$cfg"
    fi
    _CFG_FILE="$cfg"
}

# ── test_verdict_unlimited ────────────────────────────────────────────────────
# check-usage.sh exits 0 (unlimited), no config cap → output "unlimited"
_snapshot_fail
_make_mock_dir 0 "USAGE_SOURCE: no-credentials"
_make_cfg  # no orchestration.max_agents
_source_lifecycle "$_CFG_FILE"
result=""
result=$(PATH="$_MOCK_DIR:$PATH" WORKFLOW_CONFIG="$_CFG_FILE" _compute_max_agents 2>/dev/null) || true
assert_eq "test_verdict_unlimited: output is unlimited" "unlimited" "$result"
assert_pass_if_clean "test_verdict_unlimited"

# ── test_verdict_throttled ────────────────────────────────────────────────────
# check-usage.sh exits 1 (throttled), no config cap → output "1"
_snapshot_fail
_make_mock_dir 1 "USAGE_SOURCE: api"
_make_cfg  # no orchestration.max_agents
_source_lifecycle "$_CFG_FILE"
result=""
result=$(PATH="$_MOCK_DIR:$PATH" WORKFLOW_CONFIG="$_CFG_FILE" _compute_max_agents 2>/dev/null) || true
assert_eq "test_verdict_throttled: output is 1" "1" "$result"
assert_pass_if_clean "test_verdict_throttled"

# ── test_verdict_paused ───────────────────────────────────────────────────────
# check-usage.sh exits 2 (paused), no config cap → output "0"
_snapshot_fail
_make_mock_dir 2 "USAGE_SOURCE: api"
_make_cfg  # no orchestration.max_agents
_source_lifecycle "$_CFG_FILE"
result=""
result=$(PATH="$_MOCK_DIR:$PATH" WORKFLOW_CONFIG="$_CFG_FILE" _compute_max_agents 2>/dev/null) || true
assert_eq "test_verdict_paused: output is 0" "0" "$result"
assert_pass_if_clean "test_verdict_paused"

# ── test_config_cap_applied ───────────────────────────────────────────────────
# check-usage.sh exits 0 (unlimited → numeric unlimited), config cap=3 → output "3"
_snapshot_fail
_make_mock_dir 0 "USAGE_SOURCE: api"
_make_cfg 3
_source_lifecycle "$_CFG_FILE"
result=""
result=$(PATH="$_MOCK_DIR:$PATH" WORKFLOW_CONFIG="$_CFG_FILE" _compute_max_agents 2>/dev/null) || true
assert_eq "test_config_cap_applied: output is 3" "3" "$result"
assert_pass_if_clean "test_config_cap_applied"

# ── test_config_cap_lower_than_throttle ──────────────────────────────────────
# check-usage.sh exits 1 (throttled=1), config cap=5 → min(1,5)=1 → output "1"
_snapshot_fail
_make_mock_dir 1 "USAGE_SOURCE: api"
_make_cfg 5
_source_lifecycle "$_CFG_FILE"
result=""
result=$(PATH="$_MOCK_DIR:$PATH" WORKFLOW_CONFIG="$_CFG_FILE" _compute_max_agents 2>/dev/null) || true
assert_eq "test_config_cap_lower_than_throttle: output is 1 (min wins)" "1" "$result"
assert_pass_if_clean "test_config_cap_lower_than_throttle"

# ── test_config_cap_with_paused ───────────────────────────────────────────────
# check-usage.sh exits 2 (paused=0), config cap=3 → paused always wins → output "0"
_snapshot_fail
_make_mock_dir 2 "USAGE_SOURCE: api"
_make_cfg 3
_source_lifecycle "$_CFG_FILE"
result=""
result=$(PATH="$_MOCK_DIR:$PATH" WORKFLOW_CONFIG="$_CFG_FILE" _compute_max_agents 2>/dev/null) || true
assert_eq "test_config_cap_with_paused: output is 0 (paused wins)" "0" "$result"
assert_pass_if_clean "test_config_cap_with_paused"

# ── test_no_credentials_fallback ─────────────────────────────────────────────
# check-usage.sh exits 0 with USAGE_SOURCE: no-credentials → treated as unlimited.
# With config cap absent → output "unlimited".
_snapshot_fail
_make_mock_dir 0 "USAGE_SOURCE: no-credentials"
_make_cfg  # no config cap
_source_lifecycle "$_CFG_FILE"
result=""
result=$(PATH="$_MOCK_DIR:$PATH" WORKFLOW_CONFIG="$_CFG_FILE" _compute_max_agents 2>/dev/null) || true
assert_eq "test_no_credentials_fallback: output is unlimited" "unlimited" "$result"
assert_pass_if_clean "test_no_credentials_fallback"

# ── test_config_absent_fallback ───────────────────────────────────────────────
# orchestration.max_agents key absent from config → backward-compatible default.
# exit 0 from check-usage.sh → output "unlimited" (no cap applied when key missing).
_snapshot_fail
_make_mock_dir 0 "USAGE_SOURCE: api"
_make_cfg  # orchestration.max_agents deliberately absent
_source_lifecycle "$_CFG_FILE"
result=""
result=$(PATH="$_MOCK_DIR:$PATH" WORKFLOW_CONFIG="$_CFG_FILE" _compute_max_agents 2>/dev/null) || true
assert_eq "test_config_absent_fallback: output is unlimited" "unlimited" "$result"
assert_pass_if_clean "test_config_absent_fallback"

# ── test_context_check_exit11 ─────────────────────────────────────────────────
# When context-check (internal detection) returns exit 11 (high usage),
# MAX_AGENTS should be forced to 1, regardless of check-usage.sh verdict.
# This models the precedence: context-check exit 11 → cap at 1.
# check-usage.sh exits 0 (unlimited), but high context → output "1".
_snapshot_fail
_make_mock_dir 0 "USAGE_SOURCE: api"
_make_cfg  # no config cap
_source_lifecycle "$_CFG_FILE"
result=""
# Simulate context-check returning exit 11 by setting CLAUDE_CONTEXT_WINDOW_USAGE to 0.95 (>90%)
result=$(PATH="$_MOCK_DIR:$PATH" WORKFLOW_CONFIG="$_CFG_FILE" CLAUDE_CONTEXT_WINDOW_USAGE="0.95" _compute_max_agents 2>/dev/null) || true
assert_eq "test_context_check_exit11: high context caps at 1" "1" "$result"
assert_pass_if_clean "test_context_check_exit11"

print_summary
