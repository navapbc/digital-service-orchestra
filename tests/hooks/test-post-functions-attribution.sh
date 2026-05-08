#!/usr/bin/env bash
# tests/hooks/test-post-functions-attribution.sh
# RED tests for hook_record_agent_attribution (does NOT exist yet — tests must fail).
#
# Tests:
#   test_hook_record_agent_attribution_writes_jsonl_entry_when_enabled
#     When attribution.enabled=true (mocked via read-config.sh PATH prepend),
#     calling hook_record_agent_attribution with agent input JSON containing
#     subagent_type and model should append a JSONL entry to
#     $ARTIFACTS_DIR/attribution-contributors.jsonl.
#
#   test_hook_record_agent_attribution_skips_write_when_disabled
#     When attribution.enabled is not "true" (mock returns empty),
#     calling hook_record_agent_attribution should NOT append any entry.
#
# Design notes:
#   - Each test runs inside a fresh bash subshell to work around the
#     _POST_FUNCTIONS_LOADED=1 guard in post-functions.sh (double-sourcing
#     the file is a no-op — the function would be undefined in a second
#     source attempt if not yet written).
#   - read-config.sh is mocked via PATH prepend — the target implementation
#     will call: bash "$SCRIPTS_DIR/read-config.sh" attribution.enabled
#     Tests create a mock read-config.sh in a temp dir prepended to PATH.
#   - ARTIFACTS_DIR is set to an isolated temp dir so JSONL output is sandboxed.
#   - SCRIPTS_DIR in the sourced post-functions.sh will resolve to the mock
#     bin dir on PATH (since bash "$SCRIPTS_DIR/read-config.sh" will exec
#     the first read-config.sh found on PATH when SCRIPTS_DIR is the mock dir).
#
# Usage: bash tests/hooks/test-post-functions-attribution.sh
# Exit code: 0 if all pass, 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
POST_FUNCTIONS="$DSO_PLUGIN_DIR/hooks/lib/post-functions.sh"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

# Temp dir cleanup on exit
_TEST_TMPDIRS=()
_cleanup() {
    for d in "${_TEST_TMPDIRS[@]:-}"; do
        [[ -n "$d" ]] && rm -rf "$d" 2>/dev/null
    done
}
trap _cleanup EXIT

# ============================================================
# test_hook_record_agent_attribution_writes_jsonl_entry_when_enabled
#
# Setup:
#   - Mock read-config.sh: outputs "true" (attribution.enabled=true)
#   - ARTIFACTS_DIR: isolated temp dir
#   - Run hook_record_agent_attribution with agent input JSON
#
# Expected (GREEN, after implementation):
#   - attribution-contributors.jsonl exists in ARTIFACTS_DIR
#   - Contains a line with {"type":"agent","subagent_type":"code-reviewer","model":"claude-sonnet-4-6"}
#
# RED assertion: hook_record_agent_attribution function does not exist yet →
#   sourcing post-functions.sh and calling the function exits non-zero (command not found).
# ============================================================
echo "--- test_hook_record_agent_attribution_writes_jsonl_entry_when_enabled ---"

_T1_TMPDIR=$(mktemp -d)
_TEST_TMPDIRS+=("$_T1_TMPDIR")

# Create mock read-config.sh that returns "true" for attribution.enabled
_T1_MOCKBIN="$_T1_TMPDIR/bin"
mkdir -p "$_T1_MOCKBIN"
cat > "$_T1_MOCKBIN/read-config.sh" <<'MOCK_EOF'
#!/usr/bin/env bash
# Mock read-config.sh: returns "true" for attribution.enabled, empty for all else
if [[ "${1:-}" == "attribution.enabled" || "${2:-}" == "attribution.enabled" ]]; then
    echo "true"
fi
MOCK_EOF
chmod +x "$_T1_MOCKBIN/read-config.sh"

_T1_ARTIFACTS="$_T1_TMPDIR/artifacts"
mkdir -p "$_T1_ARTIFACTS"

_T1_AGENT_INPUT='{"tool_name":"Agent","tool_input":{"prompt":"do review","subagent_type":"code-reviewer"},"tool_response":{"output":"Done.","model":"claude-sonnet-4-6"}}'

