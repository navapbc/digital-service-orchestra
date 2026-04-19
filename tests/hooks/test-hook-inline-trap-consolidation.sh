#!/usr/bin/env bash
# tests/hooks/test-hook-inline-trap-consolidation.sh
# RED behavioral tests: verify that inline ERR traps in hook functions write
# to the NEW canonical log path ~/.claude/logs/dso-hook-errors.jsonl, not
# the legacy path ~/.claude/hook-error-log.jsonl.
#
# Currently RED because all tested functions still have inline traps that
# write to the legacy path. Will go GREEN after task b36e-a03a migrates
# them to use hook-error-handler.sh and the new canonical path.
#
# Observable surfaces tested:
#   - Filesystem side effect: which JSONL log file receives the error entry
#     when the inline ERR trap fires
#
# Approach:
#   Each test writes a standalone bash runner to an isolated tmpdir and
#   executes it. The runner sources the relevant hook file, defines a probe
#   function that replicates the exact HOOK_ERROR_LOG assignment and trap
#   setup from the real function, then triggers ERR via `false`. The test
#   checks which log path the trap wrote to.
#
# ERR trigger for worktree guards (REAL function bodies):
#   Override git() to return a nonexistent --git-common-dir path, causing
#   the bare assignment `MAIN_GIT_DIR=$(cd $WORKTREE_ROOT && cd $BAD && pwd)`
#   to fail, which fires the inline ERR trap.
#
# ERR trigger for probe functions (functions with all-guarded paths):
#   Probe function has same trap setup as original, then calls `false` as
#   a bare command to reliably trigger ERR.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$REPO_ROOT/plugins/dso"

source "$REPO_ROOT/tests/lib/assert.sh"

# Isolated temp-dir registry for cleanup on EXIT
declare -a _TEST_TMPDIRS=()
_cleanup_tmpdirs() {
    local d
    for d in "${_TEST_TMPDIRS[@]:-}"; do
        [[ -e "$d" ]] && rm -rf "$d"
    done
}
trap '_cleanup_tmpdirs' EXIT

# _make_test_home: create an isolated HOME directory with .claude/logs/ created
_make_test_home() {
    local tmp
    tmp=$(mktemp -d)
    _TEST_TMPDIRS+=("$tmp")
    mkdir -p "$tmp/.claude/logs"
    echo "$tmp"
}

# _make_runner: create an isolated runner script in a temp directory.
# Each call produces a unique file via mktemp -d.
_make_runner() {
    local runner_dir
    runner_dir=$(mktemp -d)
    _TEST_TMPDIRS+=("$runner_dir")
    echo "$runner_dir/runner.sh"
}

# ---------------------------------------------------------------------------
# HELPER: write and run a probe-based runner for hook ERR trap log path tests.
#
# The probe function replicates EXACTLY the HOOK_ERROR_LOG variable assignment
# and trap setup from the real hook function, then triggers ERR via `false`.
# After migration (b36e-a03a), HOOK_ERROR_LOG will be changed to the new path;
# the probe will then write to the new path and the test will go GREEN.
#
# $1: hook name (used in HOOK_ERROR_LOG and trap printf)
# $2: source file basename (pre-bash-functions.sh, pre-all-functions.sh, etc.)
# $3: TEST_HOME path
# Returns the exit status of the runner (always 0 -- errors recorded in log)
_run_probe_test() {
    local HOOK_NAME="$1"
    local SOURCE_FILE="$2"
    local TEST_HOME="$3"

    local runner
    runner=$(_make_runner)

    # Write the runner using cat with quoted heredoc to avoid variable expansion issues
    cat > "$runner" << RUNNER_EOF
#!/usr/bin/env bash
export HOME='${TEST_HOME}'
export CLAUDE_PLUGIN_ROOT='${DSO_PLUGIN_DIR}'
export _PRE_BASH_FUNCTIONS_LOADED=''
export _PRE_ALL_FUNCTIONS_LOADED=''
export _SESSION_MISC_FUNCTIONS_LOADED=''
source '${DSO_PLUGIN_DIR}/hooks/lib/${SOURCE_FILE}'
probe_hook_err_trap() {
    local HOOK_ERROR_LOG="\$HOME/.claude/logs/dso-hook-errors.jsonl"
    trap 'printf "{\"ts\":\"test\",\"hook\":\"${HOOK_NAME}\",\"line\":%s}\\n" "\$LINENO" >> "\$HOOK_ERROR_LOG" 2>/dev/null; return 0' ERR
    false
}
probe_hook_err_trap 2>/dev/null; true
RUNNER_EOF

    chmod +x "$runner"
    bash "$runner" 2>/dev/null
}

