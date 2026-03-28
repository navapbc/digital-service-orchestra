#!/usr/bin/env bash
# tests/scripts/test-validate-e2e-missing-target.sh
# RED test for bug 62d3-7064: validate.sh --ci reports E2E FAIL instead of SKIP
# when the CMD_TEST_E2E make target does not exist in the project Makefile.
#
# Bug: validate.sh unconditionally runs CMD_TEST_E2E without first checking
# whether the target exists. When `make test-e2e` is invoked and no such
# target is present, make exits 2 — validate.sh treats this non-zero exit
# as a test FAIL instead of reporting SKIP.
#
# Tests:
#   test_e2e_skip_when_target_missing_ci_pending  -- SKIP (not FAIL) when make
#     target absent and CI is pending with no prior failure history
#
# Usage: bash tests/scripts/test-validate-e2e-missing-target.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

VALIDATE_SH="$DSO_PLUGIN_DIR/scripts/validate.sh"

echo "=== test-validate-e2e-missing-target.sh ==="

# jq is required by validate.sh's check_ci() for CI JSON parsing.
# Without jq, check_ci() exits early with ci.rc=skip, causing a different
# code path that does not exercise the E2E_AVAILABLE guard under test.
if ! command -v jq &>/dev/null; then
    echo "SKIP: jq not installed — this test requires jq to exercise check_ci() correctly"
    exit 0
fi

# ── Setup ────────────────────────────────────────────────────────────────────

_TEST_TMPDIRS=()
TMPDIR_TEST="$(mktemp -d)"
_TEST_TMPDIRS+=("$TMPDIR_TEST")
trap 'rm -rf "${_TEST_TMPDIRS[@]}"' EXIT

STUB_BIN="$TMPDIR_TEST/stub_bin"
mkdir -p "$STUB_BIN"

# Stub test-batched.sh — always succeeds immediately
STUB_TEST_BATCHED="$TMPDIR_TEST/test-batched.sh"
cat > "$STUB_TEST_BATCHED" << 'TBSTUB'
#!/usr/bin/env bash
exit 0
TBSTUB
chmod +x "$STUB_TEST_BATCHED"

# Stub gh — returns a pending run with NO previous completed runs.
# This causes check_ci() to produce:
#   ci.result  = in_progress:no_history
#   ci.rc      = 0   (CI_PASSED = 1)
#
# With CI_PASSED=1 the E2E block takes the SKIP branch (line 1082-1083),
# so we need a scenario that exercises the actual execution path.
#
# The execution path that triggers the bug is at line 1127-1155:
#   "CI still running/pending — run E2E locally"
# This path is reached when CI_PASSED=0 AND e2e_ci_result is NOT completed:*.
#
# To reach it:
#   - Latest run must be in_progress (pending), so ci.result = in_progress:*
#   - Previous run must have conclusion = "failure", triggering pending_with_failure
#     which sets ci.rc=1, leaving CI_PASSED=0.
#   - e2e_ci_result will be "in_progress:failure" — NOT completed:* — so the
#     code falls through to line 1127 and attempts to run $CMD_TEST_E2E.
#
# The gh stub returns two runs: latest is in_progress, previous is failure.
cat > "$STUB_BIN/gh" << 'GHSTUB'
#!/usr/bin/env bash
# Emit JSON with: latest run in_progress, previous run completed:failure
# check_ci() uses jq to parse this and will write pending_with_failure=true
printf '[
  {"status":"in_progress","conclusion":null,"databaseId":9001,"headSha":"aaa","createdAt":"2026-01-02T00:00:00Z"},
  {"status":"completed","conclusion":"failure","databaseId":9000,"headSha":"bbb","createdAt":"2026-01-01T00:00:00Z"}
]\n'
GHSTUB
chmod +x "$STUB_BIN/gh"

# Add a jq passthrough stub so validate.sh's check_ci() can parse the gh JSON
# output correctly regardless of PATH ordering. Without this, $STUB_BIN shadowing
# PATH could hide jq on some systems, causing check_ci() to exit early with
# ci.rc=skip and exercise a different code path than the one under test.
_real_jq="$(command -v jq)"
cat > "$STUB_BIN/jq" << JQSTUB
#!/usr/bin/env bash
exec "$_real_jq" "\$@"
JQSTUB
chmod +x "$STUB_BIN/jq"

# Create a stub for every other external binary validate.sh may invoke
for bin in python3; do
    cat > "$STUB_BIN/$bin" << 'STUB'
#!/usr/bin/env bash
exit 0
STUB
    chmod +x "$STUB_BIN/$bin"
done

# ── Fake project directory ────────────────────────────────────────────────────
# validate.sh calls `git rev-parse --show-toplevel` — must be a real git repo.
FAKE_PROJECT="$TMPDIR_TEST/fake-project"
mkdir -p "$FAKE_PROJECT"
cd "$FAKE_PROJECT" && git init -q 2>/dev/null

# Minimal .claude/dso-config.conf pointing at our test stubs
mkdir -p "$FAKE_PROJECT/.claude"
cat > "$FAKE_PROJECT/.claude/dso-config.conf" << CONF
paths.app_dir=.
commands.syntax_check=true
commands.format_check=true
commands.lint_ruff=true
commands.lint_mypy=true
commands.test_unit=true
CONF

# Makefile WITHOUT a test-e2e target — this is the scenario under test.
# When validate.sh runs `make test-e2e`, make will exit 2 ("No rule to make target").
cat > "$FAKE_PROJECT/Makefile" << 'MAKEFILE'
# Intentionally has no test-e2e target — this is the bug scenario
.PHONY: dummy
dummy:
	@echo "only a dummy target here"
MAKEFILE

# ── test_e2e_skip_when_target_missing_ci_pending ──────────────────────────────
# When CMD_TEST_E2E resolves to a make target that does not exist in the project
# Makefile, validate.sh --ci should output "SKIP" for e2e (not "FAIL") and must
# NOT add "e2e" to FAILED_CHECKS.
_snapshot_fail

rc=0
output=$(
    cd "$FAKE_PROJECT" && \
    PATH="$STUB_BIN:$PATH" \
    VALIDATE_CMD_TEST="true" \
    VALIDATE_TEST_BATCHED_SCRIPT="$STUB_TEST_BATCHED" \
    VALIDATE_TIMEOUT_CI=10 \
    VALIDATE_TIMEOUT_E2E=10 \
    bash "$VALIDATE_SH" --ci 2>&1
) || rc=$?

# The test should exit non-zero (CI pending with failure means FAILED=1),
# but that is expected — we only care about the e2e line in the output.

# PRIMARY ASSERTION: e2e must be reported as SKIP, not FAIL
if echo "$output" | grep -qE 'e2e:\s+FAIL'; then
    assert_eq "e2e not reported as FAIL when target missing" "SKIP" "FAIL"
else
    assert_eq "e2e not reported as FAIL when target missing" "SKIP" "SKIP"
fi

# SECONDARY ASSERTION: output must contain a SKIP line for e2e
if echo "$output" | grep -qE 'e2e:\s+SKIP'; then
    assert_eq "e2e SKIP line present in output" "present" "present"
else
    assert_eq "e2e SKIP line present in output" "present" "absent (output: $output)"
fi

assert_pass_if_clean "test_e2e_skip_when_target_missing_ci_pending"

echo ""
print_summary
