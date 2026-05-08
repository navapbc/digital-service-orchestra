#!/usr/bin/env bash
# tests/hooks/test-post-agent-attribution.sh
# RED test: post-agent.sh dispatcher must call hook_record_agent_attribution.
#
# Tests:
#   test_post_agent_dispatcher_writes_attribution_jsonl_entry
#
# This test is RED because post-agent.sh does not yet call
# hook_record_agent_attribution — so no JSONL entry is written.
#
# Usage: bash tests/hooks/test-post-agent-attribution.sh
# Exit code: 0 if all pass, 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

export CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR"

# Temp dir cleanup on exit
_TEST_TMPDIRS=()
_cleanup() {
    for d in "${_TEST_TMPDIRS[@]:-}"; do
        [[ -n "$d" ]] && rm -rf "$d" 2>/dev/null
    done
}
trap _cleanup EXIT

POST_AGENT_DISPATCHER="$DSO_PLUGIN_DIR/hooks/dispatchers/post-agent.sh"

# ============================================================
# test_post_agent_dispatcher_writes_attribution_jsonl_entry
#
# When post-agent.sh is executed with an Agent tool input that has
# subagent_type set, and attribution.enabled=true, it should append a JSONL
# entry containing "subagent_type":"dso:red-test-writer" to
# $ARTIFACTS_DIR/attribution-contributors.jsonl.
#
# This test is RED because post-agent.sh does not call
# hook_record_agent_attribution yet — so no JSONL entry is written.
# ============================================================
echo "--- test_post_agent_dispatcher_writes_attribution_jsonl_entry ---"

_T1_DIR=$(mktemp -d)
_TEST_TMPDIRS+=("$_T1_DIR")

# Build mock scripts directory with a read-config.sh that returns "true"
# for attribution.enabled. hook_record_agent_attribution resolves read-config.sh
# via SCRIPTS_DIR (not PATH), so we place the mock there.
_T1_SCRIPTS_DIR="$_T1_DIR/scripts"
mkdir -p "$_T1_SCRIPTS_DIR"
cat > "$_T1_SCRIPTS_DIR/read-config.sh" <<'MOCK_EOF'
#!/usr/bin/env bash
# Mock read-config.sh: always returns "true" for attribution.enabled
echo "true"
exit 0
MOCK_EOF
chmod +x "$_T1_SCRIPTS_DIR/read-config.sh"

_T1_JSONL="$_T1_DIR/attribution-contributors.jsonl"
_T1_INPUT='{"tool_use_id":"tu1","tool_name":"Agent","tool_input":{"subagent_type":"dso:red-test-writer"},"tool_response":{"model":"claude-sonnet-4-6","content":""}}'

# Run the dispatcher in a fresh subshell.
# env(1) passes variables explicitly to avoid SC2030 subshell-export warnings.
# SCRIPTS_DIR — required by hook_record_agent_attribution for read-config.sh lookup
# ARTIFACTS_DIR — where the JSONL file will be written
_T1_EXIT=0
(
    env CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" \
        SCRIPTS_DIR="$_T1_SCRIPTS_DIR" \
        ARTIFACTS_DIR="$_T1_DIR" \
        bash -c "printf '%s' '$_T1_INPUT' | bash '$POST_AGENT_DISPATCHER'" \
        >/dev/null 2>/dev/null
) || _T1_EXIT=$?

# Dispatcher must exit 0 (PostToolUse hooks are always non-blocking)
assert_eq \
    "test_post_agent_dispatcher_writes_attribution_jsonl_entry: dispatcher exits 0" \
    "0" \
    "$_T1_EXIT"

# RED assertion: no JSONL entry written yet because the dispatcher doesn't call
# hook_record_agent_attribution. After the fix, the file will exist and contain
# the expected entry.
_T1_JSONL_CONTENT=""
[[ -f "$_T1_JSONL" ]] && _T1_JSONL_CONTENT=$(cat "$_T1_JSONL")

assert_contains \
    "test_post_agent_dispatcher_writes_attribution_jsonl_entry: jsonl contains subagent_type key" \
    '"subagent_type"' \
    "$_T1_JSONL_CONTENT"

assert_contains \
    "test_post_agent_dispatcher_writes_attribution_jsonl_entry: jsonl contains dso:red-test-writer" \
    "dso:red-test-writer" \
    "$_T1_JSONL_CONTENT"

assert_contains \
    "test_post_agent_dispatcher_writes_attribution_jsonl_entry: jsonl contains type=agent" \
    '"type":"agent"' \
    "$_T1_JSONL_CONTENT"

# ============================================================
# Summary
# ============================================================
print_summary