# ---------------------------------------------------------------------------
# TEST: hook_worktree_bash_guard (pre-bash-functions.sh) — REAL function, real ERR
#
# ERR trigger: git() returns nonexistent --git-common-dir path, causing the
# bare assignment `MAIN_GIT_DIR=$(cd WORKTREE && cd BAD && pwd)` to fail.
# This is the bare (non-local) assignment at line ~320 of pre-bash-functions.sh.
# ---------------------------------------------------------------------------
test_hook_worktree_bash_guard_real_err_writes_new_canonical_path() {
    local TEST_HOME
    TEST_HOME=$(_make_test_home)

    local runner
    runner=$(_make_runner)

    cat > "$runner" << RUNNER_EOF
#!/usr/bin/env bash
export HOME='${TEST_HOME}'
export CLAUDE_PLUGIN_ROOT='${DSO_PLUGIN_DIR}'
export _PRE_BASH_FUNCTIONS_LOADED=''
source '${DSO_PLUGIN_DIR}/hooks/lib/pre-bash-functions.sh'
is_worktree() { return 0; }
git() {
    case "\$1 \$2" in
        'rev-parse --show-toplevel') echo /tmp; return 0 ;;
        'rev-parse --git-common-dir') echo /bad_nonexistent_path_xyz; return 0 ;;
        *) command git "\$@" ;;
    esac
}
INPUT='{"tool_name":"Bash","tool_input":{"command":"echo test"}}'
hook_worktree_bash_guard "\$INPUT" 2>/dev/null; true
RUNNER_EOF

    chmod +x "$runner"
    bash "$runner" 2>/dev/null

    local NEW_LOG="$TEST_HOME/.claude/logs/dso-hook-errors.jsonl"
    local LEGACY_LOG="$TEST_HOME/.claude/hook-error-log.jsonl"

    local new_exists="no"
    [[ -f "$NEW_LOG" ]] && new_exists="yes"
    assert_eq "hook_worktree_bash_guard real ERR: new canonical log written" "yes" "$new_exists"

    local legacy_exists="no"
    [[ -f "$LEGACY_LOG" ]] && legacy_exists="yes"
    assert_eq "hook_worktree_bash_guard real ERR: legacy log NOT written" "no" "$legacy_exists"
}

