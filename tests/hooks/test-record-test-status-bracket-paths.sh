#!/usr/bin/env bash
set -euo pipefail
# tests/hooks/test-record-test-status-bracket-paths.sh
#
# Regression tests for bug c209-a321:
#   Jest TS/TSX test paths with bracket segments (e.g. [id], [locale]) were
#   passed as positional regex arguments to jest, causing "No tests found"
#   exit 1. The fix uses --runTestsByPath, which treats each argument as an
#   exact filesystem path rather than a regex pattern.
#
# Covers:
#   tsx_bracket_path_uses_runTestsByPath (source-level assertion)
#   tsx_bracket_path_passing_records_passed_status
#   tsx_bracket_path_failing_records_failed_status
#   tsx_static_path_still_works_with_runTestsByPath

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
HOOK="$DSO_PLUGIN_DIR/hooks/record-test-status.sh"
PROCESSOR="$DSO_PLUGIN_DIR/hooks/lib/test-result-processor.sh"

source "$PLUGIN_ROOT/tests/lib/assert.sh"
source "$DSO_PLUGIN_DIR/hooks/lib/deps.sh"

# Disable commit signing for test git repos
export GIT_CONFIG_COUNT=1
export GIT_CONFIG_KEY_0=commit.gpgsign
export GIT_CONFIG_VALUE_0=false

# ============================================================
# Helper: create an isolated temp git repo with initial commit
# ============================================================
create_test_repo() {
    local tmpdir
    tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/test-rts-bracket-XXXXXX")
    git -C "$tmpdir" init --quiet 2>/dev/null
    git -C "$tmpdir" config user.email "test@test.com"
    git -C "$tmpdir" config user.name "Test"
    touch "$tmpdir/.gitkeep"
    git -C "$tmpdir" add .gitkeep
    git -C "$tmpdir" commit -m "initial" --quiet 2>/dev/null
    echo "$tmpdir"
}

run_hook_exit() {
    local exit_code=0
    bash "$HOOK" 2>/dev/null || exit_code=$?
    echo "$exit_code"
}

# ============================================================
# test_tsx_bracket_path_uses_runTestsByPath
#
# Source-level assertion: the TS/TSX branch in test-result-processor.sh
# must use --runTestsByPath, not a bare positional argument.
# Positional args are regex-matched by jest; brackets become character
# classes (e.g. [id] matches 'i' or 'd', not the literal "[id]" segment).
# ============================================================
echo ""
echo "=== test_tsx_bracket_path_uses_runTestsByPath ==="
_snapshot_fail

USES_RUNTESTSBY_PATH=$(grep -c -- '--runTestsByPath' "$PROCESSOR" || echo "0")
assert_ne "tsx_branch_uses_runTestsByPath: --runTestsByPath found in processor" \
    "0" "$USES_RUNTESTSBY_PATH"

# Verify no bare positional-arg jest invocation remains in the TS/TSX branch.
# The pattern 'jest "$full_test_path"' (without --runTestsByPath flag before it)
# is the bug; it must NOT exist.
# Use grep exit code directly rather than -c to avoid the "0\n0" double-output
# when grep finds nothing (exits 1) and || echo "0" also fires.
# shellcheck disable=SC2016  # single-quote intentional: matching literal $full_test_path in source file
if grep -q 'jest "\$full_test_path"' "$PROCESSOR" 2>/dev/null; then
    BARE_POSITIONAL="1"
else
    BARE_POSITIONAL="0"
fi
assert_eq "tsx_branch_no_bare_positional_arg: 'jest \"\$full_test_path\"' not present" \
    "0" "$BARE_POSITIONAL"

assert_pass_if_clean "test_tsx_bracket_path_uses_runTestsByPath"

# ============================================================
# test_tsx_bracket_path_passing_records_passed_status
#
# A TS/TSX test file whose path contains bracket segments (dynamic-route
# Next.js / SvelteKit pattern) must record "passed" when the test exits 0.
# Before fix: jest treated [id] as a regex character class → "No tests found"
#   → exit 1 → recorder wrote "failed" for a test that actually passes.
# After fix: --runTestsByPath resolves the exact path → exit 0 → "passed".
# ============================================================
echo ""
echo "=== test_tsx_bracket_path_passing_records_passed_status ==="
_snapshot_fail

TEST_REPO_BRACKET_PASS=$(create_test_repo)
ARTIFACTS_BRACKET_PASS=$(mktemp -d "${TMPDIR:-/tmp}/test-rts-artifacts-XXXXXX")
trap 'rm -rf "$TEST_REPO_BRACKET_PASS" "$ARTIFACTS_BRACKET_PASS"' EXIT

# Create a source file at a bracket-segment path (simulates Next.js App Router route)
mkdir -p "$TEST_REPO_BRACKET_PASS/src/app/api/projects/[id]"
cat > "$TEST_REPO_BRACKET_PASS/src/app/api/projects/[id]/route.ts" << 'EOF'
export async function GET(request: Request, { params }: { params: { id: string } }) {
  return Response.json({ id: params.id });
}
EOF

