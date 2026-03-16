#!/usr/bin/env bash
# lockpick-workflow/tests/evals/test_evals_runner_processes_single_entry.sh
# TDD test: verifies run-evals.sh processes a single skill-activation entry.
#
# Usage: bash lockpick-workflow/tests/evals/test_evals_runner_processes_single_entry.sh
#
# Assertion density: 4 assertions (exit_code, output PASS, output skill id, summary)

# Note: Do NOT use `set -e` — assert.sh uses (( PASS++ )) which exits non-zero
# when the counter is 0 (arithmetic expression evaluating to 0 is "false").
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR" && git rev-parse --show-toplevel)"
LIB_DIR="$PLUGIN_ROOT/tests/lib"

source "$LIB_DIR/assert.sh"

# --- Fixtures ---
RUNNER="$SCRIPT_DIR/run-evals.sh"

# Write fixture to a temp dir (not the worktree) for test isolation
TMPDIR_FIXTURE="$(mktemp -d "${TMPDIR:-/tmp}/test-evals-runner-XXXXXX")"
trap 'rm -rf "$TMPDIR_FIXTURE"' EXIT
MINIMAL_JSON="$TMPDIR_FIXTURE/minimal_single_entry.json"

# Write a minimal evals.json with one file_exists entry targeting a skill that exists.
cat > "$MINIMAL_JSON" <<'EOF'
{
  "suites": [
    {
      "id": "skill-batch-overlap-check-exists",
      "category": "skill-activation",
      "phase_introduced": 0,
      "hook": ".claude/skills/batch-overlap-check/SKILL.md",
      "setup": { "stdin": "", "state_files": {}, "env": {} },
      "assertions": [
        { "type": "file_exists", "path": ".claude/skills/batch-overlap-check/SKILL.md" }
      ]
    }
  ]
}
EOF

# --- Test: run-evals.sh exits 0 on a single passing entry ---
output=$(bash "$RUNNER" "$MINIMAL_JSON" 2>&1)
exit_code=$?

assert_eq "exit_code is 0 for passing entry" "0" "$exit_code"
assert_contains "output contains PASS" "PASS" "$output"
assert_contains "output contains entry id" "skill-batch-overlap-check-exists" "$output"
assert_contains "output contains summary line" "passed" "$output"

print_summary