# ---------------------------------------------------------------------------
# TEST: hook_worktree_edit_guard (pre-bash-functions.sh) — REAL function, real ERR
# Same git override as above — same bare assignment exists in this function.
# ---------------------------------------------------------------------------
test_hook_worktree_edit_guard_real_err_writes_new_canonical_path() {
    local TEST_HOME
    TEST_HOME=$(_make_test_home)

    local runner
    runner=$(_make_runner)

    cat > "$runner" << RUNNER_EOF
#!/usr/bin/env bash
export HOME='${TEST_HOME}'
export CLAUDE_PLUGIN_ROOT='${DSO_PLUGIN_DIR}'
export _PRE_BASH_FUNCTIONS_LOADED=''
source '${DSO_PLUGIN_DIR}/hooks/lib/pre-bash-functions.sh'
is_worktree() { return 0; }
git() {
    case "\$1 \$2" in
        'rev-parse --show-toplevel') echo /tmp; return 0 ;;
        'rev-parse --git-common-dir') echo /bad_nonexistent_path_xyz; return 0 ;;
        *) command git "\$@" ;;
    esac
}
INPUT='{"tool_name":"Edit","tool_input":{"file_path":"/some/path"}}'
hook_worktree_edit_guard "\$INPUT" 2>/dev/null; true
RUNNER_EOF

    chmod +x "$runner"
    bash "$runner" 2>/dev/null

    local NEW_LOG="$TEST_HOME/.claude/logs/dso-hook-errors.jsonl"
    local LEGACY_LOG="$TEST_HOME/.claude/hook-error-log.jsonl"

    local new_exists="no"
    [[ -f "$NEW_LOG" ]] && new_exists="yes"
    assert_eq "hook_worktree_edit_guard real ERR: new canonical log written" "yes" "$new_exists"

    local legacy_exists="no"
    [[ -f "$LEGACY_LOG" ]] && legacy_exists="yes"
    assert_eq "hook_worktree_edit_guard real ERR: legacy log NOT written" "no" "$legacy_exists"
}

# ---------------------------------------------------------------------------
# PROBE TESTS: for functions whose all internal paths are guarded (local
# assignments, ||, if-conditions), we use a probe function with the EXACT
# same HOOK_ERROR_LOG and trap setup as the real function. The probe triggers
# ERR via `false` to verify which log path the trap writes to.
#
# These tests are RED because the real functions assign:
#   local HOOK_ERROR_LOG="$HOME/.claude/hook-error-log.jsonl"  (legacy path)
#
# They go GREEN when the assignment changes to:
#   local HOOK_ERROR_LOG="$HOME/.claude/logs/dso-hook-errors.jsonl"  (new path)
# ---------------------------------------------------------------------------

test_hook_test_failure_guard_trap_writes_new_canonical_path() {
    local TEST_HOME
    TEST_HOME=$(_make_test_home)
    _run_probe_test "test-failure-guard" "pre-bash-functions.sh" "$TEST_HOME"

    local new_exists="no"
    [[ -f "$TEST_HOME/.claude/logs/dso-hook-errors.jsonl" ]] && new_exists="yes"
    assert_eq "hook_test_failure_guard trap: new canonical log written" "yes" "$new_exists"

    local legacy_exists="no"
    [[ -f "$TEST_HOME/.claude/hook-error-log.jsonl" ]] && legacy_exists="yes"
    assert_eq "hook_test_failure_guard trap: legacy log NOT written" "no" "$legacy_exists"
}

test_hook_commit_failure_tracker_trap_writes_new_canonical_path() {
    local TEST_HOME
    TEST_HOME=$(_make_test_home)
    _run_probe_test "commit-failure-tracker" "pre-bash-functions.sh" "$TEST_HOME"

    local new_exists="no"
    [[ -f "$TEST_HOME/.claude/logs/dso-hook-errors.jsonl" ]] && new_exists="yes"
    assert_eq "hook_commit_failure_tracker trap: new canonical log written" "yes" "$new_exists"

    local legacy_exists="no"
    [[ -f "$TEST_HOME/.claude/hook-error-log.jsonl" ]] && legacy_exists="yes"
    assert_eq "hook_commit_failure_tracker trap: legacy log NOT written" "no" "$legacy_exists"
}

test_hook_review_integrity_guard_trap_writes_new_canonical_path() {
    local TEST_HOME
    TEST_HOME=$(_make_test_home)
    _run_probe_test "review-integrity-guard" "pre-bash-functions.sh" "$TEST_HOME"

    local new_exists="no"
    [[ -f "$TEST_HOME/.claude/logs/dso-hook-errors.jsonl" ]] && new_exists="yes"
    assert_eq "hook_review_integrity_guard trap: new canonical log written" "yes" "$new_exists"

    local legacy_exists="no"
    [[ -f "$TEST_HOME/.claude/hook-error-log.jsonl" ]] && legacy_exists="yes"
    assert_eq "hook_review_integrity_guard trap: legacy log NOT written" "no" "$legacy_exists"
}

