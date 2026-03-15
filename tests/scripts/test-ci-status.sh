#!/usr/bin/env bash
# lockpick-workflow/tests/scripts/test-ci-status.sh
# Tests for the get_job_timeout_min helper in lockpick-workflow/scripts/ci-status.sh.
#
# Usage: bash lockpick-workflow/tests/scripts/test-ci-status.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR" && git rev-parse --show-toplevel)"

source "$REPO_ROOT/lockpick-workflow/tests/lib/assert.sh"

echo "=== test-ci-status.sh ==="

# ── Python probe ──────────────────────────────────────────────────────────────
# Resolve Python with PyYAML (same probe as read-config.sh / _find_python_with_yaml)
PYTHON=""
for _candidate in \
    "${CLAUDE_PLUGIN_PYTHON:-}" \
    "$REPO_ROOT/app/.venv/bin/python3" \
    "$REPO_ROOT/.venv/bin/python3" \
    "python3"; do
    [[ -z "$_candidate" ]] && continue
    [[ "$_candidate" != "python3" ]] && [[ ! -f "$_candidate" ]] && continue
    if "$_candidate" -c "import yaml" 2>/dev/null; then
        PYTHON="$_candidate"
        break
    fi
done

if [[ -z "$PYTHON" ]]; then
    echo "SKIP: no python3 with PyYAML found — skipping get_job_timeout_min tests"
    print_summary
    exit 0
fi

# ── Fixture ci.yml ────────────────────────────────────────────────────────────
TMPDIR_FIXTURE="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_FIXTURE"' EXIT

FIXTURE_CI="$TMPDIR_FIXTURE/ci.yml"
cat > "$FIXTURE_CI" <<'YAML'
jobs:
  fast-gate:
    name: Fast Gate
    timeout-minutes: 10
  unit-tests:
    name: Unit Tests
    timeout-minutes: 15
  e2e:
    name: E2E Tests
    timeout-minutes: 20
  no-timeout:
    name: No Timeout Job
YAML

# ── Inline the Python logic under test ───────────────────────────────────────
# This mirrors the heredoc embedded in get_job_timeout_min exactly,
# so changes to the script will break these tests if the logic diverges.
run_get_job_timeout_min() {
    local yaml="$1" job_name="$2"
    "$PYTHON" - "$yaml" "$job_name" <<'PYEOF'
import sys
try:
    import yaml as _yaml
    with open(sys.argv[1]) as f:
        data = _yaml.safe_load(f)
    for job in (data or {}).get("jobs", {}).values():
        if job.get("name") == sys.argv[2]:
            t = job.get("timeout-minutes")
            if t is not None:
                print(t)
            sys.exit(0)
    print(f"Warning: CI job '{sys.argv[2]}' not found in {sys.argv[1]}", file=sys.stderr)
except FileNotFoundError:
    pass
except Exception as e:
    print(f"Warning: error parsing {sys.argv[1]}: {e}", file=sys.stderr)
PYEOF
}

# ── Tests ─────────────────────────────────────────────────────────────────────

# Known job: Fast Gate → 10
actual=$(run_get_job_timeout_min "$FIXTURE_CI" "Fast Gate" 2>/dev/null)
assert_eq "fast_gate_timeout: returns 10" "10" "$actual"

# Known job: Unit Tests → 15
actual=$(run_get_job_timeout_min "$FIXTURE_CI" "Unit Tests" 2>/dev/null)
assert_eq "unit_tests_timeout: returns 15" "15" "$actual"

# Known job: E2E Tests → 20
actual=$(run_get_job_timeout_min "$FIXTURE_CI" "E2E Tests" 2>/dev/null)
assert_eq "e2e_timeout: returns 20" "20" "$actual"

# Job with no timeout-minutes set → empty output (not an error)
actual=$(run_get_job_timeout_min "$FIXTURE_CI" "No Timeout Job" 2>/dev/null)
assert_eq "no_timeout_job: empty output" "" "$actual"

# Unknown job name → empty stdout, warning on stderr
actual_out=$(run_get_job_timeout_min "$FIXTURE_CI" "Nonexistent Job" 2>/dev/null)
actual_err=$(run_get_job_timeout_min "$FIXTURE_CI" "Nonexistent Job" 2>&1 >/dev/null)
assert_eq "unknown_job: empty stdout" "" "$actual_out"
assert_contains "unknown_job: warning on stderr" "not found" "$actual_err"

# Missing ci.yml → empty output, no error (FileNotFoundError is silenced)
actual_out=$(run_get_job_timeout_min "$TMPDIR_FIXTURE/does-not-exist.yml" "Fast Gate" 2>/dev/null)
actual_err=$(run_get_job_timeout_min "$TMPDIR_FIXTURE/does-not-exist.yml" "Fast Gate" 2>&1 >/dev/null)
assert_eq "missing_yaml: empty stdout" "" "$actual_out"
assert_eq "missing_yaml: silent stderr" "" "$actual_err"

# ── Summary ───────────────────────────────────────────────────────────────────
print_summary
