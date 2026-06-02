#!/usr/bin/env bash
# tests/scripts/test-run-hermetic.sh
# RED-phase tests for plugins/dso/scripts/run-hermetic.sh
#
# Behaviors under test:
#   T1. shell test (.sh suffix) that reproduces under hermetic isolation → exit 0
#       with "reproduce" token in output
#   T2. shell test (.sh suffix) that does NOT reproduce → exit non-zero
#       (caller can trigger HARD-GATE full stop)
#   T3. non-shell test (runner is not bash|sh AND no .sh suffix) → emits
#       "HERMETIC_SKIP: runner=<runner> reason=non-shell" and exits 0
#   T4. shell-ness via bash runner (no .sh suffix but TEST_CMD runner = bash) →
#       treated as shell, reproduce path works
#   T5. sh runner (no .sh suffix) → also treated as shell
#
# Shell-ness determination rule:
#   shell iff: file has .sh suffix OR resolved $TEST_CMD runner starts with bash|sh
#
# Hermetic recipe (mental model for fixture construction):
#   env -u CLAUDE_PLUGIN_ROOT bash -c 'unset "${!BASH_FUNC_@}" 2>/dev/null; <test command>'
#   preserving PATH and venv.
#
# Usage: bash tests/scripts/test-run-hermetic.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

# NOTE: -e is intentionally omitted — test functions return non-zero by design
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
HELPER="$REPO_ROOT/plugins/dso/scripts/run-hermetic.sh"

source "$REPO_ROOT/tests/lib/assert.sh"

# Global cleanup registry
declare -a _TEST_TMPDIRS=()
trap 'rm -rf "${_TEST_TMPDIRS[@]:-}"' EXIT

_make_tmpdir() {
    local d
    d=$(mktemp -d "${TMPDIR:-/tmp}/test-run-hermetic.XXXXXX")
    _TEST_TMPDIRS+=("$d")
    echo "$d"
}

echo "=== test-run-hermetic.sh ==="
echo ""

# ── Pre-flight: helper must exist ─────────────────────────────────────────────
# All tests depend on the helper. If it is absent (RED phase), we emit a
# clear failure and exit immediately rather than producing confusing cascades.
if [[ ! -f "$HELPER" ]]; then
    echo "FAIL: plugins/dso/scripts/run-hermetic.sh does not exist — RED phase expected" >&2
    (( ++FAIL ))
    print_summary
fi

# ── T1: shell test (.sh suffix) that REPRODUCES → exit 0 with "reproduce" token ─

test_shell_sh_suffix_that_reproduces_exits_0() {
    local tmpdir
    tmpdir="$(_make_tmpdir)"

    # Fixture: a .sh test that always exits 0 (it "reproduces" the bug under test
    # by completing successfully). The helper should classify this as a shell test
    # (via .sh suffix) and, after running it hermetically, report reproduction.
    local test_script="$tmpdir/repro-test.sh"
    cat > "$test_script" <<'FIXTURE'
#!/usr/bin/env bash
# Minimal reproducer: always succeeds (bug reproduces)
exit 0
FIXTURE
    chmod +x "$test_script"

    local output exit_code=0
    output=$(TEST_CMD="bash $test_script" bash "$HELPER" 2>&1) || exit_code=$?

    assert_eq \
        "T1: shell .sh reproducer exits 0" \
        "0" \
        "$exit_code"
    assert_contains \
        "T1: output contains 'reproduce' token confirming hermetic reproduction" \
        "reproduce" \
        "$output"
}

# ── T2: shell test (.sh suffix) that does NOT reproduce → exit non-zero ───────

test_shell_sh_suffix_non_reproduce_exits_nonzero() {
    local tmpdir
    tmpdir="$(_make_tmpdir)"

    # Fixture: a .sh test that always exits non-zero (does not reproduce).
    # The helper should classify via .sh suffix, run hermetically, observe
    # failure, and itself exit non-zero so the caller can trigger a HARD-GATE.
    local test_script="$tmpdir/no-repro-test.sh"
    cat > "$test_script" <<'FIXTURE'
#!/usr/bin/env bash
# Non-reproducer: always fails (bug does not reproduce under isolation)
exit 1
FIXTURE
    chmod +x "$test_script"

    local exit_code=0
    TEST_CMD="bash $test_script" bash "$HELPER" >/dev/null 2>&1 || exit_code=$?

    assert_ne \
        "T2: non-reproducing shell .sh test causes helper to exit non-zero (HARD-GATE signal)" \
        "0" \
        "$exit_code"
}

