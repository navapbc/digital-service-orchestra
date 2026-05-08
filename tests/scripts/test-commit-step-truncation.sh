#!/usr/bin/env bash
# tests/scripts/test-commit-step-truncation.sh
# RED-phase tests for commit-step.sh truncation immunity.
#
# These tests verify that commit-step.sh writes its artifact file even when
# its stdout is piped through a truncating consumer (tail, /dev/null, grep -v).
#
# RED/PASS STATUS NOTE:
# Tests 1-4 (pipe_to_tail, pipe_to_devnull, grep_filter, failing_cmd) currently
# pass prematurely because commit-step.sh already redirects command stdout to a
# temp file and does not stream to its own stdout — so SIGPIPE from a pipe
# consumer never reaches the artifact-write code path. These tests are marked
# with TODO comments below.
#
# Test 5 (verifier_sees_failure_through_tail) is genuinely RED: it asserts the
# verifier exits 1 when only one required artifact is present (lint.result), which
# the current implementation satisfies correctly. However the full E2E scenario
# (artifact written through tail pipe) currently passes trivially — see TODO.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
source "$SCRIPT_DIR/../lib/assert.sh"

COMMIT_STEP="$REPO_ROOT/plugins/dso/scripts/commit-step.sh"
VERIFIER="$REPO_ROOT/plugins/dso/hooks/pre-commit-compliance-verifier.sh"

# ── Isolation: each test gets a fresh artifacts dir ──
_TEST_TMPDIRS=()
_cleanup_tmpdirs() {
    for d in "${_TEST_TMPDIRS[@]:-}"; do
        rm -rf "$d"
    done
}
trap _cleanup_tmpdirs EXIT

_make_artifacts_dir() {
    local d
    d=$(mktemp -d)
    _TEST_TMPDIRS+=("$d")
    echo "$d"
}

