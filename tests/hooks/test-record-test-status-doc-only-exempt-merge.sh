#!/usr/bin/env bash
set -uo pipefail
# tests/hooks/test-record-test-status-doc-only-exempt-merge.sh
# Bug 11d5-0429: doc-only-exempt sentinel must not downgrade or pollute
# tested_files when concrete test paths are present at the same diff_hash.
#
# Two cooperating defects in record-test-status.sh:
#   Bug A — line 566 area: unconditional cat>file with tested_files=doc-only-exempt
#           clobbers an existing richer same-hash record.
#   Bug B — line 854-864 merge: doc-only-exempt token survives sort/paste union
#           when concrete test paths are also present.
#
# Tests invoke the actual hook script end-to-end via mock test runner.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
HOOK="$DSO_PLUGIN_DIR/hooks/record-test-status.sh"
COMPUTE_HASH_SCRIPT="$DSO_PLUGIN_DIR/hooks/compute-diff-hash.sh"

source "$PLUGIN_ROOT/tests/lib/assert.sh"
source "$DSO_PLUGIN_DIR/hooks/lib/deps.sh"

export GIT_CONFIG_COUNT=1
export GIT_CONFIG_KEY_0=commit.gpgsign
export GIT_CONFIG_VALUE_0=false

# Mock pass runner — tests don't need pytest
_MOCK_PASS_RUNNER=$(mktemp "${TMPDIR:-/tmp}/mock-pass-runner-XXXXXX")
chmod +x "$_MOCK_PASS_RUNNER"
cat > "$_MOCK_PASS_RUNNER" << 'MOCKEOF'
#!/usr/bin/env bash
exit 0
MOCKEOF

create_test_repo() {
    local tmpdir
    tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/test-rts-doexempt-XXXXXX")
    git -C "$tmpdir" init --quiet 2>/dev/null
    git -C "$tmpdir" config user.email "test@test.com"
    git -C "$tmpdir" config user.name "Test"
    touch "$tmpdir/.gitkeep"
    git -C "$tmpdir" add .gitkeep
    git -C "$tmpdir" commit -m "initial" --quiet 2>/dev/null
    echo "$tmpdir"
}

# ── Test 1: Bug B end-to-end — sentinel must not survive resume merge ──
echo ""
echo "--- Bug B: doc-only-exempt cleared by resume that records concrete tests ---"

_snapshot_fail
TMPREPO=$(create_test_repo)
trap 'rm -rf "$TMPREPO" "$_MOCK_PASS_RUNNER"' EXIT

# Create source + test, register in .test-index
mkdir -p "$TMPREPO/src" "$TMPREPO/tests"
echo "x=1" > "$TMPREPO/src/foo.py"
cat > "$TMPREPO/tests/test_foo.py" <<'EOF'
def test_foo(): assert True
EOF
echo "src/foo.py:tests/test_foo.py" > "$TMPREPO/.test-index"
git -C "$TMPREPO" add -A
git -C "$TMPREPO" commit -m "add foo" --quiet

# First: invoke hook normally (mock runner) — populates progress + status
cd "$TMPREPO" || exit 1
DSO_COMMIT_WORKFLOW=1 RECORD_TEST_STATUS_RUNNER="$_MOCK_PASS_RUNNER" \
    bash "$HOOK" --source-file src/foo.py >/dev/null 2>&1 || true

# Get the artifacts dir the hook used
ARTIFACTS_DIR=$(get_artifacts_dir)
STATUS_FILE="$ARTIFACTS_DIR/test-gate-status"

if [[ ! -f "$STATUS_FILE" ]]; then
    echo "SETUP_FAIL: status file not created"
    _FAIL=1
fi

# Capture diff_hash from the status file the hook just wrote
DIFF_HASH=$(grep '^diff_hash=' "$STATUS_FILE" 2>/dev/null | head -1 | cut -d= -f2-)

# Compute test-index hash (matches the script's _TEST_INDEX_HASH derivation)
_TIH=$(shasum -a 256 "$TMPREPO/.test-index" | cut -d' ' -f1)

# Recreate the progress file to mimic an interrupted prior run (Bug B preconditions
# require the resume short-circuit to fire, which depends on the progress file).
PROGRESS_FILE="$ARTIFACTS_DIR/test-gate-progress-${DIFF_HASH:0:16}-${_TIH:0:8}"
echo "tests/test_foo.py" > "$PROGRESS_FILE"

