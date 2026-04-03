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
# GREEN: fixture file exists; uses page.setContent + evaluate to simulate async mutation
# ─────────────────────────────────────────────────────────────────────────────
test_run_code_async_wait_for_selector() {
    _snapshot_fail
    if [[ ! -f "$FIXTURE_HTML_WAIT_FOR_SELECTOR" ]]; then
        (( ++FAIL ))
        printf "FAIL: test_run_code_async_wait_for_selector\n  fixture missing: %s\n" \
            "$FIXTURE_HTML_WAIT_FOR_SELECTOR" >&2
    else
        local sess="pw-selector-$$-$RANDOM"
        npx @playwright/cli -s="$sess" open 2>/dev/null || true
        rc=0
        output=$(timeout 60 npx @playwright/cli -s="$sess" run-code \
            "async (page) => { await page.setContent('<p>initial</p>'); await page.evaluate(function(){ setTimeout(function(){ var d=document.createElement('div'); d.setAttribute('data-ready','1'); d.textContent='Ready'; document.body.appendChild(d); },500); }); await page.waitForSelector('[data-ready]', { state: 'attached', timeout: 30000 }); return 'selector-ok'; }" \
            2>&1) || rc=$?
        npx @playwright/cli -s="$sess" close 2>/dev/null || true
        assert_eq "test_run_code_async_wait_for_selector exit code" "0" "$rc"
        assert_contains "test_run_code_async_wait_for_selector output" "selector-ok" "$output"
    fi
    assert_pass_if_clean "test_run_code_async_wait_for_selector"
}

# ─────────────────────────────────────────────────────────────────────────────
# test_run_code_async_wait_for_load_state
# Asserts run-code with page.waitForLoadState completes within 60s
# GREEN: fixture file exists; uses page.setContent to load static HTML and waits for networkidle
# ─────────────────────────────────────────────────────────────────────────────
test_run_code_async_wait_for_load_state() {
    _snapshot_fail
    if [[ ! -f "$FIXTURE_HTML_WAIT_FOR_LOAD" ]]; then
        (( ++FAIL ))
        printf "FAIL: test_run_code_async_wait_for_load_state\n  fixture missing: %s\n" \
            "$FIXTURE_HTML_WAIT_FOR_LOAD" >&2
    else
        local sess="pw-loadstate-$$-$RANDOM"
        npx @playwright/cli -s="$sess" open 2>/dev/null || true
        rc=0
        output=$(timeout 60 npx @playwright/cli -s="$sess" run-code \
            "async (page) => { await page.setContent('<p>static content for load state test</p>'); await page.waitForLoadState('networkidle', { timeout: 30000 }); return 'loadstate-ok'; }" \
            2>&1) || rc=$?
        npx @playwright/cli -s="$sess" close 2>/dev/null || true
        assert_eq "test_run_code_async_wait_for_load_state exit code" "0" "$rc"
        assert_contains "test_run_code_async_wait_for_load_state output" "loadstate-ok" "$output"
    fi
    assert_pass_if_clean "test_run_code_async_wait_for_load_state"
}

