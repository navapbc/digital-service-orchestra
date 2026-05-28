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
# Explicit utf-8 encoding — runner.py contains non-ASCII (e.g., Unicode em-
# dashes in comments). Locale-default encoding could raise UnicodeDecodeError
# on a non-UTF-8 system (c131-0f34 review cycle 4).
with open(sys.argv[1], encoding="utf-8") as _f:
    src = _f.read()
# Locate the broad-except block in main(): from `except Exception as exc:`
# (4-space indented) to the next return-1 at the same indent level. Anchors
# on the broad-except block in main() and asserts _write_output is called
# within it.
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

# --- 5. Behavioral test: extract the assertion logic and verify it fires
#        on each failure condition. Regression guard against future edits
#        that quietly weaken the check (e.g., dropping `if-no-files-found`
#        or replacing the jq guard with a non-failing alternative). ---

_ASSERT_SCRIPT=$(mktemp "${TMPDIR:-/tmp}/liveness-assert.XXXXXX".sh)
_FIND_FIXTURE=$(mktemp "${TMPDIR:-/tmp}/liveness-fixture.XXXXXX".json)
trap 'rm -f "$_ASSERT_SCRIPT" "$_FIND_FIXTURE"' EXIT

cat > "$_ASSERT_SCRIPT" <<EOF
#!/bin/bash
set -euo pipefail
F="$_FIND_FIXTURE"
if [ ! -s "\$F" ]; then
  echo "ERROR [liveness]: missing or empty" >&2; exit 1
fi
if ! jq -e 'has("findings") and (.findings | type == "array")' "\$F" >/dev/null 2>&1; then
  echo "ERROR [liveness]: malformed" >&2
  head -c 500 "\$F" 2>/dev/null | sed 's/^/  | /' >&2 || true
  exit 1
fi
echo "review liveness: ok (\$(jq -r '.findings | length' "\$F") findings)"
EOF

_run_assert() {
    local _out _rc=0
    _out=$(bash "$_ASSERT_SCRIPT" 2>&1) || _rc=$?
    printf '%s|%d' "$_out" "$_rc"
}

# Case A: missing file
rm -f "$_FIND_FIXTURE"
result=$(_run_assert)
if [[ "${result##*|}" == "1" && "$result" == *"missing or empty"* ]]; then
    (( ++PASS ))
else
    (( ++FAIL ))
    echo "FAIL: assertion did not fire on missing file: $result" >&2
fi

# Case B: empty file
: > "$_FIND_FIXTURE"
result=$(_run_assert)
if [[ "${result##*|}" == "1" && "$result" == *"missing or empty"* ]]; then
    (( ++PASS ))
else
    (( ++FAIL ))
    echo "FAIL: assertion did not fire on empty file: $result" >&2
fi

# Case C: malformed JSON — must fire AND must print malformed content snippet
echo 'not json {{{' > "$_FIND_FIXTURE"
result=$(_run_assert)
if [[ "${result##*|}" == "1" && "$result" == *"malformed"* && "$result" == *"not json"* ]]; then
    (( ++PASS ))
else
    (( ++FAIL ))
    echo "FAIL: assertion did not fire on malformed JSON or did not print snippet: $result" >&2
fi

# Case D: valid JSON but missing 'findings' key
echo '{"summary":"ran","cycle_number":1}' > "$_FIND_FIXTURE"
result=$(_run_assert)
if [[ "${result##*|}" == "1" && "$result" == *"malformed"* ]]; then
    (( ++PASS ))
else
    (( ++FAIL ))
    echo "FAIL: assertion did not fire on missing 'findings' key: $result" >&2
fi

# Case D2: 'findings' key present but value is NOT an array (regression
# guard for c131-0f34 review cycle 3 — without the `.findings | type ==
# "array"` predicate, this case used to pass falsely).
echo '{"findings":{"oops":"object"},"cycle_number":1}' > "$_FIND_FIXTURE"
result=$(_run_assert)
if [[ "${result##*|}" == "1" && "$result" == *"malformed"* ]]; then
    (( ++PASS ))
else
    (( ++FAIL ))
    echo "FAIL: assertion did not fire on findings-is-object (non-array): $result" >&2
fi

# Case D3: 'findings' key present but value is null
echo '{"findings":null,"cycle_number":1}' > "$_FIND_FIXTURE"
result=$(_run_assert)
if [[ "${result##*|}" == "1" && "$result" == *"malformed"* ]]; then
    (( ++PASS ))
else
    (( ++FAIL ))
    echo "FAIL: assertion did not fire on findings-is-null: $result" >&2
fi

# Case E: valid empty findings → must PASS
echo '{"findings":[],"cycle_number":1}' > "$_FIND_FIXTURE"
result=$(_run_assert)
if [[ "${result##*|}" == "0" && "$result" == *"ok (0 findings)"* ]]; then
    (( ++PASS ))
else
    (( ++FAIL ))
    echo "FAIL: assertion mis-fired on valid empty findings: $result" >&2
fi

# Case F: valid populated findings → must PASS with correct count
echo '{"findings":[{"severity":"minor"},{"severity":"important"}],"cycle_number":1}' > "$_FIND_FIXTURE"
result=$(_run_assert)
if [[ "${result##*|}" == "0" && "$result" == *"ok (2 findings)"* ]]; then
    (( ++PASS ))
else
    (( ++FAIL ))
    echo "FAIL: assertion mis-fired on valid populated findings: $result" >&2
fi

print_summary
