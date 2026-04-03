#!/usr/bin/env bash
# tests/scripts/test-playwright-cli-validation.sh
# RED test suite for @playwright/cli capabilities.
#
# All tests are intentionally RED because the test HTML fixtures and wrapper
# logic referenced here do not yet exist. RED state is based on fixture/logic
# absence, not package absence.
#
# Usage: bash tests/scripts/test-playwright-cli-validation.sh
# Returns: exit 1 (RED — fixtures and wrapper not yet implemented)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null)"

# Project-local @playwright/cli install lives in spike-env/node_modules/.bin/
export PATH="$REPO_ROOT/spike-env/node_modules/.bin:$PATH"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-playwright-cli-validation.sh ==="

# ── Fixture paths (do not exist yet — RED state) ──────────────────────────────
FIXTURE_HTML_WAIT_FOR_SELECTOR="$REPO_ROOT/tests/fixtures/playwright/wait-for-selector.html"
FIXTURE_HTML_WAIT_FOR_LOAD="$REPO_ROOT/tests/fixtures/playwright/wait-for-load-state.html"
FIXTURE_HTML_SNAPSHOT="$REPO_ROOT/tests/fixtures/playwright/snapshot.html"
FIXTURE_HTML_SCREENSHOT="$REPO_ROOT/tests/fixtures/playwright/screenshot.html"
FIXTURE_HTML_CONSOLE="$REPO_ROOT/tests/fixtures/playwright/console.html"
FIXTURE_HTML_SESSION="$REPO_ROOT/tests/fixtures/playwright/session.html"

# Temporary output directory (cleaned up on exit)
TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_TEST"' EXIT

# ── Setup/teardown ────────────────────────────────────────────────────────────

# teardown_session: close any open spike-test session before/after session tests
teardown_session() {
    npx @playwright/cli close -s=spike-test 2>/dev/null || true
}

# ─────────────────────────────────────────────────────────────────────────────
# test_playwright_cli_installed
# Asserts that npx @playwright/cli --version exits 0
# ─────────────────────────────────────────────────────────────────────────────
test_playwright_cli_installed() {
    _snapshot_fail
    rc=0
    output=$(npx @playwright/cli --version 2>&1) || rc=$?
    assert_eq "test_playwright_cli_installed exit code" "0" "$rc"
    assert_ne "test_playwright_cli_installed version non-empty" "" "$output"
    assert_pass_if_clean "test_playwright_cli_installed"
}

# ─────────────────────────────────────────────────────────────────────────────
# test_run_code_async_wait_for_selector
# Asserts run-code with page.waitForSelector completes within 60s on test HTML page
# RED: fixture file does not yet exist
# ─────────────────────────────────────────────────────────────────────────────
test_run_code_async_wait_for_selector() {
    _snapshot_fail
    if [[ ! -f "$FIXTURE_HTML_WAIT_FOR_SELECTOR" ]]; then
        (( ++FAIL ))
        printf "FAIL: test_run_code_async_wait_for_selector\n  fixture missing: %s\n" \
            "$FIXTURE_HTML_WAIT_FOR_SELECTOR" >&2
    else
        rc=0
        output=$(timeout 60 npx @playwright/cli run-code \
            "const page = await browser.newPage(); await page.goto('file://${FIXTURE_HTML_WAIT_FOR_SELECTOR}'); await page.waitForSelector('[data-ready]'); console.log('selector-ok');" \
            2>&1) || rc=$?
        assert_eq "test_run_code_async_wait_for_selector exit code" "0" "$rc"
        assert_contains "test_run_code_async_wait_for_selector output" "selector-ok" "$output"
    fi
    assert_pass_if_clean "test_run_code_async_wait_for_selector"
}