# Create the test file at the same bracket-segment path
mkdir -p "$TEST_REPO_BRACKET_PASS/src/app/api/projects/[id]/__tests__"
cat > "$TEST_REPO_BRACKET_PASS/src/app/api/projects/[id]/__tests__/route.test.tsx" << 'EOF'
// Stub test — real jest invocation replaced by mock runner in the test harness
EOF

# Map source → test via .test-index
cat > "$TEST_REPO_BRACKET_PASS/.test-index" << 'IDXEOF'
src/app/api/projects/[id]/route.ts: src/app/api/projects/[id]/__tests__/route.test.tsx
IDXEOF

git -C "$TEST_REPO_BRACKET_PASS" add -A
git -C "$TEST_REPO_BRACKET_PASS" commit -m "initial" --quiet 2>/dev/null

# Stage source change to trigger the test
echo "// updated" >> "$TEST_REPO_BRACKET_PASS/src/app/api/projects/[id]/route.ts"
git -C "$TEST_REPO_BRACKET_PASS" add -A

# Mock runner: simulates a passing jest run.
# With --runTestsByPath the path is resolved literally; the mock receives the
# exact path and exits 0 (test passes). Before fix, jest would exit 1 because
# the bracket regex matched nothing — the mock replaces jest entirely, so the
# recorder's behavior under the fix is what matters here.
MOCK_BRACKET_PASS=$(mktemp "${TMPDIR:-/tmp}/mock-bracket-pass-XXXXXX")
chmod +x "$MOCK_BRACKET_PASS"
cat > "$MOCK_BRACKET_PASS" << 'MOCKEOF'
#!/usr/bin/env bash
# Simulates: npx --no-install jest --runTestsByPath <path> --no-coverage
# All tests pass (exit 0).
echo "PASS src/app/api/projects/[id]/__tests__/route.test.tsx"
echo ""
echo "Test Suites: 1 passed, 1 total"
echo "Tests:       1 passed, 1 total"
exit 0
MOCKEOF

EXIT_BRACKET_PASS=$(
    cd "$TEST_REPO_BRACKET_PASS"
    WORKFLOW_PLUGIN_ARTIFACTS_DIR="$ARTIFACTS_BRACKET_PASS" \
    CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" \
    RECORD_TEST_STATUS_RUNNER="$MOCK_BRACKET_PASS" \
    run_hook_exit
)
assert_eq "tsx_bracket_path_passing: hook exits 0" "0" "$EXIT_BRACKET_PASS"

STATUS_BRACKET_PASS=$(head -1 "$ARTIFACTS_BRACKET_PASS/test-gate-status" 2>/dev/null || echo "missing")
assert_eq "tsx_bracket_path_passing: status is passed" "passed" "$STATUS_BRACKET_PASS"

# Confirm the bracket-path test appears in tested_files audit trail
TESTED_BRACKET_PASS=$(grep '^tested_files=' "$ARTIFACTS_BRACKET_PASS/test-gate-status" 2>/dev/null || echo "")
assert_contains "tsx_bracket_path_passing: test path in tested_files" \
    "route.test.tsx" "$TESTED_BRACKET_PASS"

rm -f "$MOCK_BRACKET_PASS"
rm -rf "$TEST_REPO_BRACKET_PASS" "$ARTIFACTS_BRACKET_PASS"
trap - EXIT

assert_pass_if_clean "test_tsx_bracket_path_passing_records_passed_status"

# ============================================================
# test_tsx_bracket_path_failing_records_failed_status
#
# A TS/TSX test with a bracket-segment path that genuinely fails (exit 1)
# must still record "failed" status — the fix must not suppress real failures.
# ============================================================
echo ""
echo "=== test_tsx_bracket_path_failing_records_failed_status ==="
_snapshot_fail

TEST_REPO_BRACKET_FAIL=$(create_test_repo)
ARTIFACTS_BRACKET_FAIL=$(mktemp -d "${TMPDIR:-/tmp}/test-rts-artifacts-XXXXXX")
trap 'rm -rf "$TEST_REPO_BRACKET_FAIL" "$ARTIFACTS_BRACKET_FAIL"' EXIT

mkdir -p "$TEST_REPO_BRACKET_FAIL/src/app/api/projects/[id]"
cat > "$TEST_REPO_BRACKET_FAIL/src/app/api/projects/[id]/route.ts" << 'EOF'
export async function GET() { return Response.error(); }
EOF

mkdir -p "$TEST_REPO_BRACKET_FAIL/src/app/api/projects/[id]/__tests__"
cat > "$TEST_REPO_BRACKET_FAIL/src/app/api/projects/[id]/__tests__/route.test.tsx" << 'EOF'
// Stub — mock runner drives this
EOF

cat > "$TEST_REPO_BRACKET_FAIL/.test-index" << 'IDXEOF'
src/app/api/projects/[id]/route.ts: src/app/api/projects/[id]/__tests__/route.test.tsx
IDXEOF

