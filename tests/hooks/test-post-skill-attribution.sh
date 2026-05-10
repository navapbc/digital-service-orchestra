#!/usr/bin/env bash
# tests/hooks/test-post-skill-attribution.sh
# RED tests for hook_record_skill_attribution (post-functions.sh) and
# post-skill.sh dispatcher — both targets do NOT exist yet.
#
# Tests:
#   test_hook_record_skill_attribution_writes_jsonl_entry_when_enabled
#   test_post_skill_dispatcher_appends_skill_entry_to_jsonl
#
# Both tests run in fresh subshells to guarantee clean load-guard state.
#
# Usage: bash tests/hooks/test-post-skill-attribution.sh
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

POST_SKILL_DISPATCHER="$DSO_PLUGIN_DIR/hooks/dispatchers/post-skill.sh"
POST_FUNCTIONS="$DSO_PLUGIN_DIR/hooks/lib/post-functions.sh"

# ============================================================
# test_hook_record_skill_attribution_writes_jsonl_entry_when_enabled
#
# When attribution.enabled=true, calling hook_record_skill_attribution
# with a Skill tool input JSON should append a JSONL entry of the form
# {"type":"skill","skill_name":"<value>"} to attribution-contributors.jsonl.
#
# This test is RED because hook_record_skill_attribution does not exist
# in post-functions.sh yet.
# ============================================================
echo "--- test_hook_record_skill_attribution_writes_jsonl_entry_when_enabled ---"

_T1_DIR=$(mktemp -d)
_TEST_TMPDIRS+=("$_T1_DIR")

# Build a mock read-config.sh that returns "true" for attribution.enabled
_MOCK_BIN_DIR="$_T1_DIR/mockbin"
mkdir -p "$_MOCK_BIN_DIR"
cat > "$_MOCK_BIN_DIR/read-config.sh" <<'MOCK_EOF'
#!/usr/bin/env bash
# Mock read-config.sh: always returns "true" for attribution.enabled
echo "true"
exit 0
MOCK_EOF
chmod +x "$_MOCK_BIN_DIR/read-config.sh"

_T1_JSONL="$_T1_DIR/attribution-contributors.jsonl"
_SKILL_INPUT='{"tool_name":"Skill","tool_input":{"skill":"dso:sprint"},"tool_response":{"output":"done"}}'

# Run in a fresh subshell to guarantee a clean load-guard environment.
# env(1) passes variables explicitly to avoid SC2030 subshell-export warnings.
_T1_RESULT=$(
    env CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" \
        WORKFLOW_PLUGIN_ARTIFACTS_DIR="$_T1_DIR" \
        PATH="$_MOCK_BIN_DIR:$PATH" \
        bash -c "
        source \"$POST_FUNCTIONS\" 2>/dev/null || true
        if declare -f hook_record_skill_attribution >/dev/null 2>&1; then
            hook_record_skill_attribution '$_SKILL_INPUT'
            echo 'function_called'
        else
            echo 'function_missing'
        fi
    " 2>/dev/null
)

# RED assertion: the function must not exist yet → subshell reports function_missing.
# After implementation, it will report function_called and write the JSONL entry.
assert_eq \
    "test_hook_record_skill_attribution_writes_jsonl_entry_when_enabled: function exists in post-functions.sh" \
    "function_called" \
    "$_T1_RESULT"

# Verify the JSONL side-effect by parsing each line as JSON and matching the
# full expected object (defends against false positives from substring matches).
_T1_MATCH="absent"
if [[ -f "$_T1_JSONL" ]]; then
    _T1_MATCH=$(python3 - "$_T1_JSONL" <<'PYEOF' 2>/dev/null
import json, sys
expected = {"type": "skill", "skill_name": "dso:sprint"}
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
    "test_hook_record_skill_attribution_writes_jsonl_entry_when_enabled: jsonl entry matches {type:skill, skill_name}" \
    "match" \
    "$_T1_MATCH"

# ============================================================
# test_post_skill_dispatcher_appends_skill_entry_to_jsonl
#
# When executing post-skill.sh with a Skill tool input (via stdin),
# it should append a skill attribution entry to attribution-contributors.jsonl
# in the artifacts directory.
#
# This test is RED because post-skill.sh does not exist yet.
# ============================================================
echo "--- test_post_skill_dispatcher_appends_skill_entry_to_jsonl ---"

_T2_DIR=$(mktemp -d)
_TEST_TMPDIRS+=("$_T2_DIR")

# Reuse same mock read-config.sh
_T2_MOCK_BIN_DIR="$_T2_DIR/mockbin"
mkdir -p "$_T2_MOCK_BIN_DIR"
cat > "$_T2_MOCK_BIN_DIR/read-config.sh" <<'MOCK2_EOF'
#!/usr/bin/env bash
echo "true"
exit 0
MOCK2_EOF
chmod +x "$_T2_MOCK_BIN_DIR/read-config.sh"

_T2_JSONL="$_T2_DIR/attribution-contributors.jsonl"
_T2_SKILL_INPUT='{"tool_name":"Skill","tool_input":{"skill":"dso:fix-bug"},"tool_response":{"output":"done"}}'

# Run in a fresh subshell — dispatcher must be sourced/executed cleanly.
# env(1) passes variables explicitly to avoid SC2030/SC2031 subshell-export warnings.
_T2_EXIT=1
if [[ -f "$POST_SKILL_DISPATCHER" ]]; then
    (
        env CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" \
            WORKFLOW_PLUGIN_ARTIFACTS_DIR="$_T2_DIR" \
            PATH="$_T2_MOCK_BIN_DIR:$PATH" \
            bash -c "printf '%s' '$_T2_SKILL_INPUT' | bash '$POST_SKILL_DISPATCHER'" \
            >/dev/null 2>/dev/null
    )
    _T2_EXIT=$?
else
    # Dispatcher missing → explicit failure
    _T2_EXIT=127
fi

# RED assertion: post-skill.sh does not exist, so we expect exit 127 or non-zero.
# After implementation this must exit 0.
assert_eq \
    "test_post_skill_dispatcher_appends_skill_entry_to_jsonl: dispatcher exits 0" \
    "0" \
    "$_T2_EXIT"

_T2_MATCH="absent"
if [[ -f "$_T2_JSONL" ]]; then
    _T2_MATCH=$(python3 - "$_T2_JSONL" <<'PYEOF' 2>/dev/null
import json, sys
expected = {"type": "skill", "skill_name": "dso:fix-bug"}
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
    "test_post_skill_dispatcher_appends_skill_entry_to_jsonl: jsonl entry matches {type:skill, skill_name=dso:fix-bug}" \
    "match" \
    "$_T2_MATCH"

# ============================================================
# Summary
# ============================================================
print_summary
