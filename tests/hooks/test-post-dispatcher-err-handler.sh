#!/usr/bin/env bash
# tests/hooks/test-post-dispatcher-err-handler.sh
# RED behavioral tests: verify all 5 post-* dispatchers use hook-error-handler.sh.
#
# For each dispatcher we assert two behaviors when an ERR fires:
#   1. Exit 0 (fail-open — never blocks Claude Code)
#   2. A JSONL entry is written to $HOME/.claude/logs/dso-hook-errors.jsonl
#
# Tests are RED before task 36a8-27a9 (dispatchers don't yet source
# hook-error-handler.sh / call _dso_register_hook_err_handler).
# They become GREEN after 36a8-27a9 adds the source + registration calls.
#
# ERR injection strategy:
#   - Each test builds a stub $HOOKS_LIB_DIR with:
#       - A real symlink to dispatcher.sh (needed for parse_json_field etc.)
#       - A stub post-functions.sh that defines all needed functions
#         AND runs `false` at the end to fire ERR in the dispatcher's
#         top-level shell (after _dso_register_hook_err_handler registers
#         the ERR trap, per the GREEN implementation).
#       - A stub session-misc-functions.sh (for post-failure only)
#   - CLAUDE_PLUGIN_ROOT is set to point at a fake plugin root whose
#     hooks/lib/ is the stub lib. This overrides path resolution in every
#     dispatcher without touching the source files.
#
# Functions tested:
#   test_post_bash_err_fails_open
#   test_post_bash_err_writes_jsonl
#   test_post_edit_err_fails_open
#   test_post_edit_err_writes_jsonl
#   test_post_write_err_fails_open
#   test_post_write_err_writes_jsonl
#   test_post_all_err_fails_open
#   test_post_all_err_writes_jsonl
#   test_post_agent_err_fails_open
#   test_post_agent_err_writes_jsonl
#   test_post_failure_err_fails_open
#   test_post_failure_err_writes_jsonl
#
# Usage: bash tests/hooks/test-post-dispatcher-err-handler.sh
# Exit code: 0 if all pass, non-zero if any fail.

set -uo pipefail
# set -e intentionally omitted: dispatchers under test may exit non-zero in RED state;
# non-zero exits are captured via '|| _exit=$?' and asserted via assert_eq.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR" && git rev-parse --show-toplevel)"
DSO_PLUGIN_DIR="$REPO_ROOT/plugins/dso"

source "$REPO_ROOT/tests/lib/assert.sh"

# ---- Temp dir registry --------------------------------------------------------
_TEST_TMPDIRS=()
_cleanup_all() {
    for _d in "${_TEST_TMPDIRS[@]:-}"; do
        [[ -d "$_d" ]] && rm -rf "$_d"
    done
}
trap _cleanup_all EXIT