# Simulate Bug A's clobber: overwrite tested_files with doc-only-exempt at same hash.
# Include failed_tests= to match the format the merge path expects.
cat > "$STATUS_FILE" <<EOF
passed
diff_hash=${DIFF_HASH}
timestamp=2026-05-08T00:45:56Z
tested_files=doc-only-exempt
failed_tests=
EOF

# Re-invoke hook — resume short-circuit fires; merge block reads the clobbered status.
DSO_COMMIT_WORKFLOW=1 RECORD_TEST_STATUS_RUNNER="$_MOCK_PASS_RUNNER" \
    bash "$HOOK" --source-file src/foo.py >/dev/null 2>&1 || true

_final_tested=$(grep '^tested_files=' "$STATUS_FILE" 2>/dev/null | head -1 | cut -d= -f2-)

assert_contains "bug_b_e2e: tested_files contains test_foo.py" "tests/test_foo.py" "$_final_tested"
# Critical assertion — sentinel must NOT survive when concrete paths are present.
if [[ ",${_final_tested}," == *",doc-only-exempt,"* ]]; then
    echo "FAIL bug_b_e2e: doc-only-exempt sentinel survived merge: $_final_tested"
    _FAIL=1
fi
assert_pass_if_clean "test_bug_b_e2e_sentinel_stripped_after_resume"

# ── Test 2: Bug A end-to-end — doc-only path must not clobber rich same-hash record ──
echo ""
echo "--- Bug A: doc-only invocation refuses to downgrade richer same-hash record ---"

_snapshot_fail
# Setup a doc file with NO entry in .test-index (triggers the doc-only-exempt path)
cd "$TMPREPO" || exit 1
mkdir -p "$TMPREPO/docs"
echo "doc" > "$TMPREPO/docs/foo.md"
git -C "$TMPREPO" add -A
git -C "$TMPREPO" commit -m "add doc" --quiet

# Seed a richer record at the doc commit's diff_hash (matches what record-test-status will
# compute when invoked). We capture it by invoking the hook's compute-diff-hash helper.
DIFF_HASH=$(DSO_COMMIT_WORKFLOW=1 bash "$COMPUTE_HASH_SCRIPT" 2>/dev/null | tr -d '[:space:]' || true)

# If we couldn't compute, derive from the script's own output by invoking once
if [[ -z "$DIFF_HASH" ]]; then
    DSO_COMMIT_WORKFLOW=1 RECORD_TEST_STATUS_RUNNER="$_MOCK_PASS_RUNNER" \
        bash "$HOOK" --source-file docs/foo.md >/dev/null 2>&1 || true
    DIFF_HASH=$(grep '^diff_hash=' "$STATUS_FILE" 2>/dev/null | head -1 | cut -d= -f2-)
fi

# Seed a rich record (mimics Step 1 of synthetic recipe)
cat > "$STATUS_FILE" <<EOF
passed
diff_hash=${DIFF_HASH}
timestamp=2026-05-08T00:30:00Z
tested_files=tests/test_a.sh,tests/test_b.sh
EOF

# Now invoke the hook against the doc-only path — it should refuse to downgrade
DSO_COMMIT_WORKFLOW=1 RECORD_TEST_STATUS_RUNNER="$_MOCK_PASS_RUNNER" \
    bash "$HOOK" --source-file docs/foo.md >/dev/null 2>&1 || true

_final_tested=$(grep '^tested_files=' "$STATUS_FILE" 2>/dev/null | head -1 | cut -d= -f2-)

# The rich record must be preserved — sentinel must NOT have clobbered it.
if [[ "$_final_tested" == "doc-only-exempt" ]]; then
    echo "FAIL bug_a_e2e: rich record clobbered to doc-only-exempt at same hash"
    _FAIL=1
fi
assert_contains "bug_a_e2e: tested_files contains test_a" "tests/test_a.sh" "$_final_tested"
assert_contains "bug_a_e2e: tested_files contains test_b" "tests/test_b.sh" "$_final_tested"
assert_pass_if_clean "test_bug_a_e2e_no_downgrade_same_hash"

rm -rf "$TMPREPO" "$_MOCK_PASS_RUNNER"
trap - EXIT

print_summary
