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

# Verify the dispatcher wrote a single JSONL entry whose parsed fields match
# the expected agent attribution shape (parses with python3 — substring matches
# could pass for unrelated payloads with the same key fragments).
_T1_MATCH="absent"
if [[ -f "$_T1_JSONL" ]]; then
    _T1_MATCH=$(python3 - "$_T1_JSONL" <<'PYEOF' 2>/dev/null
import json, sys
expected = {"type": "agent", "subagent_type": "dso:red-test-writer", "model": "claude-sonnet-4-6"}
try:
    with open(sys.argv[1]) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            obj = json.loads(line)
            if obj == expected:
                print("match")
                sys.exit(0)
except Exception:
    pass
print("absent")
PYEOF
)
fi
assert_eq \
    "test_post_agent_dispatcher_writes_attribution_jsonl_entry: jsonl entry matches {type:agent, subagent_type, model}" \
    "match" \
    "$_T1_MATCH"

# ============================================================
# Summary
# ============================================================
print_summary