# ── Test 1: test_pipe_to_tail_artifact_intact ──
# When: commit-step.sh output is piped through `tail -3` (early consumer)
# Then: the artifact file must still exist and record exit_code=0
# TODO: this test passes prematurely — commit-step.sh already redirects command
#       stdout to a temp file; it does not stream to its own stdout, so SIGPIPE
#       from tail never races with the artifact write. This test will become
#       meaningfully RED if commit-step.sh is refactored to stream to stdout.
test_pipe_to_tail_artifact_intact() {
    local artifacts_dir
    artifacts_dir=$(_make_artifacts_dir)

    # Pipe stdout+stderr through tail -3; tail exits after 3 lines, sending SIGPIPE
    # to the process group. The artifact write must survive this truncation.
    WORKFLOW_PLUGIN_ARTIFACTS_DIR="$artifacts_dir" \
        bash "$COMMIT_STEP" lint 5 bash -c 'echo ok' 2>&1 | tail -3

    local result_file="$artifacts_dir/lint.result"

    local file_exists="no"
    [[ -f "$result_file" ]] && file_exists="yes"
    assert_eq "pipe_to_tail: artifact file exists" "yes" "$file_exists"

    local exit_code_val="missing"
    if [[ -f "$result_file" ]]; then
        exit_code_val=$(python3 -c "
import json, sys
try:
    data = json.load(open(sys.argv[1]))
    print(str(data.get('exit_code', 'missing')))
except Exception as e:
    print('parse_error: ' + str(e))
" "$result_file" 2>/dev/null || echo "parse_error")
    fi
    assert_eq "pipe_to_tail: artifact records exit_code=0" "0" "$exit_code_val"
}

# ── Test 2: test_pipe_to_devnull_artifact_intact ──
# When: commit-step.sh stdout is redirected to /dev/null
# Then: the artifact file must still be written
# TODO: this test passes prematurely — redirecting to /dev/null has no effect on
#       artifact writes since commit-step.sh does not write to stdout at all;
#       the artifact goes directly to a file. Behavior is correct by accident.
test_pipe_to_devnull_artifact_intact() {
    local artifacts_dir
    artifacts_dir=$(_make_artifacts_dir)

    # Redirect all output to /dev/null; the artifact write must still complete.
    WORKFLOW_PLUGIN_ARTIFACTS_DIR="$artifacts_dir" \
        bash "$COMMIT_STEP" lint 5 bash -c 'echo ok' >/dev/null 2>&1

    local result_file="$artifacts_dir/lint.result"

    local file_exists="no"
    [[ -f "$result_file" ]] && file_exists="yes"
    assert_eq "pipe_to_devnull: artifact file exists" "yes" "$file_exists"
}

# ── Test 3: test_grep_filter_artifact_intact ──
# When: commit-step.sh stdout is piped through `grep -v "ok"` (filters all output)
# Then: the artifact file must still exist and be valid JSON
# TODO: this test passes prematurely — commit-step.sh does not emit anything to
#       stdout in the success path, so grep -v sends no SIGPIPE signal. The
#       artifact write is not exercised under actual pipe pressure.
test_grep_filter_artifact_intact() {
    local artifacts_dir
    artifacts_dir=$(_make_artifacts_dir)

    # grep -v "ok" matches and drops lines containing "ok" (all output here),
    # then exits 1 with broken pipe signalling the upstream process.
    WORKFLOW_PLUGIN_ARTIFACTS_DIR="$artifacts_dir" \
        bash "$COMMIT_STEP" lint 5 bash -c 'echo ok' 2>&1 | grep -v "ok" || true

    local result_file="$artifacts_dir/lint.result"

    local file_exists="no"
    [[ -f "$result_file" ]] && file_exists="yes"
    assert_eq "grep_filter: artifact file exists" "yes" "$file_exists"

    local is_valid_json="no"
    if [[ -f "$result_file" ]]; then
        is_valid_json=$(python3 -c "
import json, sys
try:
    json.load(open(sys.argv[1]))
    print('yes')
except Exception:
    print('no')
" "$result_file" 2>/dev/null || echo "no")
    fi
    assert_eq "grep_filter: artifact is valid JSON" "yes" "$is_valid_json"
}

# ── Test 4: test_failing_cmd_artifact_records_failure ──
# When: the underlying command exits 1 and stdout is piped to /dev/null
# Then: the artifact must exist and record exit_code=1
# TODO: this test passes prematurely — the >/dev/null redirect applies to
#       commit-step.sh's own stdout, not the inner command's stdout (which goes
#       to a temp file). The failing exit code is correctly captured regardless
#       of how the outer process stdout is redirected. The test is valid as a
#       regression guard but is not a true RED test for the truncation scenario.
test_failing_cmd_artifact_records_failure() {
    local artifacts_dir
    artifacts_dir=$(_make_artifacts_dir)

    # Underlying command exits 1; commit-step should propagate this exit code
    # AND write the artifact before dying.
    WORKFLOW_PLUGIN_ARTIFACTS_DIR="$artifacts_dir" \
        bash "$COMMIT_STEP" lint 5 bash -c 'echo failing; exit 1' >/dev/null 2>&1 || true

    local result_file="$artifacts_dir/lint.result"

    local file_exists="no"
    [[ -f "$result_file" ]] && file_exists="yes"
    assert_eq "failing_cmd: artifact file exists" "yes" "$file_exists"

    local exit_code_val="missing"
    if [[ -f "$result_file" ]]; then
        exit_code_val=$(python3 -c "
import json, sys
try:
    data = json.load(open(sys.argv[1]))
    print(str(data.get('exit_code', 'missing')))
except Exception as e:
    print('parse_error: ' + str(e))
" "$result_file" 2>/dev/null || echo "parse_error")
    fi
    assert_eq "failing_cmd: artifact records exit_code=1" "1" "$exit_code_val"
}

# ── Test 5: test_verifier_sees_failure_through_tail ──
# E2E: commit-step writes artifact with failure (exit 1),
# then pre-commit-compliance-verifier.sh reads the artifact directory.
# Because the artifact records a failure (exit_code=1) the verifier should
# NOT block on missing artifacts (it finds the file), but the commit-step
# process itself should exit 1 even when piped through tail.
#
# RED condition: commit-step.sh currently does not guarantee the artifact
# is written before SIGPIPE from the pipe consumer terminates the process.
# If SIGPIPE kills commit-step before it writes the artifact, the verifier
# will EXIT 1 because the required artifact is MISSING (not because it saw
# a failure exit_code). The test asserts on the artifact-exists path.
test_verifier_sees_failure_through_tail() {
    local artifacts_dir
    artifacts_dir=$(_make_artifacts_dir)

    # Step A: run commit-step with a failing command, piped through tail -3
    # so that the pipe consumer exits early and may send SIGPIPE.
    WORKFLOW_PLUGIN_ARTIFACTS_DIR="$artifacts_dir" \
        bash "$COMMIT_STEP" lint 5 bash -c 'echo output line; exit 1' 2>&1 | tail -3 || true

    # Step B: the artifact must exist for the verifier to read it at all.
    local result_file="$artifacts_dir/lint.result"

    local file_exists="no"
    [[ -f "$result_file" ]] && file_exists="yes"
    assert_eq "e2e_verifier: artifact exists after pipe through tail" "yes" "$file_exists"

    # Step C: verify the verifier sees the artifact directory correctly.
    # The verifier requires ALL standard steps (test, format, lint, classifier-dispatch,
    # reviewer-record). We only have lint here; the verifier will block on missing others.
    # That is expected behavior — the key assertion is that lint.result EXISTS.
    # We verify the exit_code field in the artifact matches the failing command.
    local exit_code_val="missing"
    if [[ -f "$result_file" ]]; then
        exit_code_val=$(python3 -c "
import json, sys
try:
    data = json.load(open(sys.argv[1]))
    print(str(data.get('exit_code', 'missing')))
except Exception as e:
    print('parse_error: ' + str(e))
" "$result_file" 2>/dev/null || echo "parse_error")
    fi
    assert_eq "e2e_verifier: artifact records failure exit_code=1" "1" "$exit_code_val"

    # Step D: run the verifier with the compliance check enabled.
    # It will exit 1 because only lint.result is present, not all required steps.
    # The test asserts it exits 1 (blocked) rather than 0 (passed with no artifacts).
    local verifier_exit=0
    DSO_COMPLIANCE_VERIFIER_ENABLED=true \
        WORKFLOW_PLUGIN_ARTIFACTS_DIR="$artifacts_dir" \
        bash "$VERIFIER" 2>/dev/null || verifier_exit=$?

    assert_eq "e2e_verifier: verifier blocked (exits 1)" "1" "$verifier_exit"
}

# ── Test 6: test_python_artifact_write_failure_exits_nonzero ──
# When: the python3 process used to write the artifact fails (simulated via PATH override)
# Then: commit-step.sh must exit non-zero AND must NOT produce a corrupt artifact
test_python_artifact_write_failure_exits_nonzero() {
    local artifacts_dir
    artifacts_dir=$(_make_artifacts_dir)

    # Inject a fake python3 that exits 1 on every call
    local fake_bin
    fake_bin=$(mktemp -d)
    _TEST_TMPDIRS+=("$fake_bin")
    cat > "$fake_bin/python3" <<'PYEOF'
#!/usr/bin/env bash
exit 1
PYEOF
    chmod +x "$fake_bin/python3"

    local exit_code=0
    PATH="$fake_bin:$PATH" WORKFLOW_PLUGIN_ARTIFACTS_DIR="$artifacts_dir" \
        bash "$COMMIT_STEP" lint 5 bash -c 'echo ok' 2>/dev/null || exit_code=$?

    assert_eq "python_fail: commit-step exits non-zero" "1" "$exit_code"

    local artifact_exists="no"
    [[ -f "$artifacts_dir/lint.result" ]] && artifact_exists="yes"
    assert_eq "python_fail: no corrupt artifact on disk" "no" "$artifact_exists"
}

# ── Run all tests ──
test_pipe_to_tail_artifact_intact
test_pipe_to_devnull_artifact_intact
test_grep_filter_artifact_intact
test_failing_cmd_artifact_records_failure
test_verifier_sees_failure_through_tail
test_python_artifact_write_failure_exits_nonzero

print_summary