# ---- Helper: build a stub hooks lib -------------------------------------------
# _build_stub_lib <stub_lib_dir>
#   Populates <stub_lib_dir> with:
#     dispatcher.sh  → symlink to real dispatcher.sh
#     hook-error-handler.sh → symlink to real hook-error-handler.sh
#     post-functions.sh → stub that defines all functions + runs `false`
#     session-misc-functions.sh → stub that defines all functions + runs `false`
#
# The `false` at the end of each sourced stub triggers an ERR in the
# dispatcher's top-level context after _dso_register_hook_err_handler has
# registered the ERR trap (GREEN implementation), causing _dso_hook_err_handler
# to fire, write JSONL, and exit 0.
_build_stub_lib() {
    local _stub_lib="$1"
    mkdir -p "$_stub_lib"

    # Real dispatcher.sh (provides parse_json_field, run_hooks)
    ln -sf "$DSO_PLUGIN_DIR/hooks/lib/dispatcher.sh" "$_stub_lib/dispatcher.sh"

    # Real hook-error-handler.sh (the library under test)
    ln -sf "$DSO_PLUGIN_DIR/hooks/lib/hook-error-handler.sh" "$_stub_lib/hook-error-handler.sh"

    # Stub post-functions.sh: defines all expected hook functions, then runs `false`
    # to trigger ERR in the dispatcher's top-level shell.
    cat > "$_stub_lib/post-functions.sh" <<'STUB_POST_FUNCTIONS'
#!/usr/bin/env bash
# Stub post-functions.sh for ERR injection testing.
# Defines all functions that post-* dispatchers expect, then runs `false`
# to trigger an ERR at the top level of the dispatcher's shell context.

hook_exit_144_forensic_logger()   { return 0; }
hook_check_validation_failures()  { return 0; }
hook_track_cascade_failures()     { return 0; }
hook_auto_format()                { return 0; }
hook_tool_logging_pre()           { return 0; }
hook_tool_logging_post()          { return 0; }
hook_extract_agent_suggestion()   { return 0; }

# Inject ERR: `false` runs at source time in the dispatcher's top-level shell.
# After GREEN implementation, _dso_register_hook_err_handler has already set
# trap '_dso_hook_err_handler' ERR, so this fires the handler which writes JSONL.
false
STUB_POST_FUNCTIONS

    # Stub session-misc-functions.sh: defines all expected hook functions + `false`
    cat > "$_stub_lib/session-misc-functions.sh" <<'STUB_SESSION_MISC'
#!/usr/bin/env bash
# Stub session-misc-functions.sh for ERR injection testing.

hook_cleanup_orphaned_processes() { return 0; }
hook_cleanup_stale_nohup()        { return 0; }
hook_inject_using_lockpick()      { return 0; }
hook_session_safety_check()       { return 0; }
hook_post_compact_review_check()  { return 0; }
hook_review_stop_check()          { return 0; }
hook_tool_logging_summary()       { return 0; }
hook_track_tool_errors()          { return 0; }
hook_plan_review_gate()           { return 0; }
hook_brainstorm_gate()            { return 0; }

# Inject ERR at source time (same strategy as post-functions.sh stub).
false
STUB_SESSION_MISC
}

# ---- Helper: build a fake plugin root whose hooks/lib → stub lib --------------
# _build_fake_plugin_root <root_dir> <stub_lib_dir>
# Creates <root_dir>/hooks/lib/ as a directory containing symlinks to stub_lib.
_build_fake_plugin_root() {
    local _fake_root="$1" _stub_lib="$2"
    mkdir -p "$_fake_root/hooks"
    ln -sf "$_stub_lib" "$_fake_root/hooks/lib"
}

# ---- Helper: make a minimal hook JSON input -----------------------------------
_hook_input() {
    printf '{"tool_name":"Bash","tool_input":{"command":"echo hi"},"tool_response":{"stdout":"hi","stderr":"","exit_code":0}}'
}

# ==============================================================================
# post-bash.sh
# ==============================================================================

# ------------------------------------------------------------------------------
# test_post_bash_err_fails_open
# Verify post-bash.sh exits 0 when an ERR fires inside the dispatcher.
# ------------------------------------------------------------------------------
echo "--- test_post_bash_err_fails_open ---"
_TMP_BASH_FO=$(mktemp -d); _TEST_TMPDIRS+=("$_TMP_BASH_FO")
_build_stub_lib "$_TMP_BASH_FO/hooks_lib"
_build_fake_plugin_root "$_TMP_BASH_FO/fake_plugin" "$_TMP_BASH_FO/hooks_lib"
mkdir -p "$_TMP_BASH_FO/home/.claude/logs"

_bash_fo_exit=0
HOME="$_TMP_BASH_FO/home" CLAUDE_PLUGIN_ROOT="$_TMP_BASH_FO/fake_plugin" \
    bash "$DSO_PLUGIN_DIR/hooks/dispatchers/post-bash.sh" \
    < <(printf '%s' "$(_hook_input)") >/dev/null 2>/dev/null \
    || _bash_fo_exit=$?
assert_eq "test_post_bash_err_fails_open: exits 0" "0" "$_bash_fo_exit"

# ------------------------------------------------------------------------------
# test_post_bash_err_writes_jsonl
# Verify post-bash.sh writes a JSONL entry to dso-hook-errors.jsonl on ERR.
# RED: fails because post-bash.sh's inline `trap 'exit 0' ERR` doesn't write JSONL.
# GREEN: passes after _dso_register_hook_err_handler is registered.
# ------------------------------------------------------------------------------
echo "--- test_post_bash_err_writes_jsonl ---"
_TMP_BASH=$(mktemp -d); _TEST_TMPDIRS+=("$_TMP_BASH")
_STUB_LIB_BASH="$_TMP_BASH/hooks_lib"
_FAKE_ROOT_BASH="$_TMP_BASH/fake_plugin"
_TEST_HOME_BASH="$_TMP_BASH/home"
mkdir -p "$_TEST_HOME_BASH/.claude/logs"
_build_stub_lib "$_STUB_LIB_BASH"
_build_fake_plugin_root "$_FAKE_ROOT_BASH" "$_STUB_LIB_BASH"

