#!/usr/bin/env bash
# run-hermetic.sh
#
# Hermetic isolation runner for RED tests.
#
# Inputs (via environment):
#   TEST_CMD  — the resolved test command (e.g. "bash /path/to/test.sh")
#
# Shell-ness determination:
#   shell iff: test file has .sh suffix OR resolved $TEST_CMD runner starts
#              with "bash" or "sh"
#
# For shell tests:
#   Run under hermetic isolation:
#     env -u CLAUDE_PLUGIN_ROOT bash -c 'unset "${!BASH_FUNC_@}" 2>/dev/null; <TEST_CMD>'
#   preserving PATH and venv.
#   Exit 0 (with "reproduce" token in output) if the test reproduces (exits 0).
#   Exit non-zero if the test does NOT reproduce — caller uses this to trigger
#   HARD-GATE full stop.
#
# For non-shell tests:
#   Emit exactly: HERMETIC_SKIP: runner=<runner> reason=non-shell
#   Exit 0 (never blocked).
#
# Usage: TEST_CMD="<runner> <test-path>" bash run-hermetic.sh

set -uo pipefail

# ── Validate input ────────────────────────────────────────────────────────────

if [[ -z "${TEST_CMD:-}" ]]; then
    echo "ERROR: TEST_CMD is not set" >&2
    exit 2
fi

# ── Extract runner and test path from TEST_CMD ────────────────────────────────

# Runner is the first word of TEST_CMD
runner="${TEST_CMD%% *}"
runner_basename="$(basename "$runner")"

# The test path is the last word in TEST_CMD (the actual script/file)
read -ra _cmd_parts <<< "$TEST_CMD"
_test_path="${_cmd_parts[-1]}"

# ── Determine shell-ness ──────────────────────────────────────────────────────

_is_shell=0

# Rule 1: test path has .sh suffix
if [[ "$_test_path" == *.sh ]]; then
    _is_shell=1
fi

# Rule 2: runner starts with "bash" or "sh"
if [[ "$runner_basename" == bash* ]] || [[ "$runner_basename" == sh* ]]; then
    _is_shell=1
fi

# ── Non-shell path ────────────────────────────────────────────────────────────

if [[ "$_is_shell" -eq 0 ]]; then
    echo "HERMETIC_SKIP: runner=$runner_basename reason=non-shell"
    exit 0
fi

# ── Shell path: run hermetically ──────────────────────────────────────────────

# Run the test under hermetic isolation:
#   - unset CLAUDE_PLUGIN_ROOT
#   - unset exported bash functions
#   - preserve PATH and venv
hermetic_exit=0
# SC2016: the single-quoted ${!BASH_FUNC_@} is intentional — it must expand inside
# the inner hermetic bash (to clear inherited exported functions), not the outer shell.
# shellcheck disable=SC2016
env -u CLAUDE_PLUGIN_ROOT bash -c 'unset "${!BASH_FUNC_@}" 2>/dev/null; '"$TEST_CMD" || hermetic_exit=$?

if [[ "$hermetic_exit" -eq 0 ]]; then
    echo "hermetic reproduce: test reproduced under isolation (exit 0)"
    exit 0
else
    echo "hermetic reproduce: FAILED — test did not reproduce under isolation (exit $hermetic_exit)" >&2
    exit "$hermetic_exit"
fi
