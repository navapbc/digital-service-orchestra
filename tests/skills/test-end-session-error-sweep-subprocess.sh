#!/usr/bin/env bash
# shellcheck disable=SC2030,SC2031
# tests/skills/test-end-session-error-sweep-subprocess.sh
# Behavioral RED tests for the CLI subcommand dispatch block in error-sweep.sh.
#
# Bug 0584-b545: error-sweep.sh uses [[ =~ ]] with a capture group that fails
# under zsh --emulate sh. The fix (Approach C) adds a CLI dispatch block so the
# script can be invoked as a subprocess:
#   bash error-sweep.sh sweep-tool-errors
#   bash error-sweep.sh sweep-validation-failures
#
# These tests assert observable subprocess behavior (exit code + ticket-CLI
# invocation side-effects) and verify the fix works inside zsh --emulate sh.
# Tests fail in RED (no dispatch block exists) and pass in GREEN (block added).
#
# Usage: bash tests/skills/test-end-session-error-sweep-subprocess.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR" && git rev-parse --show-toplevel)"
ERROR_SWEEP="$REPO_ROOT/plugins/dso/scripts/end-session/error-sweep.sh"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-end-session-error-sweep-subprocess.sh ==="

# ---------------------------------------------------------------------------
# Shared helpers
# ---------------------------------------------------------------------------

_TMPDIRS=()
_cleanup_all() {
    for d in "${_TMPDIRS[@]+"${_TMPDIRS[@]}"}"; do
        [[ -d "$d" ]] && rm -rf "$d"
    done
}
trap '_cleanup_all' EXIT

_make_tmpdir() {
    local d
    d=$(mktemp -d)
    _TMPDIRS+=("$d")
    echo "$d"
}

# _make_env: creates an isolated home dir, fake ticket CLI, and required dirs.
# Echoes: "<tmpdir>:<fake_ticket_path>:<tk_log_path>"
_make_env() {
    local tmpdir
    tmpdir=$(_make_tmpdir)
    local fake_tk="$tmpdir/bin/fake-ticket"
    local tk_log="$tmpdir/tk.log"
    mkdir -p "$tmpdir/bin" "$tmpdir/.claude"

    # Fake ticket CLI: record all invocations to tk.log, print a stub ID on "create"
    cat > "$fake_tk" <<EOF
#!/usr/bin/env bash
echo "\$@" >> "${tk_log}"
if [ "\$1" = "create" ]; then
    echo "stub-id-001"
fi
exit 0
EOF
    chmod +x "$fake_tk"
    echo "${tmpdir}:${fake_tk}:${tk_log}"
}

# ---------------------------------------------------------------------------
# Test 1: sweep-tool-errors subprocess — function executes and creates ticket
# ---------------------------------------------------------------------------
test_sweep_tool_errors_subprocess_invokes_function() {
    local env_info tmpdir fake_tk tk_log
    env_info=$(_make_env)
    tmpdir="${env_info%%:*}"; env_info="${env_info#*:}"
    fake_tk="${env_info%%:*}"; tk_log="${env_info#*:}"

    # Stub read-config.sh to return "true" (monitoring enabled)
    local fake_read_config="$tmpdir/bin/read-config.sh"
    cat > "$fake_read_config" <<'EOF'
#!/usr/bin/env bash
echo "true"
EOF
    chmod +x "$fake_read_config"

    # Counter file with one category above THRESHOLD (500)
    mkdir -p "$tmpdir/.claude"
    cat > "$tmpdir/.claude/tool-error-counter.json" <<'EOF'
{"index": {"subprocess_test_category": 500}, "errors": []}
EOF

    # Invoke the script as a subprocess with the new CLI subcommand.
    # In RED state: no dispatch block exists, so the function never runs.
    # In GREEN state: dispatch block calls sweep_tool_errors(), which hits TICKET_CMD.
    local exit_code
    TICKET_CMD="$fake_tk" \
    HOME="$tmpdir" \
        bash "$ERROR_SWEEP" sweep-tool-errors
    exit_code=$?

    assert_eq "sweep-tool-errors subprocess exits 0" "0" "$exit_code"

    # The function must have run: ticket CLI should have been called with "create bug ..."
    local tk_log_content
    tk_log_content=$(cat "$tk_log" 2>/dev/null || echo "")

    assert_contains \
        "sweep-tool-errors subprocess: ticket create was called" \
        "create bug" \
        "$tk_log_content"
}

# ---------------------------------------------------------------------------
# Test 2: sweep-validation-failures subprocess — function executes and creates ticket
# ---------------------------------------------------------------------------
test_sweep_validation_failures_subprocess_invokes_function() {
    local env_info tmpdir fake_tk tk_log
    env_info=$(_make_env)
    tmpdir="${env_info%%:*}"; env_info="${env_info#*:}"
    fake_tk="${env_info%%:*}"; tk_log="${env_info#*:}"

    # Create validation failures log with one category entry
    local artifacts_dir="$tmpdir/artifacts"
    mkdir -p "$artifacts_dir"
    echo "subprocess_validation_category" > "$artifacts_dir/untracked-validation-failures.log"

    # Invoke as subprocess with the new CLI subcommand.
    # In RED state: no dispatch block, function never runs.
    # In GREEN state: dispatch block calls sweep_validation_failures().
    local exit_code
    TICKET_CMD="$fake_tk" \
    ARTIFACTS_DIR="$artifacts_dir" \
    HOME="$tmpdir" \
        bash "$ERROR_SWEEP" sweep-validation-failures
    exit_code=$?

    assert_eq "sweep-validation-failures subprocess exits 0" "0" "$exit_code"

    local tk_log_content
    tk_log_content=$(cat "$tk_log" 2>/dev/null || echo "")

    assert_contains \
        "sweep-validation-failures subprocess: ticket create was called" \
        "create bug" \
        "$tk_log_content"
}

