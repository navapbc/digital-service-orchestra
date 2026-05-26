#!/usr/bin/env bash
# tests/scripts/test-bash-runner-red-zone.sh
#
# Behavioral tests for SUITE_TEST_INDEX RED-zone tolerance in
# plugins/dso/scripts/runners/bash-runner.sh (added in 7225-7708).
#
# Verifies:
#   - SUITE_TEST_INDEX unset: no behavior change (failures still fail)
#   - failure at/after marker: TOLERATED (reclassified pass)
#   - failure before marker: not tolerated (still fail)
#   - unparseable test output: fails safe (not tolerated)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
TEST_BATCHED="$REPO_ROOT/plugins/dso/scripts/test-batched.sh"

PASS=0
FAIL=0
fail_msg() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
pass_msg() { PASS=$((PASS + 1)); }

# Build an isolated fixture: temp dir with a test-*.sh file that has
# both a "good" function (passes) and a "bad" function (fails),
# plus a .test-index file marking the bad function as RED-tolerated.
FIXTURE=$(mktemp -d)
# Resolve macOS /tmp -> /private/tmp symlink so git rev-parse and `cd && pwd`
# return identical paths (test-batched.sh uses git rev-parse, while bash-runner
# computes _abs_bash_file via `cd $(dirname) && pwd`).
FIXTURE=$(cd "$FIXTURE" && pwd -P)
trap 'rm -rf "$FIXTURE"' EXIT
mkdir -p "$FIXTURE/tests/hooks"

# A test file with one passing test and one failing test (the bad one is later in the file)
cat > "$FIXTURE/tests/hooks/test-fixture.sh" <<'TESTSH'
#!/usr/bin/env bash
test_good_pass() {
    echo "test_good_pass ... PASS"
}
test_bad_fail() {
    echo "FAIL: test_bad_fail"
    exit 1
}
test_good_pass
test_bad_fail
TESTSH
chmod +x "$FIXTURE/tests/hooks/test-fixture.sh"

# Build .test-index marking test_bad_fail as a RED marker
cat > "$FIXTURE/.test-index" <<EOF
fixture-source.txt: tests/hooks/test-fixture.sh [test_bad_fail]
EOF
touch "$FIXTURE/fixture-source.txt"

# Initialize a git repo so red-zone helpers' REPO_ROOT detection works
git -C "$FIXTURE" init -q 2>/dev/null
git -C "$FIXTURE" -c user.email=t@t -c user.name=t add . 2>/dev/null
git -C "$FIXTURE" -c user.email=t@t -c user.name=t commit -q -m "fixture" 2>/dev/null

# ── Test 1: SUITE_TEST_INDEX unset → failure still fails ─────────────────
unset SUITE_TEST_INDEX
STATE_FILE_1=$(mktemp -u)
out1=$(cd "$FIXTURE" && \
    TEST_BATCHED_STATE_FILE="$STATE_FILE_1" \
    timeout 30 bash "$TEST_BATCHED" --timeout=20 --per-test-timeout=20 \
    --runner=bash --test-dir=tests/hooks "x" 2>&1)
rc1=$?
if [ "$rc1" != "0" ]; then
    pass_msg
else
    fail_msg "Test 1: SUITE_TEST_INDEX unset should produce non-zero exit (got $rc1). Output: $out1"
fi
if echo "$out1" | grep -qE "TOLERATED.*red-zone"; then
    fail_msg "Test 1: TOLERATED line should NOT appear when SUITE_TEST_INDEX is unset. Output: $out1"
else
    pass_msg
fi
rm -f "$STATE_FILE_1"

# ── Test 2: SUITE_TEST_INDEX set with marker covering failure → TOLERATED ─
# Tolerance is auto-disabled by the bash-runner when CI=true / GITHUB_ACTIONS=true.
# This test verifies the LEGACY local-tolerance contract, so scrub the CI envs
# via `env -u` to keep the assertion runnable inside CI workflows. Tests 4 and
# 5 below cover the inverse (CI vars set → tolerance off).
STATE_FILE_2=$(mktemp -u)
out2=$(cd "$FIXTURE" && \
    env -u CI -u GITHUB_ACTIONS \
    SUITE_TEST_INDEX="$FIXTURE/.test-index" \
    TEST_BATCHED_STATE_FILE="$STATE_FILE_2" \
    timeout 30 bash "$TEST_BATCHED" --timeout=20 --per-test-timeout=20 \
    --runner=bash --test-dir=tests/hooks "x" 2>&1)
rc2=$?
if echo "$out2" | grep -qE "TOLERATED.*red-zone.*test-fixture"; then
    pass_msg
else
    fail_msg "Test 2: marker covering failure should produce TOLERATED line. Output: $out2"
fi
if [ "$rc2" = "0" ]; then
    pass_msg
else
    fail_msg "Test 2: tolerated test should produce zero exit (got $rc2). Output: $out2"
fi
rm -f "$STATE_FILE_2"

