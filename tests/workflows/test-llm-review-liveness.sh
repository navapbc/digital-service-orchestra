#!/usr/bin/env bash
# tests/workflows/test-llm-review-liveness.sh
# Structural test for c131-0f34: every workflow that runs the LLM review must
# end with a liveness-assertion step that fails the job when the runner did
# not produce a well-formed findings artifact.
#
# Specifically:
#  1. .github/workflows/ci.yml's `llm-review` job MUST set
#     DSO_CI_REVIEW_OUTPUT_PATH so a file artifact exists to assert against.
#  2. ci.yml AND .github/workflows/per-branch-review.yml MUST contain a step
#     (after `Run LLM review`) that asserts /tmp/findings.json exists, is
#     non-empty, and has a `findings` key.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CI_YML="$REPO_ROOT/.github/workflows/ci.yml"
PER_BRANCH_YML="$REPO_ROOT/.github/workflows/per-branch-review.yml"

source "$REPO_ROOT/tests/lib/assert.sh"

# --- 1. ci.yml's llm-review job sets DSO_CI_REVIEW_OUTPUT_PATH ---
if grep -E "^[[:space:]]+DSO_CI_REVIEW_OUTPUT_PATH:" "$CI_YML" >/dev/null; then
    (( ++PASS ))
else
    (( ++FAIL ))
    echo "FAIL: ci.yml does not set DSO_CI_REVIEW_OUTPUT_PATH — runner writes to stdout, no artifact to assert against" >&2
fi

# --- 2. ci.yml contains a liveness assertion step ---
# The step name MUST contain 'liveness' (case-insensitive) AND its run block
# must reference /tmp/findings.json AND have a `findings` key check.
if grep -iE "name:.*liveness" "$CI_YML" >/dev/null; then
    (( ++PASS ))
else
    (( ++FAIL ))
    echo "FAIL: ci.yml has no liveness-assertion step (search: 'name:.*liveness')" >&2
fi

# The assertion body must check both file presence AND JSON shape.
if grep -E "/tmp/findings\.json" "$CI_YML" >/dev/null \
   && grep -E "jq.*findings|has\(.findings.\)" "$CI_YML" >/dev/null; then
    (( ++PASS ))
else
    (( ++FAIL ))
    echo "FAIL: ci.yml liveness step does not assert /tmp/findings.json existence + 'findings' key" >&2
fi

# --- 3. per-branch-review.yml contains a liveness assertion step ---
if grep -iE "name:.*liveness" "$PER_BRANCH_YML" >/dev/null; then
    (( ++PASS ))
else
    (( ++FAIL ))
    echo "FAIL: per-branch-review.yml has no liveness-assertion step" >&2
fi

if grep -E "/tmp/findings\.json" "$PER_BRANCH_YML" >/dev/null \
   && grep -E "jq.*findings|has\(.findings.\)" "$PER_BRANCH_YML" >/dev/null; then
    (( ++PASS ))
else
    (( ++FAIL ))
    echo "FAIL: per-branch-review.yml liveness step does not assert /tmp/findings.json + 'findings'" >&2
fi

# --- 4. runner.py's broad except writes findings.json before returning ---
# Defense-in-depth: the workflow liveness step is meaningless if the runner
# can fail before _write_output(). Asserts the broad-except block calls
# _write_output (string match — implementation detail visible enough at the
# source level).
RUNNER_PY="$REPO_ROOT/plugins/dso/scripts/dso_ci_review/runner.py"
if [ ! -f "$RUNNER_PY" ]; then
    (( ++FAIL ))
    echo "FAIL: runner.py not found at $RUNNER_PY — liveness guarantee depends on it" >&2
else
    # Find the broad-except block and assert _write_output is called inside.
    # shellcheck disable=SC2016  # python source must use single-quoted heredoc
    if python3 -c '
import re, sys
src = open(sys.argv[1]).read()
# Locate the broad-except block in main(): from `except Exception as exc:`
# (8-space indented) to the next `return` at the same indent level.
m = re.search(
    r"^    except Exception as exc:.*?\n(?P<body>(?:    .+\n|\n)*?)^    [^\s]",
    src, re.MULTILINE,
)
if not m:
    sys.exit(2)
sys.exit(0 if "_write_output" in m.group("body") else 1)
' "$RUNNER_PY"; then
        (( ++PASS ))
    else
        (( ++FAIL ))
        echo "FAIL: runner.py broad-except block does not call _write_output before returning — silent failure window remains" >&2
    fi
fi

print_summary
