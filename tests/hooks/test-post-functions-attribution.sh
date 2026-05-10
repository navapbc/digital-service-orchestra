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
_t1_output=$(
    env PATH="$_T1_MOCKBIN:$PATH" \
        ARTIFACTS_DIR="$_T1_ARTIFACTS" \
        CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" \
        SCRIPTS_DIR="$_T1_MOCKBIN" \
        bash -c "
    set -uo pipefail
    source \"$POST_FUNCTIONS\" 2>/dev/null
    hook_record_agent_attribution '$_T1_AGENT_INPUT'
" 2>&1) || _t1_exit=$?

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
env PATH="$_T2_MOCKBIN:$PATH" \
    ARTIFACTS_DIR="$_T2_ARTIFACTS" \
    CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" \
    SCRIPTS_DIR="$_T2_MOCKBIN" \
    bash -c "
    set -uo pipefail
    source \"$POST_FUNCTIONS\" 2>/dev/null
    hook_record_agent_attribution '$_T2_AGENT_INPUT'
" 2>/dev/null || _t2_exit=$?

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
# test_hook_record_agent_attribution_resolves_read_config_via_claude_plugin_root (C1)
#
# RED: hook only checks "${SCRIPTS_DIR:-}/read-config.sh". When SCRIPTS_DIR is
# unset (the post-agent.sh dispatcher does not set it), `_enabled` stays empty
# regardless of config, and the hook silently no-ops — feature is dead at
# runtime. After fix: agent hook adopts the same SCRIPTS_DIR → PATH →
# CLAUDE_PLUGIN_ROOT/scripts/ chain that the skill hook already uses.
# ============================================================
echo "--- test_hook_record_agent_attribution_resolves_read_config_via_claude_plugin_root ---"

_T3_TMPDIR=$(mktemp -d)
_TEST_TMPDIRS+=("$_T3_TMPDIR")

# Build a fake plugin tree with scripts/read-config.sh → "true"
_T3_PLUGIN_ROOT="$_T3_TMPDIR/plugin"
mkdir -p "$_T3_PLUGIN_ROOT/scripts"
cat > "$_T3_PLUGIN_ROOT/scripts/read-config.sh" <<'MOCK_EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "attribution.enabled" ]]; then
    echo "true"
fi
MOCK_EOF
chmod +x "$_T3_PLUGIN_ROOT/scripts/read-config.sh"

_T3_ARTIFACTS="$_T3_TMPDIR/artifacts"
mkdir -p "$_T3_ARTIFACTS"

_T3_AGENT_INPUT='{"tool_name":"Agent","tool_input":{"prompt":"x","subagent_type":"dso:via-plugin-root"},"tool_response":{"output":"ok","model":"sonnet"}}'

# Critical: do NOT set SCRIPTS_DIR; do NOT put read-config.sh on PATH.
env -i \
    HOME="$HOME" \
    PATH="/usr/bin:/bin" \
    CLAUDE_PLUGIN_ROOT="$_T3_PLUGIN_ROOT" \
    ARTIFACTS_DIR="$_T3_ARTIFACTS" \
    bash -c "
    set -uo pipefail
    source \"$POST_FUNCTIONS\" 2>/dev/null
    hook_record_agent_attribution '$_T3_AGENT_INPUT'
" 2>/dev/null || true

_T3_JSONL="$_T3_ARTIFACTS/attribution-contributors.jsonl"

_t3_has_entry="no"
if [[ -f "$_T3_JSONL" ]]; then
    _t3_match=$(python3 -c "
import json, sys
try:
    with open(sys.argv[1]) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            d = json.loads(line)
            if (d.get('type') == 'agent'
                    and d.get('subagent_type') == 'dso:via-plugin-root'
                    and d.get('model') == 'sonnet'):
                print('found')
                sys.exit(0)
    print('absent')
except Exception:
    print('absent')
" "$_T3_JSONL" 2>/dev/null)
    [[ "$_t3_match" == "found" ]] && _t3_has_entry="yes"
fi

assert_eq \
    "C1: agent hook resolves read-config.sh via CLAUDE_PLUGIN_ROOT and writes JSONL entry" \
    "yes" \
    "$_t3_has_entry"

# ============================================================
# test_hook_record_agent_attribution_warns_on_artifacts_dir_failure (L3)
#
# RED: an `ERR` trap silently swallows mkdir/printf failures. If the artifacts
# dir cannot be created or written, the hook returns 0 with no observability,
# masking attribution loss. After fix: failures emit a stderr WARNING, the
# hook still returns 0 (non-blocking).
# ============================================================
echo "--- test_hook_record_agent_attribution_warns_on_artifacts_dir_failure ---"

_T4_TMPDIR=$(mktemp -d)
_TEST_TMPDIRS+=("$_T4_TMPDIR")

# Skip when running as root (chmod 555 has no effect for root)
if [[ "$(id -u)" -eq 0 ]]; then
    echo "SKIP: test_hook_record_agent_attribution_warns_on_artifacts_dir_failure (running as root)"
else
    _T4_MOCKBIN="$_T4_TMPDIR/bin"
    mkdir -p "$_T4_MOCKBIN"
    cat > "$_T4_MOCKBIN/read-config.sh" <<'MOCK_EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "attribution.enabled" ]]; then
    echo "true"
fi
MOCK_EOF
    chmod +x "$_T4_MOCKBIN/read-config.sh"

    # Make a parent dir read-only so mkdir of a child fails.
    _T4_PARENT="$_T4_TMPDIR/locked"
    mkdir -p "$_T4_PARENT"
    chmod 555 "$_T4_PARENT"
    _T4_ARTIFACTS="$_T4_PARENT/artifacts"

    _T4_AGENT_INPUT='{"tool_name":"Agent","tool_input":{"prompt":"x","subagent_type":"dso:warn-test"},"tool_response":{"output":"ok","model":"sonnet"}}'

    _t4_stderr_file="$_T4_TMPDIR/stderr.txt"
    _t4_exit=0
    env PATH="$_T4_MOCKBIN:$PATH" \
        ARTIFACTS_DIR="$_T4_ARTIFACTS" \
        SCRIPTS_DIR="$_T4_MOCKBIN" \
        CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" \
        bash -c "
    set -uo pipefail
    source \"$POST_FUNCTIONS\" 2>/dev/null
    hook_record_agent_attribution '$_T4_AGENT_INPUT'
" 2>"$_t4_stderr_file" || _t4_exit=$?

    # Hook is non-blocking — must return 0 even on failure.
    assert_eq "L3: hook exits 0 (non-blocking) on artifacts-dir failure" "0" "$_t4_exit"

    _t4_has_warning=0
    grep -qi 'warning\|attribution.*fail\|fail.*attribution' "$_t4_stderr_file" 2>/dev/null && _t4_has_warning=1
    assert_eq "L3: stderr contains warning when attribution write fails" "1" "$_t4_has_warning"

    # Restore so cleanup can remove the dir
    chmod 755 "$_T4_PARENT" 2>/dev/null || true
fi

# ============================================================
# test_hook_record_agent_attribution_does_not_leak_err_trap_to_caller (C2)
#
# RED: hook installs `trap 'return 0' ERR` and returns early on the disabled
# config path without restoring the prior trap. When the function is sourced
# (not run in a subshell), the global ERR trap leaks into subsequent commands
# and masks unrelated errors. After fix: trap is restored on every return path.
# ============================================================
echo "--- test_hook_record_agent_attribution_does_not_leak_err_trap_to_caller ---"

_T5_TMPDIR=$(mktemp -d)
_TEST_TMPDIRS+=("$_T5_TMPDIR")

# read-config.sh that returns empty (disabled) — drives the early-return path
_T5_MOCKBIN="$_T5_TMPDIR/bin"
mkdir -p "$_T5_MOCKBIN"
cat > "$_T5_MOCKBIN/read-config.sh" <<'MOCK_EOF'
#!/usr/bin/env bash
exit 0
MOCK_EOF
chmod +x "$_T5_MOCKBIN/read-config.sh"

_T5_AGENT_INPUT='{"tool_name":"Agent","tool_input":{"prompt":"x","subagent_type":"dso:trap-test"},"tool_response":{"output":"ok","model":"sonnet"}}'

# After the early-return path, run a sentinel that detects whether the ERR
# trap is still active. If the trap leaks, `false` would silently `return 0`
# and the marker file would not be created with the expected exit code.
_T5_MARKER="$_T5_TMPDIR/marker"
env PATH="$_T5_MOCKBIN:$PATH" \
    ARTIFACTS_DIR="$_T5_TMPDIR/artifacts" \
    SCRIPTS_DIR="$_T5_MOCKBIN" \
    CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" \
    bash -c "
set -uo pipefail
source \"$POST_FUNCTIONS\" 2>/dev/null
# Capture pristine ERR trap before hook call
_pre_trap=\"\$(trap -p ERR)\"
hook_record_agent_attribution '$_T5_AGENT_INPUT'
_post_trap=\"\$(trap -p ERR)\"
if [[ \"\$_pre_trap\" == \"\$_post_trap\" ]]; then
    echo restored > \"$_T5_MARKER\"
else
    echo leaked > \"$_T5_MARKER\"
fi
" 2>/dev/null || true

_t5_status="missing"
[[ -f "$_T5_MARKER" ]] && _t5_status="$(cat "$_T5_MARKER")"
assert_eq "C2: ERR trap restored after early-return on disabled config" "restored" "$_t5_status"

# ============================================================
# test_hook_record_agent_attribution_honors_workflow_plugin_artifacts_dir (N2)
#
# RED: agent hook reads ${ARTIFACTS_DIR:-} only; skill hook reads
# ${WORKFLOW_PLUGIN_ARTIFACTS_DIR:-${ARTIFACTS_DIR:-}}. In a dispatch context
# that exports WORKFLOW_PLUGIN_ARTIFACTS_DIR (the script
# apply-attribution-trailers.sh and resolve_artifacts() in deps.sh both treat
# it as the highest-priority resolution), agent attribution writes to a
# different directory than the script reads from — silent data loss.
#
# After fix: agent hook prefers WORKFLOW_PLUGIN_ARTIFACTS_DIR when set,
# matching the skill hook.
# ============================================================
echo "--- test_hook_record_agent_attribution_honors_workflow_plugin_artifacts_dir ---"

_T6_TMPDIR=$(mktemp -d)
_TEST_TMPDIRS+=("$_T6_TMPDIR")

# Mock read-config.sh → "true"
_T6_MOCKBIN="$_T6_TMPDIR/bin"
mkdir -p "$_T6_MOCKBIN"
cat > "$_T6_MOCKBIN/read-config.sh" <<'MOCK_EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "attribution.enabled" ]]; then
    echo "true"
fi
MOCK_EOF
chmod +x "$_T6_MOCKBIN/read-config.sh"

# Two distinct dirs — the hook must write to WORKFLOW_PLUGIN_ARTIFACTS_DIR
# (not ARTIFACTS_DIR) because the script also resolves to it first.
_T6_WORKFLOW_DIR="$_T6_TMPDIR/workflow-artifacts"
_T6_FALLBACK_DIR="$_T6_TMPDIR/fallback-artifacts"
mkdir -p "$_T6_WORKFLOW_DIR" "$_T6_FALLBACK_DIR"

_T6_AGENT_INPUT='{"tool_name":"Agent","tool_input":{"prompt":"x","subagent_type":"dso:wpad-test"},"tool_response":{"output":"ok","model":"sonnet"}}'

env PATH="$_T6_MOCKBIN:$PATH" \
    WORKFLOW_PLUGIN_ARTIFACTS_DIR="$_T6_WORKFLOW_DIR" \
    ARTIFACTS_DIR="$_T6_FALLBACK_DIR" \
    SCRIPTS_DIR="$_T6_MOCKBIN" \
    CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" \
    bash -c "
    set -uo pipefail
    source \"$POST_FUNCTIONS\" 2>/dev/null
    hook_record_agent_attribution '$_T6_AGENT_INPUT'
" 2>/dev/null || true

_t6_workflow_count="0"
if [[ -f "$_T6_WORKFLOW_DIR/attribution-contributors.jsonl" ]]; then
    _t6_workflow_count=$(grep -c '"subagent_type": "dso:wpad-test"' "$_T6_WORKFLOW_DIR/attribution-contributors.jsonl" 2>/dev/null) || _t6_workflow_count="0"
fi

_t6_fallback_count="0"
if [[ -f "$_T6_FALLBACK_DIR/attribution-contributors.jsonl" ]]; then
    _t6_fallback_count=$(grep -c '"subagent_type": "dso:wpad-test"' "$_T6_FALLBACK_DIR/attribution-contributors.jsonl" 2>/dev/null) || _t6_fallback_count="0"
fi

assert_eq \
    "N2: agent hook writes to WORKFLOW_PLUGIN_ARTIFACTS_DIR when set" \
    "1" \
    "$_t6_workflow_count"

assert_eq \
    "N2: agent hook does NOT write to ARTIFACTS_DIR when WORKFLOW_PLUGIN_ARTIFACTS_DIR is set" \
    "0" \
    "$_t6_fallback_count"

# ============================================================
# Summary
# ============================================================
print_summary
