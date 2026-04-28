#!/usr/bin/env bash
# tests/scripts/test-sigpipe-canary.sh
# Permanent canary test demonstrating bash pipefail divergence detection.
#
# Demonstrates that `set -o pipefail` catches pipeline failures that normal
# bash (without pipefail) silently swallows.
#
# Usage: bash tests/scripts/test-sigpipe-canary.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-sigpipe-canary.sh ==="

# ── test_pipefail_catches_pipeline_failure ────────────────────────────────────
_snapshot_fail

# Contrast: without pipefail, `false | true` exits 0 (last command wins)
bash -c 'false | true'
exit_without_pipefail=$?

# With pipefail: `false | true` exits non-zero (failure propagates)
bash -eo pipefail -c 'false | true' 2>/dev/null
exit_with_pipefail=$?

assert_eq "test_pipefail_catches_pipeline_failure: without pipefail exits 0" \
    "0" "$exit_without_pipefail"
assert_ne "test_pipefail_catches_pipeline_failure: with pipefail exits non-zero" \
    "0" "$exit_with_pipefail"

assert_pass_if_clean "test_pipefail_catches_pipeline_failure"

# ── test_bash_opts_cli_args ───────────────────────────────────────────────────
_snapshot_fail

# GitHub Actions CI sets BASH_OPTS as a job-level env var and each run: step
# invokes `bash $BASH_OPTS script.sh` — the variable is word-split into CLI
# flags. This test verifies that pattern works correctly.
BASH_OPTS='-eo pipefail'
# shellcheck disable=SC2086  # word-splitting is intentional: $BASH_OPTS must expand to separate flags
bash $BASH_OPTS -c 'false | true' 2>/dev/null
exit_via_bash_opts=$?

assert_ne "test_bash_opts_cli_args: BASH_OPTS word-split as CLI flags catches pipeline failure" \
    "0" "$exit_via_bash_opts"

assert_pass_if_clean "test_bash_opts_cli_args"

print_summary