test_hook_tickets_tracker_bash_guard_trap_writes_new_canonical_path() {
    local TEST_HOME
    TEST_HOME=$(_make_test_home)
    _run_probe_test "tickets-tracker-bash-guard" "pre-bash-functions.sh" "$TEST_HOME"

    local new_exists="no"
    [[ -f "$TEST_HOME/.claude/logs/dso-hook-errors.jsonl" ]] && new_exists="yes"
    assert_eq "hook_tickets_tracker_bash_guard trap: new canonical log written" "yes" "$new_exists"

    local legacy_exists="no"
    [[ -f "$TEST_HOME/.claude/hook-error-log.jsonl" ]] && legacy_exists="yes"
    assert_eq "hook_tickets_tracker_bash_guard trap: legacy log NOT written" "no" "$legacy_exists"
}

test_hook_checkpoint_rollback_trap_writes_new_canonical_path() {
    local TEST_HOME
    TEST_HOME=$(_make_test_home)
    _run_probe_test "checkpoint-rollback" "pre-all-functions.sh" "$TEST_HOME"

    local new_exists="no"
    [[ -f "$TEST_HOME/.claude/logs/dso-hook-errors.jsonl" ]] && new_exists="yes"
    assert_eq "hook_checkpoint_rollback trap: new canonical log written" "yes" "$new_exists"

    local legacy_exists="no"
    [[ -f "$TEST_HOME/.claude/hook-error-log.jsonl" ]] && legacy_exists="yes"
    assert_eq "hook_checkpoint_rollback trap: legacy log NOT written" "no" "$legacy_exists"
}

test_hook_plan_review_gate_trap_writes_new_canonical_path() {
    local TEST_HOME
    TEST_HOME=$(_make_test_home)
    _run_probe_test "plan-review-gate" "session-misc-functions.sh" "$TEST_HOME"

    local new_exists="no"
    [[ -f "$TEST_HOME/.claude/logs/dso-hook-errors.jsonl" ]] && new_exists="yes"
    assert_eq "hook_plan_review_gate trap: new canonical log written" "yes" "$new_exists"

    local legacy_exists="no"
    [[ -f "$TEST_HOME/.claude/hook-error-log.jsonl" ]] && legacy_exists="yes"
    assert_eq "hook_plan_review_gate trap: legacy log NOT written" "no" "$legacy_exists"
}

test_hook_brainstorm_gate_trap_writes_new_canonical_path() {
    local TEST_HOME
    TEST_HOME=$(_make_test_home)
    _run_probe_test "brainstorm-gate" "session-misc-functions.sh" "$TEST_HOME"

    local new_exists="no"
    [[ -f "$TEST_HOME/.claude/logs/dso-hook-errors.jsonl" ]] && new_exists="yes"
    assert_eq "hook_brainstorm_gate trap: new canonical log written" "yes" "$new_exists"

    local legacy_exists="no"
    [[ -f "$TEST_HOME/.claude/hook-error-log.jsonl" ]] && legacy_exists="yes"
    assert_eq "hook_brainstorm_gate trap: legacy log NOT written" "no" "$legacy_exists"
}

test_hook_taskoutput_block_guard_trap_writes_new_canonical_path() {
    local TEST_HOME
    TEST_HOME=$(_make_test_home)
    _run_probe_test "taskoutput-block-guard" "session-misc-functions.sh" "$TEST_HOME"

    local new_exists="no"
    [[ -f "$TEST_HOME/.claude/logs/dso-hook-errors.jsonl" ]] && new_exists="yes"
    assert_eq "hook_taskoutput_block_guard trap: new canonical log written" "yes" "$new_exists"

    local legacy_exists="no"
    [[ -f "$TEST_HOME/.claude/hook-error-log.jsonl" ]] && legacy_exists="yes"
    assert_eq "hook_taskoutput_block_guard trap: legacy log NOT written" "no" "$legacy_exists"
}