_JSONL_FILE="$_TEST_HOME_BASH/.claude/logs/dso-hook-errors.jsonl"

HOME="$_TEST_HOME_BASH" CLAUDE_PLUGIN_ROOT="$_FAKE_ROOT_BASH" \
    bash "$DSO_PLUGIN_DIR/hooks/dispatchers/post-bash.sh" \
    < <(printf '%s' "$(_hook_input)") >/dev/null || true  # stderr visible for debugging

_jsonl_found=0
if [[ -f "$_JSONL_FILE" ]] && grep -q '"hook"' "$_JSONL_FILE" 2>/dev/null; then
    _jsonl_found=1
fi
assert_eq "test_post_bash_err_writes_jsonl: JSONL entry written to dso-hook-errors.jsonl" "1" "$_jsonl_found"

# ==============================================================================
# post-edit.sh
# ==============================================================================

# ------------------------------------------------------------------------------
# test_post_edit_err_fails_open
# ------------------------------------------------------------------------------
echo "--- test_post_edit_err_fails_open ---"
_TMP_EDIT_FO=$(mktemp -d); _TEST_TMPDIRS+=("$_TMP_EDIT_FO")
_build_stub_lib "$_TMP_EDIT_FO/hooks_lib"
_build_fake_plugin_root "$_TMP_EDIT_FO/fake_plugin" "$_TMP_EDIT_FO/hooks_lib"
mkdir -p "$_TMP_EDIT_FO/home/.claude/logs"

_edit_fo_exit=0
HOME="$_TMP_EDIT_FO/home" CLAUDE_PLUGIN_ROOT="$_TMP_EDIT_FO/fake_plugin" \
    bash "$DSO_PLUGIN_DIR/hooks/dispatchers/post-edit.sh" \
    < <(printf '{"tool_name":"Edit","tool_input":{"file_path":"/tmp/t.txt"},"tool_response":{"success":true}}') \
    >/dev/null 2>/dev/null \
    || _edit_fo_exit=$?
assert_eq "test_post_edit_err_fails_open: exits 0" "0" "$_edit_fo_exit"

# ------------------------------------------------------------------------------
# test_post_edit_err_writes_jsonl
# RED: fails because post-edit.sh doesn't write JSONL on ERR.
# ------------------------------------------------------------------------------
echo "--- test_post_edit_err_writes_jsonl ---"
_TMP_EDIT=$(mktemp -d); _TEST_TMPDIRS+=("$_TMP_EDIT")
_STUB_LIB_EDIT="$_TMP_EDIT/hooks_lib"
_FAKE_ROOT_EDIT="$_TMP_EDIT/fake_plugin"
_TEST_HOME_EDIT="$_TMP_EDIT/home"
mkdir -p "$_TEST_HOME_EDIT/.claude/logs"
_build_stub_lib "$_STUB_LIB_EDIT"
_build_fake_plugin_root "$_FAKE_ROOT_EDIT" "$_STUB_LIB_EDIT"

_JSONL_FILE_EDIT="$_TEST_HOME_EDIT/.claude/logs/dso-hook-errors.jsonl"

HOME="$_TEST_HOME_EDIT" CLAUDE_PLUGIN_ROOT="$_FAKE_ROOT_EDIT" \
    bash "$DSO_PLUGIN_DIR/hooks/dispatchers/post-edit.sh" \
    < <(printf '{"tool_name":"Edit","tool_input":{"file_path":"/tmp/t.txt"},"tool_response":{"success":true}}') \
    >/dev/null || true  # stderr visible for debugging

_jsonl_found=0
if [[ -f "$_JSONL_FILE_EDIT" ]] && grep -q '"hook"' "$_JSONL_FILE_EDIT" 2>/dev/null; then
    _jsonl_found=1