# ─────────────────────────────────────────────────────────────────────────────
# test_run_code_async_wait_for_load_state
# Asserts run-code with page.waitForLoadState completes within 60s
# RED: fixture file does not yet exist
# ─────────────────────────────────────────────────────────────────────────────
test_run_code_async_wait_for_load_state() {
    _snapshot_fail
    if [[ ! -f "$FIXTURE_HTML_WAIT_FOR_LOAD" ]]; then
        (( ++FAIL ))
        printf "FAIL: test_run_code_async_wait_for_load_state\n  fixture missing: %s\n" \
            "$FIXTURE_HTML_WAIT_FOR_LOAD" >&2
    else
        rc=0
        output=$(timeout 60 npx @playwright/cli run-code \
            "const page = await browser.newPage(); await page.goto('file://${FIXTURE_HTML_WAIT_FOR_LOAD}'); await page.waitForLoadState('networkidle'); console.log('loadstate-ok');" \
            2>&1) || rc=$?
        assert_eq "test_run_code_async_wait_for_load_state exit code" "0" "$rc"
        assert_contains "test_run_code_async_wait_for_load_state output" "loadstate-ok" "$output"
    fi
    assert_pass_if_clean "test_run_code_async_wait_for_load_state"
}

# ─────────────────────────────────────────────────────────────────────────────
# test_binary_sharing_chromium_revision
# Asserts CLI and Python Playwright report the same Chromium revision
# RED: relies on chromium-revision-check wrapper not yet present
# ─────────────────────────────────────────────────────────────────────────────
test_binary_sharing_chromium_revision() {
    _snapshot_fail
    CHROMIUM_REV_WRAPPER="$REPO_ROOT/spike-env/chromium-revision-check.sh"
    if [[ ! -f "$CHROMIUM_REV_WRAPPER" ]]; then
        (( ++FAIL ))
        printf "FAIL: test_binary_sharing_chromium_revision\n  wrapper missing: %s\n" \
            "$CHROMIUM_REV_WRAPPER" >&2
    else
        cli_rev=""
        py_rev=""
        rc=0
        cli_rev=$(npx @playwright/cli chromium-revision 2>&1) || rc=$?
        py_rev=$(bash "$CHROMIUM_REV_WRAPPER" 2>&1) || true
        assert_eq "test_binary_sharing_chromium_revision cli exit code" "0" "$rc"
        assert_ne "test_binary_sharing_chromium_revision cli rev non-empty" "" "$cli_rev"
        assert_eq "test_binary_sharing_chromium_revision revisions match" "$cli_rev" "$py_rev"
    fi
    assert_pass_if_clean "test_binary_sharing_chromium_revision"
}

# ─────────────────────────────────────────────────────────────────────────────
# test_session_persistence
# Asserts navigate+click across separate Bash calls with same -s=spike-test
# session preserves page state
# RED: fixture file does not yet exist
# ─────────────────────────────────────────────────────────────────────────────
test_session_persistence() {
    _snapshot_fail
    teardown_session
    if [[ ! -f "$FIXTURE_HTML_SESSION" ]]; then
        (( ++FAIL ))
        printf "FAIL: test_session_persistence\n  fixture missing: %s\n" \
            "$FIXTURE_HTML_SESSION" >&2
    else
        rc1=0
        out1=$(npx @playwright/cli run-code -s=spike-test \
            "const page = await browser.newPage(); await page.goto('file://${FIXTURE_HTML_SESSION}'); await page.click('#set-state-btn'); console.log('state-set');" \
            2>&1) || rc1=$?
        rc2=0
        out2=$(npx @playwright/cli run-code -s=spike-test \
            "const page = await browser.pages().then(ps => ps[0]); const val = await page.getAttribute('#state-indicator', 'data-state'); console.log('state-value:' + val);" \
            2>&1) || rc2=$?
        assert_eq "test_session_persistence first call exit code" "0" "$rc1"
        assert_contains "test_session_persistence first call output" "state-set" "$out1"
        assert_eq "test_session_persistence second call exit code" "0" "$rc2"
        assert_contains "test_session_persistence second call preserves state" "state-value:active" "$out2"
        teardown_session
    fi
    assert_pass_if_clean "test_session_persistence"
}