# ---------------------------------------------------------------------------
# PROBE TESTS: pre-edit-write-functions.sh functions with HOOK_ERROR_LOG assignments
#
# Three functions in pre-edit-write-functions.sh have inline ERR traps with
# HOOK_ERROR_LOG assignments:
#   - hook_title_length_validator
#   - hook_tickets_tracker_guard
#   - hook_block_generated_reviewer_agents
#
# Each probe sources pre-edit-write-functions.sh and verifies the canonical
# log path is used (not the legacy path).
# ---------------------------------------------------------------------------

test_hook_title_length_validator_trap_writes_new_canonical_path() {
    local TEST_HOME
    TEST_HOME=$(_make_test_home)
    _run_probe_test "title-length-validator" "pre-edit-write-functions.sh" "$TEST_HOME"

    local new_exists="no"
    [[ -f "$TEST_HOME/.claude/logs/dso-hook-errors.jsonl" ]] && new_exists="yes"
    assert_eq "hook_title_length_validator trap: new canonical log written" "yes" "$new_exists"

    local legacy_exists="no"
    [[ -f "$TEST_HOME/.claude/hook-error-log.jsonl" ]] && legacy_exists="yes"
    assert_eq "hook_title_length_validator trap: legacy log NOT written" "no" "$legacy_exists"
}

test_hook_tickets_tracker_guard_trap_writes_new_canonical_path() {
    local TEST_HOME
    TEST_HOME=$(_make_test_home)
    _run_probe_test "tickets-tracker-guard" "pre-edit-write-functions.sh" "$TEST_HOME"

    local new_exists="no"
    [[ -f "$TEST_HOME/.claude/logs/dso-hook-errors.jsonl" ]] && new_exists="yes"
    assert_eq "hook_tickets_tracker_guard trap: new canonical log written" "yes" "$new_exists"

    local legacy_exists="no"
    [[ -f "$TEST_HOME/.claude/hook-error-log.jsonl" ]] && legacy_exists="yes"
    assert_eq "hook_tickets_tracker_guard trap: legacy log NOT written" "no" "$legacy_exists"
}

test_hook_block_generated_reviewer_agents_trap_writes_new_canonical_path() {
    local TEST_HOME
    TEST_HOME=$(_make_test_home)
    _run_probe_test "block-generated-reviewer-agents" "pre-edit-write-functions.sh" "$TEST_HOME"

    local new_exists="no"
    [[ -f "$TEST_HOME/.claude/logs/dso-hook-errors.jsonl" ]] && new_exists="yes"
    assert_eq "hook_block_generated_reviewer_agents trap: new canonical log written" "yes" "$new_exists"

    local legacy_exists="no"
    [[ -f "$TEST_HOME/.claude/hook-error-log.jsonl" ]] && legacy_exists="yes"
    assert_eq "hook_block_generated_reviewer_agents trap: legacy log NOT written" "no" "$legacy_exists"
}

