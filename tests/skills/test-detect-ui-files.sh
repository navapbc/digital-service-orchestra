#!/usr/bin/env bash
# Tests for detect-ui-files.sh (Story 1: UI-File Detection Gate)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DETECT="$REPO_ROOT/plugins/dso/scripts/detect-ui-files.sh"

pass=0
fail=0

assert_exit() {
  local desc="$1" expected="$2"
  shift 2
  if "$@" >/dev/null 2>&1; then
    actual=0
  else
    actual=$?
  fi
  if [[ "$actual" -eq "$expected" ]]; then
    echo "PASS: $desc"
    pass=$((pass + 1))
  else
    echo "FAIL: $desc (expected exit $expected, got $actual)"
    fail=$((fail + 1))
  fi
}

assert_exit_stdin() {
  local desc="$1" expected="$2" input="$3"
  if echo "$input" | bash "$DETECT" >/dev/null 2>&1; then
    actual=0
  else
    actual=$?
  fi
  if [[ "$actual" -eq "$expected" ]]; then
    echo "PASS: $desc"
    pass=$((pass + 1))
  else
    echo "FAIL: $desc (expected exit $expected, got $actual)"
    fail=$((fail + 1))
  fi
}

# Test: Pure Python changes → exit 1
assert_exit "Pure Python → no UI" 1 bash "$DETECT" "src/main.py" "src/utils.py" "tests/test_main.py"

# Test: Mixed Python+CSS → exit 0
assert_exit "Mixed Python+CSS → UI detected" 0 bash "$DETECT" "src/main.py" "static/styles.css"

# Test: Template-only → exit 0
assert_exit "Template-only → UI detected" 0 bash "$DETECT" "templates/index.jinja2"

# Test: SKILL.md-only → exit 1
assert_exit "SKILL.md-only → no UI" 1 bash "$DETECT" "plugins/dso/skills/sprint/SKILL.md"

# Test: Empty file list → exit 1
assert_exit "Empty args → no UI" 1 bash "$DETECT"

# Test: stdin mode with CSS file
assert_exit_stdin "stdin CSS file → UI detected" 0 "src/app.css"

# Test: stdin mode with only .py files
assert_exit_stdin "stdin Python-only → no UI" 1 "src/app.py
lib/utils.py"

# Test: Directory pattern match (components/)
assert_exit "components/ dir → UI detected" 0 bash "$DETECT" "src/components/Button.py"

# Test: Frontend directory pattern
assert_exit "frontend/ dir → UI detected" 0 bash "$DETECT" "frontend/App.tsx"

# Test: .tsx extension match
assert_exit "TSX extension → UI detected" 0 bash "$DETECT" "src/Dashboard.tsx"

# Test: .vue extension match
assert_exit "Vue extension → UI detected" 0 bash "$DETECT" "src/Header.vue"

echo ""
echo "Results: $pass passed, $fail failed"
[[ $fail -eq 0 ]] || exit 1