# ── Test 3: marker BEFORE the failing function → not tolerated ───────────
# Replace the test file so test_bad_fail comes BEFORE test_good_pass; marker
# still points to test_bad_fail so its line is BEFORE the marker target's
# line in the file (we put the marker on test_good_pass).
cat > "$FIXTURE/tests/hooks/test-fixture.sh" <<'TESTSH'
#!/usr/bin/env bash
test_bad_fail() {
    echo "FAIL: test_bad_fail"
    exit 1
}
test_good_pass() {
    echo "test_good_pass ... PASS"
}
test_bad_fail
test_good_pass
TESTSH
chmod +x "$FIXTURE/tests/hooks/test-fixture.sh"
# Marker now points to test_good_pass (which is AFTER the failing test_bad_fail)
cat > "$FIXTURE/.test-index" <<EOF
fixture-source.txt: tests/hooks/test-fixture.sh [test_good_pass]
EOF

# Same env scrub as Test 2 — this assertion needs tolerance ENABLED to verify
# that the runner still produces a non-tolerated failure when the marker is
# in the wrong place. Without scrubbing CI vars, the assertion couldn't
# distinguish "wrong marker location" from "tolerance off entirely."
STATE_FILE_3=$(mktemp -u)
out3=$(cd "$FIXTURE" && \
    env -u CI -u GITHUB_ACTIONS \
    SUITE_TEST_INDEX="$FIXTURE/.test-index" \
    TEST_BATCHED_STATE_FILE="$STATE_FILE_3" \
    timeout 30 bash "$TEST_BATCHED" --timeout=20 --per-test-timeout=20 \
    --runner=bash --test-dir=tests/hooks "x" 2>&1)
rc3=$?
if echo "$out3" | grep -qE "TOLERATED.*red-zone"; then
    fail_msg "Test 3: failure BEFORE marker should NOT be tolerated. Output: $out3"
else
    pass_msg
fi
if [ "$rc3" != "0" ]; then
    pass_msg
else
    fail_msg "Test 3: untolerated failure should produce non-zero exit (got $rc3)"
fi
rm -f "$STATE_FILE_3"

# ── Test 4: CI=true overrides SUITE_TEST_INDEX → marker NOT honored ──────
# RED markers are a development-time TDD aid. When CI=true or GITHUB_ACTIONS=true,
# the runner must skip marker setup so every failing test fails the suite. Recreate
# the Test 2 fixture (marker covers the failure) but invoke the runner with CI=true.
cat > "$FIXTURE/tests/hooks/test-fixture.sh" <<'TESTSH'
#!/usr/bin/env bash
test_good_pass() {
    echo "test_good_pass ... PASS"
}
test_bad_fail() {
    echo "FAIL: test_bad_fail"
    exit 1
}
test_good_pass
test_bad_fail
TESTSH
chmod +x "$FIXTURE/tests/hooks/test-fixture.sh"
cat > "$FIXTURE/.test-index" <<EOF
fixture-source.txt: tests/hooks/test-fixture.sh [test_bad_fail]
EOF

STATE_FILE_4=$(mktemp -u)
out4=$(cd "$FIXTURE" && \
    CI=true \
    SUITE_TEST_INDEX="$FIXTURE/.test-index" \
    TEST_BATCHED_STATE_FILE="$STATE_FILE_4" \
    timeout 30 bash "$TEST_BATCHED" --timeout=20 --per-test-timeout=20 \
    --runner=bash --test-dir=tests/hooks "x" 2>&1)
rc4=$?
if echo "$out4" | grep -qE "TOLERATED.*red-zone"; then
    fail_msg "Test 4: CI=true must disable RED-zone tolerance. Output: $out4"
else
    pass_msg
fi
if [ "$rc4" != "0" ]; then
    pass_msg
else
    fail_msg "Test 4: CI=true with covered failure should produce non-zero exit (got $rc4)"
fi
rm -f "$STATE_FILE_4"

# ── Test 5: GITHUB_ACTIONS=true also disables tolerance ──────────────────
STATE_FILE_5=$(mktemp -u)
out5=$(cd "$FIXTURE" && \
    GITHUB_ACTIONS=true \
    SUITE_TEST_INDEX="$FIXTURE/.test-index" \
    TEST_BATCHED_STATE_FILE="$STATE_FILE_5" \
    timeout 30 bash "$TEST_BATCHED" --timeout=20 --per-test-timeout=20 \
    --runner=bash --test-dir=tests/hooks "x" 2>&1)
rc5=$?
if echo "$out5" | grep -qE "TOLERATED.*red-zone"; then
    fail_msg "Test 5: GITHUB_ACTIONS=true must disable RED-zone tolerance. Output: $out5"
else
    pass_msg
fi
if [ "$rc5" != "0" ]; then
    pass_msg
else
    fail_msg "Test 5: GITHUB_ACTIONS=true with covered failure should produce non-zero exit (got $rc5)"
fi
rm -f "$STATE_FILE_5"

echo ""
echo "PASSED: $PASS  FAILED: $FAIL"
[ "$FAIL" -eq 0 ] || exit 1