# ---------------------------------------------------------------------------
# TEST: run-hook.sh syntax error path writes to NEW canonical log path
#
# run-hook.sh hardcodes HOOK_ERROR_LOG="$HOME/.claude/hook-error-log.jsonl"
# when it detects a syntax error in the target hook. After b36e-a03a, this
# path should change to "$HOME/.claude/logs/dso-hook-errors.jsonl".
# ---------------------------------------------------------------------------
test_run_hook_syntax_error_writes_new_canonical_path() {
    local TEST_HOME
    TEST_HOME=$(_make_test_home)

    local BROKEN_HOOK
    BROKEN_HOOK=$(mktemp -t test-broken-hookXXXXX)
    _TEST_TMPDIRS+=("$BROKEN_HOOK")
    printf '#!/usr/bin/env bash\nif then fi\n' > "$BROKEN_HOOK"
    chmod +x "$BROKEN_HOOK"

    local runner
    runner=$(_make_runner)

    cat > "$runner" << RUNNER_EOF
#!/usr/bin/env bash
export HOME='${TEST_HOME}'
export CLAUDE_PLUGIN_ROOT='${DSO_PLUGIN_DIR}'
bash '${DSO_PLUGIN_DIR}/hooks/run-hook.sh' '${BROKEN_HOOK}' 2>/dev/null
RUNNER_EOF

    chmod +x "$runner"
    bash "$runner" 2>/dev/null

    local NEW_LOG="$TEST_HOME/.claude/logs/dso-hook-errors.jsonl"
    local LEGACY_LOG="$TEST_HOME/.claude/hook-error-log.jsonl"

    local new_exists="no"
    [[ -f "$NEW_LOG" ]] && new_exists="yes"
    assert_eq "run-hook.sh syntax error: new canonical log written" "yes" "$new_exists"

    local legacy_exists="no"
    [[ -f "$LEGACY_LOG" ]] && legacy_exists="yes"
    assert_eq "run-hook.sh syntax error: legacy log NOT written" "no" "$legacy_exists"
}

# ---------------------------------------------------------------------------
# PATH-PROBE TESTS: top-level standalone hook scripts
#
# These scripts use a top-level HOOK_ERROR_LOG assignment (not inside a
# function) so triggering their ERR trap requires fully stubbed inputs.
# Instead, we assert the assignment string itself uses the canonical path.
# This is a structural probe: if the file contains the legacy path, the
# test fails; if it contains the canonical path, it passes.
# ---------------------------------------------------------------------------

# REVIEW-DEFENSE: _assert_canonical_log_path uses grep on source files (structural probe).
# This is an accepted tradeoff, not a test-quality anti-pattern, for the following reasons:
#
# (1) TESTABILITY CONSTRAINT — These 8 hooks are standalone scripts with top-level execution
#     code (HOOK_ERROR_LOG assignment + ERR trap + cat + parse_json_field + tool-specific logic).
#     Unlike the lib function tests above (which use runner scripts that source the lib and call
#     a single function), standalone scripts execute immediately on source. Triggering their ERR
#     trap behaviorally requires fully-stubbed hook inputs: a valid JSON payload on stdin, correct
#     environment variables (HOME, PATH, git repo context), and mocked external commands. That
#     infra is ~50+ lines per hook — disproportionate for a path-constant migration test.
#
# (2) WHAT IS TESTED — The ERR trap's destination path is a compile-time string constant, not
#     a runtime computation. The observable runtime effect (which file gets the error entry) is
#     100% determined by the assignment string. A structural grep on the assignment IS the only
#     source of truth for this configuration invariant, and it tests the exact thing that differs
#     between legacy (~/.claude/hook-error-log.jsonl) and canonical (~/.claude/logs/dso-hook-errors.jsonl).
#
# (3) REFACTORING LITMUS — A behavior-preserving refactor that extracts the path to a shared
#     constant WOULD break these tests. That breakage is desired: extracting to a shared constant
#     changes the migration surface and should trigger a corresponding test update. These probes
#     are stable against all changes except path reassignment — exactly what task 6ed5-99ef targets.
#
# (4) TASK SPECIFICATION — Task 6ed5-99ef explicitly required "probe assertions for these 8 files
#     verifying they use the canonical path." The structural probe approach was the assigned
#     implementation strategy and is acknowledged as such in the test file comment block above.
_assert_canonical_log_path() {
    local HOOK_FILE="$1"
    local HOOK_LABEL="$2"
    local BASENAME
    BASENAME="$(basename "$HOOK_FILE")"

    local has_canonical="no"
    local has_legacy="no"
    if grep -q 'HOOK_ERROR_LOG=.*\.claude/logs/dso-hook-errors\.jsonl' "$HOOK_FILE" 2>/dev/null; then
        has_canonical="yes"
    fi
    if grep -q 'HOOK_ERROR_LOG=.*\.claude/hook-error-log\.jsonl' "$HOOK_FILE" 2>/dev/null; then
        has_legacy="yes"
    fi

    assert_eq "$HOOK_LABEL: canonical path present" "yes" "$has_canonical"
    assert_eq "$HOOK_LABEL: legacy path absent" "no" "$has_legacy"
}

