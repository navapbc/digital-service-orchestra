#!/usr/bin/env bash
# Tests for capture-screenshots.sh (Story 2: Screenshot Capture Pipeline)
# These tests exercise the gating logic without requiring a running server or Playwright.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CAPTURE="$REPO_ROOT/plugins/dso/scripts/capture-screenshots.sh"

pass=0
fail=0

assert_exit_contains() {
  local desc="$1" expected_exit="$2" expected_stderr="$3"
  shift 3
  local tmpfile
  tmpfile=$(mktemp /tmp/capture-test.XXXXXX)
  if "$@" >"$tmpfile" 2>&1; then
    actual=0
  else
    actual=$?
  fi
  local output
  output=$(cat "$tmpfile")
  rm -f "$tmpfile"

  if [[ "$actual" -ne "$expected_exit" ]]; then
    echo "FAIL: $desc (expected exit $expected_exit, got $actual)"
    fail=$((fail + 1))
    return
  fi
  if [[ -n "$expected_stderr" ]] && ! echo "$output" | grep -q "$expected_stderr"; then
    echo "FAIL: $desc (expected '$expected_stderr' in output, got: $output)"
    fail=$((fail + 1))
    return
  fi
  echo "PASS: $desc"
  pass=$((pass + 1))
}

# Setup: work in a temp directory to avoid polluting the repo
WORK_DIR=$(mktemp -d /tmp/capture-test-work.XXXXXX)
cleanup() { rm -rf "$WORK_DIR"; }
trap cleanup EXIT
cd "$WORK_DIR"

# Test: Absent route-map → visual_eval_inapplicable:route_map_missing
assert_exit_contains \
  "Missing route-map → inapplicable" 1 "route_map_missing" \
  bash "$CAPTURE"

# Test: Route-map exists but is stale (>24h)
mkdir -p .ui-discovery-cache
echo '[]' > .ui-discovery-cache/route-map.json
touch -t 202501010000 .ui-discovery-cache/route-map.json
assert_exit_contains \
  "Stale route-map → inapplicable" 1 "route_map_stale" \
  bash "$CAPTURE"

# Test: Fresh route-map but no local server running
# Shadow curl so all server probes fail
echo '[{"path": "/"}]' > .ui-discovery-cache/route-map.json
touch .ui-discovery-cache/route-map.json  # reset mtime to now
mkdir -p "$WORK_DIR/fake-bin"
printf '#!/bin/sh\nexit 1\n' > "$WORK_DIR/fake-bin/curl"
chmod +x "$WORK_DIR/fake-bin/curl"
assert_exit_contains \
  "No local server → inapplicable" 1 "no_local_server" \
  env PATH="$WORK_DIR/fake-bin:$PATH" bash "$CAPTURE"

# Test: Empty route-map (no routes) — server irrelevant since we check routes before capture
# This case actually hits no_local_server first because server check comes before route parsing
# That's correct behavior — gating order is: route-map exists → fresh → server reachable → routes exist

echo ""
echo "Results: $pass passed, $fail failed"
[[ $fail -eq 0 ]] || exit 1