_t1_exit=0
_t1_output=$(bash -c '
    set -uo pipefail
    export PATH="'"$_T1_MOCKBIN"':$PATH"
    export ARTIFACTS_DIR="'"$_T1_ARTIFACTS"'"
    export CLAUDE_PLUGIN_ROOT="'"$DSO_PLUGIN_DIR"'"
    export SCRIPTS_DIR="'"$_T1_MOCKBIN"'"
    source "'"$POST_FUNCTIONS"'" 2>/dev/null
    hook_record_agent_attribution "'"$_T1_AGENT_INPUT"'"
' 2>&1) || _t1_exit=$?

_T1_JSONL="$_T1_ARTIFACTS/attribution-contributors.jsonl"

# RED assertion: function does not exist — subshell exits non-zero or JSONL is absent/wrong
_t1_jsonl_exists="no"
[[ -f "$_T1_JSONL" ]] && _t1_jsonl_exists="yes"

_t1_has_entry="no"
if [[ "$_t1_jsonl_exists" == "yes" ]]; then
    _t1_content=$(python3 -c "
import json, sys
try:
    with open(sys.argv[1]) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            d = json.loads(line)
            if (d.get('type') == 'agent'
                    and d.get('subagent_type') == 'code-reviewer'
                    and d.get('model') == 'claude-sonnet-4-6'):
                print('found')
                sys.exit(0)
    print('absent')
except Exception as e:
    print('error:' + str(e))
" "$_T1_JSONL" 2>/dev/null)
    [[ "$_t1_content" == "found" ]] && _t1_has_entry="yes"
fi

assert_eq \
    "test_hook_record_agent_attribution_writes_jsonl_entry_when_enabled: JSONL entry written" \
    "yes" \
    "$_t1_has_entry"

# ============================================================
# test_hook_record_agent_attribution_skips_write_when_disabled
#
# Setup:
#   - Mock read-config.sh: returns empty string (attribution.enabled is NOT "true")
#   - ARTIFACTS_DIR: isolated temp dir
#   - Run hook_record_agent_attribution with agent input JSON
#
# Expected (GREEN, after implementation):
#   - attribution-contributors.jsonl does NOT exist (or is empty)
#
# RED assertion: function does not exist yet → no JSONL file is written for the
#   wrong reason; test verifies the absence of JSONL, which is the correct
#   observable outcome but fails because the function is also absent for the
#   enabled test above.
# ============================================================
echo "--- test_hook_record_agent_attribution_skips_write_when_disabled ---"

_T2_TMPDIR=$(mktemp -d)
_TEST_TMPDIRS+=("$_T2_TMPDIR")

# Create mock read-config.sh that returns empty (attribution.enabled not "true")
_T2_MOCKBIN="$_T2_TMPDIR/bin"
mkdir -p "$_T2_MOCKBIN"
cat > "$_T2_MOCKBIN/read-config.sh" <<'MOCK_EOF'
#!/usr/bin/env bash
# Mock read-config.sh: returns empty string for all keys (attribution disabled)
exit 0
MOCK_EOF
chmod +x "$_T2_MOCKBIN/read-config.sh"

_T2_ARTIFACTS="$_T2_TMPDIR/artifacts"
mkdir -p "$_T2_ARTIFACTS"

_T2_AGENT_INPUT='{"tool_name":"Agent","tool_input":{"prompt":"do review","subagent_type":"code-reviewer"},"tool_response":{"output":"Done.","model":"claude-sonnet-4-6"}}'

_t2_exit=0
bash -c '
    set -uo pipefail
    export PATH="'"$_T2_MOCKBIN"':$PATH"
    export ARTIFACTS_DIR="'"$_T2_ARTIFACTS"'"
    export CLAUDE_PLUGIN_ROOT="'"$DSO_PLUGIN_DIR"'"
    export SCRIPTS_DIR="'"$_T2_MOCKBIN"'"
    source "'"$POST_FUNCTIONS"'" 2>/dev/null
    hook_record_agent_attribution "'"$_T2_AGENT_INPUT"'"
' 2>/dev/null || _t2_exit=$?

_T2_JSONL="$_T2_ARTIFACTS/attribution-contributors.jsonl"

# Count lines in the JSONL file — if it exists at all, it should have 0 entries
_t2_entry_count=0
if [[ -f "$_T2_JSONL" ]]; then
    _t2_entry_count=$(python3 -c "
import json, sys
count = 0
try:
    with open(sys.argv[1]) as f:
        for line in f:
            line = line.strip()
            if line:
                count += 1
except Exception:
    pass
print(count)
" "$_T2_JSONL" 2>/dev/null || echo "0")
fi

assert_eq \
    "test_hook_record_agent_attribution_skips_write_when_disabled: no JSONL entry written when disabled" \
    "0" \
    "$_t2_entry_count"

# ============================================================
# Summary
# ============================================================
print_summary