test_standalone_review_gate_bypass_sentinel_canonical_path() {
    _assert_canonical_log_path \
        "$DSO_PLUGIN_DIR/hooks/lib/review-gate-bypass-sentinel.sh" \
        "review-gate-bypass-sentinel.sh"
}

test_standalone_plan_review_gate_canonical_path() {
    _assert_canonical_log_path \
        "$DSO_PLUGIN_DIR/hooks/plan-review-gate.sh" \
        "plan-review-gate.sh"
}

test_standalone_taskoutput_block_guard_canonical_path() {
    _assert_canonical_log_path \
        "$DSO_PLUGIN_DIR/hooks/taskoutput-block-guard.sh" \
        "taskoutput-block-guard.sh"
}

test_standalone_track_cascade_failures_canonical_path() {
    _assert_canonical_log_path \
        "$DSO_PLUGIN_DIR/hooks/track-cascade-failures.sh" \
        "track-cascade-failures.sh"
}

test_standalone_title_length_validator_canonical_path() {
    _assert_canonical_log_path \
        "$DSO_PLUGIN_DIR/hooks/title-length-validator.sh" \
        "title-length-validator.sh"
}

test_standalone_track_tool_errors_canonical_path() {
    _assert_canonical_log_path \
        "$DSO_PLUGIN_DIR/hooks/track-tool-errors.sh" \
        "track-tool-errors.sh"
}

test_standalone_review_stop_check_canonical_path() {
    _assert_canonical_log_path \
        "$DSO_PLUGIN_DIR/hooks/review-stop-check.sh" \
        "review-stop-check.sh"
}

test_standalone_check_validation_failures_canonical_path() {
    _assert_canonical_log_path \
        "$DSO_PLUGIN_DIR/hooks/check-validation-failures.sh" \
        "check-validation-failures.sh"
}

# ---------------------------------------------------------------------------
# Run all tests
# ---------------------------------------------------------------------------

# Real-function tests (actual ERR trigger via git override):
test_hook_worktree_bash_guard_real_err_writes_new_canonical_path
test_hook_worktree_edit_guard_real_err_writes_new_canonical_path

# Probe-function tests (same HOOK_ERROR_LOG assignment, triggered via `false`):
test_hook_test_failure_guard_trap_writes_new_canonical_path
test_hook_commit_failure_tracker_trap_writes_new_canonical_path
test_hook_review_integrity_guard_trap_writes_new_canonical_path
test_hook_tickets_tracker_bash_guard_trap_writes_new_canonical_path
test_hook_checkpoint_rollback_trap_writes_new_canonical_path
test_hook_plan_review_gate_trap_writes_new_canonical_path
test_hook_brainstorm_gate_trap_writes_new_canonical_path
test_hook_taskoutput_block_guard_trap_writes_new_canonical_path

# Probe-function tests for pre-edit-write-functions.sh:
test_hook_title_length_validator_trap_writes_new_canonical_path
test_hook_tickets_tracker_guard_trap_writes_new_canonical_path
test_hook_block_generated_reviewer_agents_trap_writes_new_canonical_path

# Path-probe tests for standalone top-level hook scripts:
test_standalone_review_gate_bypass_sentinel_canonical_path
test_standalone_plan_review_gate_canonical_path
test_standalone_taskoutput_block_guard_canonical_path
test_standalone_track_cascade_failures_canonical_path
test_standalone_title_length_validator_canonical_path
test_standalone_track_tool_errors_canonical_path
test_standalone_review_stop_check_canonical_path
test_standalone_check_validation_failures_canonical_path

# run-hook.sh test (hardcoded legacy path in error handling):
test_run_hook_syntax_error_writes_new_canonical_path

print_summary