fi
assert_eq "test_post_edit_err_writes_jsonl: JSONL entry written to dso-hook-errors.jsonl" "1" "$_jsonl_found"

# ==============================================================================
# post-write.sh
# ==============================================================================

# ------------------------------------------------------------------------------
# test_post_write_err_fails_open
# ------------------------------------------------------------------------------
echo "--- test_post_write_err_fails_open ---"
_TMP_WRITE_FO=$(mktemp -d); _TEST_TMPDIRS+=("$_TMP_WRITE_FO")
_build_stub_lib "$_TMP_WRITE_FO/hooks_lib"
_build_fake_plugin_root "$_TMP_WRITE_FO/fake_plugin" "$_TMP_WRITE_FO/hooks_lib"
mkdir -p "$_TMP_WRITE_FO/home/.claude/logs"

_write_fo_exit=0
HOME="$_TMP_WRITE_FO/home" CLAUDE_PLUGIN_ROOT="$_TMP_WRITE_FO/fake_plugin" \
    bash "$DSO_PLUGIN_DIR/hooks/dispatchers/post-write.sh" \
    < <(printf '{"tool_name":"Write","tool_input":{"file_path":"/tmp/t.txt","content":"x"},"tool_response":{"success":true}}') \
    >/dev/null 2>/dev/null \
    || _write_fo_exit=$?
assert_eq "test_post_write_err_fails_open: exits 0" "0" "$_write_fo_exit"

# ------------------------------------------------------------------------------
# test_post_write_err_writes_jsonl
# RED: fails because post-write.sh doesn't write JSONL on ERR.
# ------------------------------------------------------------------------------
echo "--- test_post_write_err_writes_jsonl ---"
_TMP_WRITE=$(mktemp -d); _TEST_TMPDIRS+=("$_TMP_WRITE")
_STUB_LIB_WRITE="$_TMP_WRITE/hooks_lib"
_FAKE_ROOT_WRITE="$_TMP_WRITE/fake_plugin"
_TEST_HOME_WRITE="$_TMP_WRITE/home"
mkdir -p "$_TEST_HOME_WRITE/.claude/logs"
_build_stub_lib "$_STUB_LIB_WRITE"
_build_fake_plugin_root "$_FAKE_ROOT_WRITE" "$_STUB_LIB_WRITE"

_JSONL_FILE_WRITE="$_TEST_HOME_WRITE/.claude/logs/dso-hook-errors.jsonl"

HOME="$_TEST_HOME_WRITE" CLAUDE_PLUGIN_ROOT="$_FAKE_ROOT_WRITE" \
    bash "$DSO_PLUGIN_DIR/hooks/dispatchers/post-write.sh" \
    < <(printf '{"tool_name":"Write","tool_input":{"file_path":"/tmp/t.txt","content":"x"},"tool_response":{"success":true}}') \
    >/dev/null || true  # stderr visible for debugging

_jsonl_found=0
if [[ -f "$_JSONL_FILE_WRITE" ]] && grep -q '"hook"' "$_JSONL_FILE_WRITE" 2>/dev/null; then
    _jsonl_found=1
fi
assert_eq "test_post_write_err_writes_jsonl: JSONL entry written to dso-hook-errors.jsonl" "1" "$_jsonl_found"

# ==============================================================================
# post-all.sh
# ==============================================================================

# ------------------------------------------------------------------------------
# test_post_all_err_fails_open
# ------------------------------------------------------------------------------
echo "--- test_post_all_err_fails_open ---"
_TMP_ALL_FO=$(mktemp -d); _TEST_TMPDIRS+=("$_TMP_ALL_FO")
_build_stub_lib "$_TMP_ALL_FO/hooks_lib"
_build_fake_plugin_root "$_TMP_ALL_FO/fake_plugin" "$_TMP_ALL_FO/hooks_lib"
mkdir -p "$_TMP_ALL_FO/home/.claude/logs"

_all_fo_exit=0
HOME="$_TMP_ALL_FO/home" CLAUDE_PLUGIN_ROOT="$_TMP_ALL_FO/fake_plugin" \
    bash "$DSO_PLUGIN_DIR/hooks/dispatchers/post-all.sh" \
    < <(printf '{"tool_name":"Read","tool_input":{"file_path":"/tmp/t.txt"},"tool_response":{"content":"data"}}') \
    >/dev/null 2>/dev/null \
    || _all_fo_exit=$?