# ─────────────────────────────────────────────────────────────────────────────
# test_output_format_snapshot
# Asserts snapshot output contains structured accessibility tree
# RED: fixture file does not yet exist
# ─────────────────────────────────────────────────────────────────────────────
test_output_format_snapshot() {
    _snapshot_fail
    if [[ ! -f "$FIXTURE_HTML_SNAPSHOT" ]]; then
        (( ++FAIL ))
        printf "FAIL: test_output_format_snapshot\n  fixture missing: %s\n" \
            "$FIXTURE_HTML_SNAPSHOT" >&2
    else
        rc=0
        output=$(npx @playwright/cli run-code \
            "const page = await browser.newPage(); await page.goto('file://${FIXTURE_HTML_SNAPSHOT}'); const snap = await page.accessibility.snapshot(); console.log(JSON.stringify(snap));" \
            2>&1) || rc=$?
        assert_eq "test_output_format_snapshot exit code" "0" "$rc"
        assert_contains "test_output_format_snapshot accessibility tree role" "\"role\"" "$output"
        assert_contains "test_output_format_snapshot accessibility tree name" "\"name\"" "$output"
    fi
    assert_pass_if_clean "test_output_format_snapshot"
}

# ─────────────────────────────────────────────────────────────────────────────
# test_output_format_screenshot
# Asserts screenshot saves file to specified path
# RED: fixture file does not yet exist
# ─────────────────────────────────────────────────────────────────────────────
test_output_format_screenshot() {
    _snapshot_fail
    if [[ ! -f "$FIXTURE_HTML_SCREENSHOT" ]]; then
        (( ++FAIL ))
        printf "FAIL: test_output_format_screenshot\n  fixture missing: %s\n" \
            "$FIXTURE_HTML_SCREENSHOT" >&2
    else
        SCREENSHOT_PATH="$TMPDIR_TEST/test-screenshot.png"
        rc=0
        output=$(npx @playwright/cli run-code \
            "const page = await browser.newPage(); await page.goto('file://${FIXTURE_HTML_SCREENSHOT}'); await page.screenshot({ path: '${SCREENSHOT_PATH}' }); console.log('screenshot-saved');" \
            2>&1) || rc=$?
        assert_eq "test_output_format_screenshot exit code" "0" "$rc"
        assert_contains "test_output_format_screenshot output" "screenshot-saved" "$output"
        if [[ -s "$SCREENSHOT_PATH" ]]; then
            (( ++PASS ))
        else
            (( ++FAIL ))
            printf "FAIL: test_output_format_screenshot screenshot file not created at %s\n" \
                "$SCREENSHOT_PATH" >&2
        fi
    fi
    assert_pass_if_clean "test_output_format_screenshot"
}

# ─────────────────────────────────────────────────────────────────────────────
# test_output_format_console
# Asserts console messages output contains structured message format
# RED: fixture file does not yet exist
# ─────────────────────────────────────────────────────────────────────────────
test_output_format_console() {
    _snapshot_fail
    if [[ ! -f "$FIXTURE_HTML_CONSOLE" ]]; then
        (( ++FAIL ))
        printf "FAIL: test_output_format_console\n  fixture missing: %s\n" \
            "$FIXTURE_HTML_CONSOLE" >&2
    else
        rc=0
        output=$(npx @playwright/cli run-code \
            "const page = await browser.newPage(); const msgs = []; page.on('console', m => msgs.push({type: m.type(), text: m.text()})); await page.goto('file://${FIXTURE_HTML_CONSOLE}'); await page.waitForLoadState('networkidle'); console.log(JSON.stringify(msgs));" \
            2>&1) || rc=$?
        assert_eq "test_output_format_console exit code" "0" "$rc"
        assert_contains "test_output_format_console type key" "\"type\"" "$output"
        assert_contains "test_output_format_console text key" "\"text\"" "$output"
    fi
    assert_pass_if_clean "test_output_format_console"
}

# ─────────────────────────────────────────────────────────────────────────────
# Run all test functions
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- test_playwright_cli_installed ---"
test_playwright_cli_installed

echo ""
echo "--- test_run_code_async_wait_for_selector ---"
test_run_code_async_wait_for_selector

echo ""
echo "--- test_run_code_async_wait_for_load_state ---"
test_run_code_async_wait_for_load_state

echo ""
echo "--- test_binary_sharing_chromium_revision ---"
test_binary_sharing_chromium_revision

echo ""
echo "--- test_session_persistence ---"
test_session_persistence

echo ""
echo "--- test_output_format_snapshot ---"
test_output_format_snapshot

echo ""
echo "--- test_output_format_screenshot ---"
test_output_format_screenshot

echo ""
echo "--- test_output_format_console ---"
test_output_format_console

# ─────────────────────────────────────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────────────────────────────────────
print_summary
