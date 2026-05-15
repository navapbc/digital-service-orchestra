#!/usr/bin/env bash
# Structural test: verify .test-index format is documented with the test file
# path requirement (test file path MUST precede the [marker] bracket).
#
# This is a Rule 5 structural-boundary test (behavioral-testing-standard.md):
# the artifact under test is a non-executable agent instruction file.
# The assertion is a referential-integrity check — the format documentation
# must contain the canonical format string used by tooling (record-test-status.sh,
# pre-commit-test-gate.sh) to validate .test-index entries.
#
# Bug: 32e5-5240-b693-4511
set -uo pipefail

REPO_ROOT=$(git rev-parse --show-toplevel)

# shellcheck source=/dev/null
source "${REPO_ROOT}/tests/lib/assert.sh"

# The canonical format key string is 'source_file:test_file' — present in the
# correct-example block added to red-test-writer.md.  We also accept the
# equivalent form in COMMIT-WORKFLOW.md if that file is updated in the future.
FORMAT_CHECK=0

if grep -q 'source/path\.ext: test/path\.ext \[' \
    "${REPO_ROOT}/plugins/dso/agents/red-test-writer.md" 2>/dev/null; then
    FORMAT_CHECK=1
fi

if grep -q 'source_file:test_file' \
    "${REPO_ROOT}/plugins/dso/docs/workflows/COMMIT-WORKFLOW.md" 2>/dev/null; then
    FORMAT_CHECK=1
fi

assert_eq "test-index format doc present" "1" "$FORMAT_CHECK"

# Also verify the INCORRECT example is documented (correct vs incorrect contrast)
INCORRECT_EXAMPLE_CHECK=0
if grep -q 'INCORRECT' \
    "${REPO_ROOT}/plugins/dso/agents/red-test-writer.md" 2>/dev/null; then
    INCORRECT_EXAMPLE_CHECK=1
fi

assert_eq "INCORRECT format example documented" "1" "$INCORRECT_EXAMPLE_CHECK"

print_summary
