#!/usr/bin/env bash
# Tests for visual-eval-preconditions.sh (Item 2a: Shared precondition gates)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PRECOND="$REPO_ROOT/plugins/dso/scripts/sprint/visual-eval-preconditions.sh"

pass=0
fail=0

assert_exit_reason() {
  local desc="$1" expected_exit="$2" expected_reason="$3"
  shift 3
  local output
  output=$("$@" 2>/dev/null) || true
  local actual_exit=$?
  # Re-run to get actual exit code
  if "$@" >/dev/null 2>&1; then
    actual_exit=0
  else
    actual_exit=$?
  fi
  output=$("$@" 2>/dev/null) || true

  if [[ "$actual_exit" -ne "$expected_exit" ]]; then
    echo "FAIL: $desc (expected exit $expected_exit, got $actual_exit; output: $output)"
    fail=$((fail + 1))
    return
  fi
  if [[ -n "$expected_reason" ]] && [[ "$output" != *"$expected_reason"* ]]; then
    echo "FAIL: $desc (expected reason '$expected_reason', got: $output)"
    fail=$((fail + 1))
    return
  fi
  echo "PASS: $desc"
  pass=$((pass + 1))
}

# Setup controlled environment
WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/precond-test.XXXXXX")
cleanup() { rm -rf "$WORK_DIR"; }
trap cleanup EXIT
cd "$WORK_DIR"

mkdir -p .claude fake-plugin/scripts

# Create minimal read-config
cat > fake-plugin/scripts/read-config.sh << 'READCONF'
#!/usr/bin/env bash
key="$1"
config=".claude/dso-config.conf"
[[ -f "$config" ]] || exit 0
grep "^${key}=" "$config" 2>/dev/null | cut -d= -f2- || true
READCONF
chmod +x fake-plugin/scripts/read-config.sh

# Test 1: visual_evaluator.enabled=false → not_enabled
echo 'visual_evaluator.enabled=false' > .claude/dso-config.conf
assert_exit_reason \
  "Disabled → not_enabled" 1 "not_enabled" \
  env CLAUDE_PLUGIN_ROOT="$WORK_DIR/fake-plugin" bash "$PRECOND"

# Test 2: enabled but project.type=cli → not_web_project
echo -e 'visual_evaluator.enabled=true\nproject.type=cli' > .claude/dso-config.conf
assert_exit_reason \
  "Non-web project → not_web_project" 1 "not_web_project" \
  env CLAUDE_PLUGIN_ROOT="$WORK_DIR/fake-plugin" bash "$PRECOND"

# Test 3: enabled + web but no Playwright → playwright_unavailable
echo -e 'visual_evaluator.enabled=true\nproject.type=web' > .claude/dso-config.conf
mkdir -p "$WORK_DIR/fake-bin"
printf '#!/bin/sh\nexit 1\n' > "$WORK_DIR/fake-bin/npx"
chmod +x "$WORK_DIR/fake-bin/npx"
assert_exit_reason \
  "No Playwright → playwright_unavailable" 1 "playwright_unavailable" \
  env CLAUDE_PLUGIN_ROOT="$WORK_DIR/fake-plugin" PATH="$WORK_DIR/fake-bin:$PATH" bash "$PRECOND"

# Test 4: check-local-env.sh fails → local_env_check_failed
printf '#!/bin/sh\nexit 1\n' > "$WORK_DIR/fake-plugin/scripts/check-local-env.sh"
chmod +x "$WORK_DIR/fake-plugin/scripts/check-local-env.sh"
# Need npx to pass — create one that succeeds for --version
cat > "$WORK_DIR/fake-bin/npx" << 'NPX'
#!/bin/sh
if [ "$1" = "--no-install" ] && [ "$2" = "playwright" ] && [ "$3" = "--version" ]; then
  echo "1.40.0"
  exit 0
fi
exit 1
NPX
chmod +x "$WORK_DIR/fake-bin/npx"
assert_exit_reason \
  "Local env check failed → local_env_check_failed" 1 "local_env_check_failed" \
  env CLAUDE_PLUGIN_ROOT="$WORK_DIR/fake-plugin" PATH="$WORK_DIR/fake-bin:$PATH" bash "$PRECOND"

# Test 5: route-map missing + --route-map-required → route_map_missing
# Fix check-local-env to pass
printf '#!/bin/sh\nexit 0\n' > "$WORK_DIR/fake-plugin/scripts/check-local-env.sh"
assert_exit_reason \
  "Route-map missing + required → route_map_missing" 1 "route_map_missing" \
  env CLAUDE_PLUGIN_ROOT="$WORK_DIR/fake-plugin" PATH="$WORK_DIR/fake-bin:$PATH" bash "$PRECOND" --route-map-required

# Test 6: All gates pass → exit 0
mkdir -p .ui-discovery-cache
echo '[]' > .ui-discovery-cache/route-map.json
touch .ui-discovery-cache/route-map.json
assert_exit_reason \
  "All gates pass → exit 0" 0 "" \
  env CLAUDE_PLUGIN_ROOT="$WORK_DIR/fake-plugin" PATH="$WORK_DIR/fake-bin:$PATH" bash "$PRECOND" --route-map-required

echo ""
echo "Results: $pass passed, $fail failed"
[[ $fail -eq 0 ]] || exit 1