git -C "$TEST_REPO_BRACKET_FAIL" add -A
git -C "$TEST_REPO_BRACKET_FAIL" commit -m "initial" --quiet 2>/dev/null
echo "// updated" >> "$TEST_REPO_BRACKET_FAIL/src/app/api/projects/[id]/route.ts"
git -C "$TEST_REPO_BRACKET_FAIL" add -A

# Mock runner: simulates a genuinely failing jest test (not a "No tests found" error)
MOCK_BRACKET_FAIL=$(mktemp "${TMPDIR:-/tmp}/mock-bracket-fail-XXXXXX")
chmod +x "$MOCK_BRACKET_FAIL"
cat > "$MOCK_BRACKET_FAIL" << 'MOCKEOF'
#!/usr/bin/env bash
echo "FAIL src/app/api/projects/[id]/__tests__/route.test.tsx"
echo "  - expect(response.status).toBe(200)"
echo ""
echo "Test Suites: 1 failed, 1 total"
echo "Tests:       1 failed, 1 total"
exit 1
MOCKEOF

EXIT_BRACKET_FAIL=$(
    cd "$TEST_REPO_BRACKET_FAIL"
    WORKFLOW_PLUGIN_ARTIFACTS_DIR="$ARTIFACTS_BRACKET_FAIL" \
    CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" \
    RECORD_TEST_STATUS_RUNNER="$MOCK_BRACKET_FAIL" \
    run_hook_exit
)
assert_eq "tsx_bracket_path_failing: hook exits 1" "1" "$EXIT_BRACKET_FAIL"

STATUS_BRACKET_FAIL=$(head -1 "$ARTIFACTS_BRACKET_FAIL/test-gate-status" 2>/dev/null || echo "missing")
assert_eq "tsx_bracket_path_failing: status is failed" "failed" "$STATUS_BRACKET_FAIL"

rm -f "$MOCK_BRACKET_FAIL"
rm -rf "$TEST_REPO_BRACKET_FAIL" "$ARTIFACTS_BRACKET_FAIL"
trap - EXIT

assert_pass_if_clean "test_tsx_bracket_path_failing_records_failed_status"

# ============================================================
# test_tsx_static_path_still_works_with_runTestsByPath
#
# Static (non-bracket) TS/TSX paths must continue to work correctly
# after the --runTestsByPath change. This is a regression guard to
# confirm the fix doesn't break the non-bracket case.
# ============================================================
echo ""
echo "=== test_tsx_static_path_still_works_with_runTestsByPath ==="
_snapshot_fail

TEST_REPO_STATIC=$(create_test_repo)
ARTIFACTS_STATIC=$(mktemp -d "${TMPDIR:-/tmp}/test-rts-artifacts-XXXXXX")
trap 'rm -rf "$TEST_REPO_STATIC" "$ARTIFACTS_STATIC"' EXIT

mkdir -p "$TEST_REPO_STATIC/src/components" "$TEST_REPO_STATIC/src/__tests__"
cat > "$TEST_REPO_STATIC/src/components/Button.tsx" << 'EOF'
export const Button = ({ label }: { label: string }) => <button>{label}</button>;
EOF
cat > "$TEST_REPO_STATIC/src/__tests__/Button.test.tsx" << 'EOF'
// Stub — mock runner drives this
EOF

cat > "$TEST_REPO_STATIC/.test-index" << 'IDXEOF'
src/components/Button.tsx: src/__tests__/Button.test.tsx
IDXEOF

git -C "$TEST_REPO_STATIC" add -A
git -C "$TEST_REPO_STATIC" commit -m "initial" --quiet 2>/dev/null
echo "// updated" >> "$TEST_REPO_STATIC/src/components/Button.tsx"
git -C "$TEST_REPO_STATIC" add -A

MOCK_STATIC=$(mktemp "${TMPDIR:-/tmp}/mock-static-XXXXXX")
chmod +x "$MOCK_STATIC"
cat > "$MOCK_STATIC" << 'MOCKEOF'
#!/usr/bin/env bash
echo "PASS src/__tests__/Button.test.tsx"
echo ""
echo "Test Suites: 1 passed, 1 total"
echo "Tests:       2 passed, 2 total"
exit 0
MOCKEOF

EXIT_STATIC=$(
    cd "$TEST_REPO_STATIC"
    WORKFLOW_PLUGIN_ARTIFACTS_DIR="$ARTIFACTS_STATIC" \
    CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" \
    RECORD_TEST_STATUS_RUNNER="$MOCK_STATIC" \
    run_hook_exit
)
assert_eq "tsx_static_path: hook exits 0" "0" "$EXIT_STATIC"

STATUS_STATIC=$(head -1 "$ARTIFACTS_STATIC/test-gate-status" 2>/dev/null || echo "missing")
assert_eq "tsx_static_path: status is passed" "passed" "$STATUS_STATIC"

rm -f "$MOCK_STATIC"
rm -rf "$TEST_REPO_STATIC" "$ARTIFACTS_STATIC"
trap - EXIT

assert_pass_if_clean "test_tsx_static_path_still_works_with_runTestsByPath"

print_summary