# ---------------------------------------------------------------------------
# Test 3: zsh --emulate sh wrapper — sweep-tool-errors succeeds
# ---------------------------------------------------------------------------
test_sweep_tool_errors_works_under_zsh_emulate_sh() {
    # Verify zsh is available; skip with a recorded failure if not
    if ! command -v zsh >/dev/null 2>&1; then
        (( ++FAIL ))
        printf "FAIL: zsh --emulate sh wrapping test: zsh not available in PATH\n" >&2
        return
    fi

    local env_info tmpdir fake_tk tk_log
    env_info=$(_make_env)
    tmpdir="${env_info%%:*}"; env_info="${env_info#*:}"
    fake_tk="${env_info%%:*}"; tk_log="${env_info#*:}"

    mkdir -p "$tmpdir/.claude"
    cat > "$tmpdir/.claude/tool-error-counter.json" <<'EOF'
{"index": {"zsh_test_category": 500}, "errors": []}
EOF

    # zsh --emulate sh wraps the subprocess bash call exactly as the orchestrator does.
    # In RED state: the [[ =~ ]] capture group inside sweep_validation_failures() causes
    # an error under emulate-sh when the script is sourced. Even for sweep-tool-errors,
    # the script must parse without error under this shell context.
    # In GREEN state: subprocess dispatch avoids sourcing, so [[ =~ ]] is never evaluated
    # in the zsh context.
    local exit_code
    zsh --emulate sh -c \
        "TICKET_CMD='$fake_tk' HOME='$tmpdir' bash '$ERROR_SWEEP' sweep-tool-errors"
    exit_code=$?

    assert_eq \
        "sweep-tool-errors via zsh --emulate sh wrapper exits 0" \
        "0" \
        "$exit_code"
}

# ---------------------------------------------------------------------------
# Test 4: zsh --emulate sh wrapper — sweep-validation-failures succeeds
# ---------------------------------------------------------------------------
test_sweep_validation_failures_works_under_zsh_emulate_sh() {
    if ! command -v zsh >/dev/null 2>&1; then
        (( ++FAIL ))
        printf "FAIL: zsh --emulate sh wrapping test: zsh not available in PATH\n" >&2
        return
    fi

    local env_info tmpdir fake_tk tk_log
    env_info=$(_make_env)
    tmpdir="${env_info%%:*}"; env_info="${env_info#*:}"
    fake_tk="${env_info%%:*}"; tk_log="${env_info#*:}"

    local artifacts_dir="$tmpdir/artifacts"
    mkdir -p "$artifacts_dir"
    echo "2026-01-01T00:00:00 | UNTRACKED | zsh_validation_category | logfile: /tmp/x.log" \
        > "$artifacts_dir/untracked-validation-failures.log"

    # The critical regression: zsh --emulate sh sourcing error-sweep.sh triggers
    # the [[ =~ ]] capture-group parse failure, leaving sweep_validation_failures
    # undefined. The subprocess form (bash invocation) must bypass this entirely.
    local exit_code
    zsh --emulate sh -c \
        "TICKET_CMD='$fake_tk' ARTIFACTS_DIR='$artifacts_dir' HOME='$tmpdir' bash '$ERROR_SWEEP' sweep-validation-failures"
    exit_code=$?

    assert_eq \
        "sweep-validation-failures via zsh --emulate sh wrapper exits 0" \
        "0" \
        "$exit_code"
}

# ---------------------------------------------------------------------------
# Test 5: sourcing still works (backward compat — dispatch block must NOT run on source)
# ---------------------------------------------------------------------------
test_source_mode_does_not_trigger_dispatch() {
    local env_info tmpdir fake_tk tk_log
    env_info=$(_make_env)
    tmpdir="${env_info%%:*}"; env_info="${env_info#*:}"
    fake_tk="${env_info%%:*}"; tk_log="${env_info#*:}"

    # When sourced, the script must define the functions but NOT auto-execute them.
    # No TICKET_CMD call should appear in tk.log.
    local source_exit
    # shellcheck source=/dev/null
    (
        export TICKET_CMD="$fake_tk"
        export HOME="$tmpdir"
        # shellcheck disable=SC1090
        source "$ERROR_SWEEP"
        # Just source — do not call any function
    )
    source_exit=$?

    assert_eq "source mode exits 0" "0" "$source_exit"

    local tk_log_content
    tk_log_content=$(cat "$tk_log" 2>/dev/null || echo "")

    assert_eq \
        "source mode does not auto-invoke ticket CLI" \
        "" \
        "$tk_log_content"
}

# ---------------------------------------------------------------------------
# Run all tests
# ---------------------------------------------------------------------------
test_sweep_tool_errors_subprocess_invokes_function
test_sweep_validation_failures_subprocess_invokes_function
test_sweep_tool_errors_works_under_zsh_emulate_sh
test_sweep_validation_failures_works_under_zsh_emulate_sh
test_source_mode_does_not_trigger_dispatch

print_summary