assert_eq "test_post_all_err_fails_open: exits 0" "0" "$_all_fo_exit"

# ------------------------------------------------------------------------------
# test_post_all_err_writes_jsonl
# RED: fails because post-all.sh doesn't write JSONL on ERR.
# ------------------------------------------------------------------------------
echo "--- test_post_all_err_writes_jsonl ---"
_TMP_ALL=$(mktemp -d); _TEST_TMPDIRS+=("$_TMP_ALL")
_STUB_LIB_ALL="$_TMP_ALL/hooks_lib"
_FAKE_ROOT_ALL="$_TMP_ALL/fake_plugin"
_TEST_HOME_ALL="$_TMP_ALL/home"
mkdir -p "$_TEST_HOME_ALL/.claude/logs"
_build_stub_lib "$_STUB_LIB_ALL"
_build_fake_plugin_root "$_FAKE_ROOT_ALL" "$_STUB_LIB_ALL"

_JSONL_FILE_ALL="$_TEST_HOME_ALL/.claude/logs/dso-hook-errors.jsonl"

HOME="$_TEST_HOME_ALL" CLAUDE_PLUGIN_ROOT="$_FAKE_ROOT_ALL" \
    bash "$DSO_PLUGIN_DIR/hooks/dispatchers/post-all.sh" \
    < <(printf '{"tool_name":"Read","tool_input":{"file_path":"/tmp/t.txt"},"tool_response":{"content":"data"}}') \
    >/dev/null || true  # stderr visible for debugging

_jsonl_found=0
if [[ -f "$_JSONL_FILE_ALL" ]] && grep -q '"hook"' "$_JSONL_FILE_ALL" 2>/dev/null; then
    _jsonl_found=1
fi
assert_eq "test_post_all_err_writes_jsonl: JSONL entry written to dso-hook-errors.jsonl" "1" "$_jsonl_found"

# ==============================================================================
# post-agent.sh
# ==============================================================================

# ------------------------------------------------------------------------------
# test_post_agent_err_fails_open
# ------------------------------------------------------------------------------
echo "--- test_post_agent_err_fails_open ---"
_TMP_AGENT_FO=$(mktemp -d); _TEST_TMPDIRS+=("$_TMP_AGENT_FO")
_build_stub_lib "$_TMP_AGENT_FO/hooks_lib"
_build_fake_plugin_root "$_TMP_AGENT_FO/fake_plugin" "$_TMP_AGENT_FO/hooks_lib"
mkdir -p "$_TMP_AGENT_FO/home/.claude/logs"

_agent_fo_exit=0
HOME="$_TMP_AGENT_FO/home" CLAUDE_PLUGIN_ROOT="$_TMP_AGENT_FO/fake_plugin" \
    bash "$DSO_PLUGIN_DIR/hooks/dispatchers/post-agent.sh" \
    < <(printf '{"tool_name":"Agent","tool_input":{},"tool_response":{"output":"done"}}') \
    >/dev/null 2>/dev/null \
    || _agent_fo_exit=$?
assert_eq "test_post_agent_err_fails_open: exits 0" "0" "$_agent_fo_exit"

# ------------------------------------------------------------------------------
# test_post_agent_err_writes_jsonl
# RED: fails because post-agent.sh doesn't write JSONL on ERR.
# ------------------------------------------------------------------------------
echo "--- test_post_agent_err_writes_jsonl ---"
_TMP_AGENT=$(mktemp -d); _TEST_TMPDIRS+=("$_TMP_AGENT")
_STUB_LIB_AGENT="$_TMP_AGENT/hooks_lib"
_FAKE_ROOT_AGENT="$_TMP_AGENT/fake_plugin"
_TEST_HOME_AGENT="$_TMP_AGENT/home"
mkdir -p "$_TEST_HOME_AGENT/.claude/logs"
_build_stub_lib "$_STUB_LIB_AGENT"
_build_fake_plugin_root "$_FAKE_ROOT_AGENT" "$_STUB_LIB_AGENT"

_JSONL_FILE_AGENT="$_TEST_HOME_AGENT/.claude/logs/dso-hook-errors.jsonl"