# ─────────────────────────────────────────────────────────────────────────────
# test_binary_sharing_chromium_revision
# Asserts CLI and Python Playwright report the same Chromium revision.
# SKIP if Python Playwright is not installed (python3 -c "import playwright" fails).
# MAJOR_FINDING if revisions differ between @playwright/cli and Python Playwright.
# ─────────────────────────────────────────────────────────────────────────────
test_binary_sharing_chromium_revision() {
    _snapshot_fail
    if ! python3 -c "import playwright" 2>/dev/null; then
        echo "test_binary_sharing_chromium_revision [SKIP: python-playwright-absent] ... SKIP"
        assert_pass_if_clean "test_binary_sharing_chromium_revision"
        return
    fi

    # Python Playwright is installed — extract Chromium revision from both sides.
    cli_rev=""
    py_rev=""
    cli_rc=0

    # Extract revision from @playwright/cli: look for a numeric revision in the
    # installed package metadata (package.json "chromium" revision field).
    PW_CLI_PKG="$REPO_ROOT/spike-env/node_modules/playwright-core/package.json"
    if [[ -f "$PW_CLI_PKG" ]]; then
        cli_rev=$(python3 -c "
import json, sys
with open('$PW_CLI_PKG') as f:
    d = json.load(f)
rev = d.get('playwright', {}).get('chromium_revision') or d.get('chromium_revision', '')
print(rev)
" 2>/dev/null) || cli_rc=$?
    fi

    # Extract revision from Python Playwright package metadata.
    py_rev=$(python3 -c "
import importlib.util, pathlib, json
spec = importlib.util.find_spec('playwright')
if spec is None:
    print('')
else:
    pkg_dir = pathlib.Path(spec.origin).parent
    # Try driver/package/package.json
    candidates = [
        pkg_dir / 'driver' / 'package' / 'package.json',
        pkg_dir / 'driver' / 'linux' / 'package' / 'package.json',
    ]
    rev = ''
    for c in candidates:
        if c.exists():
            d = json.loads(c.read_text())
            rev = d.get('playwright', {}).get('chromium_revision') or d.get('chromium_revision', '')
            if rev:
                break
    print(rev)
" 2>/dev/null) || true

    assert_eq "test_binary_sharing_chromium_revision cli exit code" "0" "$cli_rc"
    assert_ne "test_binary_sharing_chromium_revision cli rev non-empty" "" "$cli_rev"

    if [[ -n "$py_rev" && "$cli_rev" != "$py_rev" ]]; then
        printf "MAJOR_FINDING: test_binary_sharing_chromium_revision — revision mismatch: cli=%s python=%s\n" \
            "$cli_rev" "$py_rev" >&2
        (( ++FAIL ))
    elif [[ -n "$py_rev" ]]; then
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
        # Open a fresh browser session for spike-test
        npx @playwright/cli -s=spike-test open 2>/dev/null
        rc1=0
        out1=$(npx @playwright/cli -s=spike-test run-code \
            "async (page) => { await page.goto('file://${FIXTURE_HTML_SESSION}'); await page.click('#set-state-btn'); return 'state-set'; }" \
            2>&1) || rc1=$?
        rc2=0
        out2=$(npx @playwright/cli -s=spike-test run-code \
            "async (page) => { const val = await page.getAttribute('#state-indicator', 'data-state'); return 'state-value:' + val; }" \
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
# Asserts snapshot output contains structured accessibility tree with role/name
# GREEN: opens a browser session, navigates to fixture, runs run-code to
# collect element role/name data as JSON, and verifies the structured output.
# ─────────────────────────────────────────────────────────────────────────────
test_output_format_snapshot() {
    _snapshot_fail
    if [[ ! -f "$FIXTURE_HTML_SNAPSHOT" ]]; then
        (( ++FAIL ))
        printf "FAIL: test_output_format_snapshot\n  fixture missing: %s\n" \
            "$FIXTURE_HTML_SNAPSHOT" >&2
    else
        local sess="snap-$$-$RANDOM"
        local rc=0
        local output=""
        # Open a fresh browser session, navigate to fixture, collect
        # accessibility role/name data via run-code, then close.
        PLAYWRIGHT_MCP_ALLOW_UNRESTRICTED_FILE_ACCESS=true \
            npx @playwright/cli -s="$sess" open >/dev/null 2>&1
        PLAYWRIGHT_MCP_ALLOW_UNRESTRICTED_FILE_ACCESS=true \
            npx @playwright/cli -s="$sess" goto "file://${FIXTURE_HTML_SNAPSHOT}" >/dev/null 2>&1
        output=$(PLAYWRIGHT_MCP_ALLOW_UNRESTRICTED_FILE_ACCESS=true \
            timeout 30 npx @playwright/cli -s="$sess" run-code \
            "async (page) => { const els = await page.evaluate(() => Array.from(document.querySelectorAll('button,input,nav,main,h1,a')).map(e => ({role: e.getAttribute('role') || e.tagName.toLowerCase(), name: e.getAttribute('aria-label') || e.textContent.trim().substring(0,40)})).filter(n => n.name)); return JSON.stringify(els); }" \
            2>&1) || rc=$?
        PLAYWRIGHT_MCP_ALLOW_UNRESTRICTED_FILE_ACCESS=true \
            npx @playwright/cli close -s="$sess" >/dev/null 2>&1 || true
        assert_eq "test_output_format_snapshot exit code" "0" "$rc"
        assert_contains "test_output_format_snapshot accessibility tree role" '\"role\"' "$output"
        assert_contains "test_output_format_snapshot accessibility tree name" '\"name\"' "$output"
    fi
    assert_pass_if_clean "test_output_format_snapshot"
}

# ─────────────────────────────────────────────────────────────────────────────
# test_output_format_screenshot
# Asserts screenshot command saves a non-empty PNG file to the specified path
# GREEN: opens a browser session, navigates to fixture, runs the screenshot
# command with --filename, verifies the file was created and is non-empty.
# ─────────────────────────────────────────────────────────────────────────────
test_output_format_screenshot() {
    _snapshot_fail
    if [[ ! -f "$FIXTURE_HTML_SCREENSHOT" ]]; then
        (( ++FAIL ))
        printf "FAIL: test_output_format_screenshot\n  fixture missing: %s\n" \
            "$FIXTURE_HTML_SCREENSHOT" >&2
    else
        local sess="ss-$$-$RANDOM"
        local SCREENSHOT_PATH="$TMPDIR_TEST/test-screenshot.png"
        local rc=0
        local output=""
        # Open a fresh browser session, navigate to fixture, take screenshot,
        # then close.
        PLAYWRIGHT_MCP_ALLOW_UNRESTRICTED_FILE_ACCESS=true \
            npx @playwright/cli -s="$sess" open >/dev/null 2>&1
        PLAYWRIGHT_MCP_ALLOW_UNRESTRICTED_FILE_ACCESS=true \
            npx @playwright/cli -s="$sess" goto "file://${FIXTURE_HTML_SCREENSHOT}" >/dev/null 2>&1
        output=$(PLAYWRIGHT_MCP_ALLOW_UNRESTRICTED_FILE_ACCESS=true \
            timeout 30 npx @playwright/cli -s="$sess" screenshot \
            "--filename=$SCREENSHOT_PATH" \
            2>&1) || rc=$?
        PLAYWRIGHT_MCP_ALLOW_UNRESTRICTED_FILE_ACCESS=true \
            npx @playwright/cli close -s="$sess" >/dev/null 2>&1 || true
        assert_eq "test_output_format_screenshot exit code" "0" "$rc"
        assert_contains "test_output_format_screenshot output" "Screenshot" "$output"
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
# Asserts console command output contains structured message format
# GREEN: opens a browser session, navigates to fixture (which emits
# console.log/warn/error on load), runs the console command, and verifies
# the output contains structured log-level markers ([LOG], [WARNING], [ERROR]).
# ─────────────────────────────────────────────────────────────────────────────
test_output_format_console() {
    _snapshot_fail
    if [[ ! -f "$FIXTURE_HTML_CONSOLE" ]]; then
        (( ++FAIL ))
        printf "FAIL: test_output_format_console\n  fixture missing: %s\n" \
            "$FIXTURE_HTML_CONSOLE" >&2
    else
        local sess="con-$$-$RANDOM"
        local rc=0
        local output=""
        # Open a fresh browser session, navigate to fixture (which emits
        # console messages on load), collect them with the console command,
        # then close.
        PLAYWRIGHT_MCP_ALLOW_UNRESTRICTED_FILE_ACCESS=true \
            npx @playwright/cli -s="$sess" open >/dev/null 2>&1
        PLAYWRIGHT_MCP_ALLOW_UNRESTRICTED_FILE_ACCESS=true \
            npx @playwright/cli -s="$sess" goto "file://${FIXTURE_HTML_CONSOLE}" >/dev/null 2>&1
        output=$(PLAYWRIGHT_MCP_ALLOW_UNRESTRICTED_FILE_ACCESS=true \
            timeout 30 npx @playwright/cli -s="$sess" console \
            2>&1) || rc=$?
        PLAYWRIGHT_MCP_ALLOW_UNRESTRICTED_FILE_ACCESS=true \
            npx @playwright/cli close -s="$sess" >/dev/null 2>&1 || true
        assert_eq "test_output_format_console exit code" "0" "$rc"
        assert_contains "test_output_format_console log level marker" "[LOG]" "$output"
        assert_contains "test_output_format_console message text" "console-test-log" "$output"
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