# ── T3: non-shell test → HERMETIC_SKIP emitted, exits 0 ──────────────────────

test_non_shell_runner_emits_hermetic_skip_and_exits_0() {
    local tmpdir
    tmpdir="$(_make_tmpdir)"

    # Fixture: a .py test file; runner is "pytest" (not bash|sh, no .sh suffix).
    # The helper must emit HERMETIC_SKIP: runner=pytest reason=non-shell
    # and exit 0 without running the test.
    local test_file="$tmpdir/test_something.py"
    cat > "$test_file" <<'FIXTURE'
def test_example():
    assert True
FIXTURE

    local output exit_code=0
    output=$(TEST_CMD="pytest $test_file" bash "$HELPER" 2>&1) || exit_code=$?

    assert_eq \
        "T3: non-shell runner exits 0 (never blocked)" \
        "0" \
        "$exit_code"
    assert_contains \
        "T3: output contains HERMETIC_SKIP token" \
        "HERMETIC_SKIP" \
        "$output"
    assert_contains \
        "T3: HERMETIC_SKIP includes runner=pytest" \
        "runner=pytest" \
        "$output"
    assert_contains \
        "T3: HERMETIC_SKIP includes reason=non-shell" \
        "reason=non-shell" \
        "$output"
}

# ── T4: shell-ness via bash runner (no .sh suffix) → treated as shell ────────

test_bash_runner_no_sh_suffix_treated_as_shell() {
    local tmpdir
    tmpdir="$(_make_tmpdir)"

    # Fixture: test file named without .sh suffix but TEST_CMD runner starts
    # with "bash". Shell-ness rule: runner starts with bash|sh → shell test.
    # Should run hermetically and reproduce (exit 0 with "reproduce" token).
    local test_script="$tmpdir/reproducer"
    cat > "$test_script" <<'FIXTURE'
#!/usr/bin/env bash
exit 0
FIXTURE
    chmod +x "$test_script"

    local output exit_code=0
    output=$(TEST_CMD="bash $test_script" bash "$HELPER" 2>&1) || exit_code=$?

    assert_eq \
        "T4: bash runner (no .sh suffix) exits 0 on reproduction" \
        "0" \
        "$exit_code"
    assert_contains \
        "T4: bash runner treated as shell — output contains reproduce token" \
        "reproduce" \
        "$output"
}

# ── T5: sh runner (no .sh suffix) → also treated as shell ────────────────────

test_sh_runner_no_sh_suffix_treated_as_shell() {
    local tmpdir
    tmpdir="$(_make_tmpdir)"

    # Fixture: runner is "sh" (starts with sh → shell test); file has no .sh suffix.
    # Non-reproducing: exits 1. Helper must exit non-zero.
    local test_script="$tmpdir/nonrepro"
    cat > "$test_script" <<'FIXTURE'
#!/bin/sh
exit 1
FIXTURE
    chmod +x "$test_script"

    local exit_code=0
    TEST_CMD="sh $test_script" bash "$HELPER" >/dev/null 2>&1 || exit_code=$?

    assert_ne \
        "T5: sh runner (no .sh suffix) treated as shell — exits non-zero on non-reproduce" \
        "0" \
        "$exit_code"
}

# ── Run all tests ─────────────────────────────────────────────────────────────

test_shell_sh_suffix_that_reproduces_exits_0
test_shell_sh_suffix_non_reproduce_exits_nonzero
test_non_shell_runner_emits_hermetic_skip_and_exits_0
test_bash_runner_no_sh_suffix_treated_as_shell
test_sh_runner_no_sh_suffix_treated_as_shell

print_summary