HOME="$_TEST_HOME_AGENT" CLAUDE_PLUGIN_ROOT="$_FAKE_ROOT_AGENT" \
    bash "$DSO_PLUGIN_DIR/hooks/dispatchers/post-agent.sh" \
    < <(printf '{"tool_name":"Agent","tool_input":{},"tool_response":{"output":"done"}}') \
    >/dev/null || true  # stderr visible for debugging

_jsonl_found=0
if [[ -f "$_JSONL_FILE_AGENT" ]] && grep -q '"hook"' "$_JSONL_FILE_AGENT" 2>/dev/null; then
    _jsonl_found=1
fi
assert_eq "test_post_agent_err_writes_jsonl: JSONL entry written to dso-hook-errors.jsonl" "1" "$_jsonl_found"

# ==============================================================================
# post-failure.sh
# ==============================================================================

# ------------------------------------------------------------------------------
# test_post_failure_err_fails_open
# ------------------------------------------------------------------------------
echo "--- test_post_failure_err_fails_open ---"
_TMP_FAILURE_FO=$(mktemp -d); _TEST_TMPDIRS+=("$_TMP_FAILURE_FO")
_build_stub_lib "$_TMP_FAILURE_FO/hooks_lib"
_build_fake_plugin_root "$_TMP_FAILURE_FO/fake_plugin" "$_TMP_FAILURE_FO/hooks_lib"
mkdir -p "$_TMP_FAILURE_FO/home/.claude/logs"

_failure_fo_exit=0
HOME="$_TMP_FAILURE_FO/home" CLAUDE_PLUGIN_ROOT="$_TMP_FAILURE_FO/fake_plugin" \
    bash "$DSO_PLUGIN_DIR/hooks/dispatchers/post-failure.sh" \
    < <(printf '{"tool_name":"Bash","tool_input":{"command":"false"},"tool_response":{"exit_code":1}}') \
    >/dev/null 2>/dev/null \
    || _failure_fo_exit=$?
assert_eq "test_post_failure_err_fails_open: exits 0" "0" "$_failure_fo_exit"

# ------------------------------------------------------------------------------
# test_post_failure_err_writes_jsonl
# RED: fails because post-failure.sh doesn't write JSONL on ERR.
# post-failure.sh does not have `trap ERR` at all in RED phase; after GREEN
# implementation sources hook-error-handler.sh + calls _dso_register_hook_err_handler,
# the ERR trap fires the handler which writes JSONL.
# ------------------------------------------------------------------------------
echo "--- test_post_failure_err_writes_jsonl ---"
_TMP_FAILURE=$(mktemp -d); _TEST_TMPDIRS+=("$_TMP_FAILURE")
_STUB_LIB_FAILURE="$_TMP_FAILURE/hooks_lib"
_FAKE_ROOT_FAILURE="$_TMP_FAILURE/fake_plugin"
_TEST_HOME_FAILURE="$_TMP_FAILURE/home"
mkdir -p "$_TEST_HOME_FAILURE/.claude/logs"
_build_stub_lib "$_STUB_LIB_FAILURE"
_build_fake_plugin_root "$_FAKE_ROOT_FAILURE" "$_STUB_LIB_FAILURE"

_JSONL_FILE_FAILURE="$_TEST_HOME_FAILURE/.claude/logs/dso-hook-errors.jsonl"

HOME="$_TEST_HOME_FAILURE" CLAUDE_PLUGIN_ROOT="$_FAKE_ROOT_FAILURE" \
    bash "$DSO_PLUGIN_DIR/hooks/dispatchers/post-failure.sh" \
    < <(printf '{"tool_name":"Bash","tool_input":{"command":"false"},"tool_response":{"exit_code":1}}') \
    >/dev/null || true  # stderr visible for debugging

_jsonl_found=0
if [[ -f "$_JSONL_FILE_FAILURE" ]] && grep -q '"hook"' "$_JSONL_FILE_FAILURE" 2>/dev/null; then
    _jsonl_found=1
fi
assert_eq "test_post_failure_err_writes_jsonl: JSONL entry written to dso-hook-errors.jsonl" "1" "$_jsonl_found"

# ==============================================================================
# Summary
# ==============================================================================
print_summary
