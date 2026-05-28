#!/usr/bin/env bash
# Tests for visual-eval-inline.sh (Story 5: Integration A Wiring)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
INLINE="$REPO_ROOT/plugins/dso/scripts/sprint/visual-eval-inline.sh"

pass=0
fail=0

assert_exit() {
  local desc="$1" expected_exit="$2"
  shift 2
  local tmpfile
  tmpfile=$(mktemp "${TMPDIR:-/tmp}/inline-test.XXXXXX")
  if "$@" >"$tmpfile" 2>&1; then
    actual=0
  else
    actual=$?
  fi
  local output
  output=$(cat "$tmpfile")
  rm -f "$tmpfile"

  if [[ "$actual" -ne "$expected_exit" ]]; then
    echo "FAIL: $desc (expected exit $expected_exit, got $actual; output: $output)"
    fail=$((fail + 1))
    return
  fi
  echo "PASS: $desc"
  pass=$((pass + 1))
}

assert_exit_stderr() {
  local desc="$1" expected_exit="$2" expected_stderr="$3"
  shift 3
  local tmpfile
  tmpfile=$(mktemp "${TMPDIR:-/tmp}/inline-test.XXXXXX")
  if "$@" 2>"$tmpfile" >/dev/null; then
    actual=0
  else
    actual=$?
  fi
  local stderr_output
  stderr_output=$(cat "$tmpfile")
  rm -f "$tmpfile"

  if [[ "$actual" -ne "$expected_exit" ]]; then
    echo "FAIL: $desc (expected exit $expected_exit, got $actual; stderr: $stderr_output)"
    fail=$((fail + 1))
    return
  fi
  if [[ -n "$expected_stderr" ]] && ! echo "$stderr_output" | grep -q "$expected_stderr"; then
    echo "FAIL: $desc (expected '$expected_stderr' in stderr, got: $stderr_output)"
    fail=$((fail + 1))
    return
  fi
  echo "PASS: $desc"
  pass=$((pass + 1))
}

# Setup controlled environment
WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/inline-test-work.XXXXXX")
cleanup() { rm -rf "$WORK_DIR"; }
trap cleanup EXIT

mkdir -p "$WORK_DIR/.claude"
mkdir -p "$WORK_DIR/fake-plugin/scripts/sprint"

cat > "$WORK_DIR/fake-plugin/scripts/read-config.sh" << 'READCONF'
#!/usr/bin/env bash
key="$1"
config=".claude/dso-config.conf"
[[ -f "$config" ]] || exit 0
grep "^${key}=" "$config" 2>/dev/null | cut -d= -f2- || true
READCONF
chmod +x "$WORK_DIR/fake-plugin/scripts/read-config.sh"
cp "$REPO_ROOT/plugins/dso/scripts/detect-ui-files.sh" "$WORK_DIR/fake-plugin/scripts/"

cd "$WORK_DIR"

# --- Gating tests ---

# Test 1: Feature disabled (default) → silent exit 0
echo 'visual_evaluator.integration_a_enabled=false' > .claude/dso-config.conf
assert_exit \
  "Disabled flag → silent skip" 0 \
  env CLAUDE_PLUGIN_ROOT="$WORK_DIR/fake-plugin" bash "$INLINE" "src/app.css"

# Test 2: Enabled but no file list → exit 0
echo 'visual_evaluator.integration_a_enabled=true' > .claude/dso-config.conf
assert_exit \
  "Enabled but empty file list → skip" 0 \
  env CLAUDE_PLUGIN_ROOT="$WORK_DIR/fake-plugin" bash "$INLINE" ""

# Test 3: Enabled but only Python files → exit 0
assert_exit \
  "Enabled + Python-only → skip" 0 \
  env CLAUDE_PLUGIN_ROOT="$WORK_DIR/fake-plugin" bash "$INLINE" "main.py"

# Test 4: Enabled + CSS file but preconditions fail → exit 0
cat > "$WORK_DIR/fake-plugin/scripts/sprint/visual-eval-preconditions.sh" << 'PRECOND'
#!/usr/bin/env bash
echo "not_web_project"
exit 1
PRECOND
chmod +x "$WORK_DIR/fake-plugin/scripts/sprint/visual-eval-preconditions.sh"
assert_exit \
  "Enabled + CSS + preconditions fail → inapplicable" 0 \
  env CLAUDE_PLUGIN_ROOT="$WORK_DIR/fake-plugin" bash "$INLINE" "app.css"

# --- Iteration tests (mock capture + eval) ---

# Create preconditions that pass
cat > "$WORK_DIR/fake-plugin/scripts/sprint/visual-eval-preconditions.sh" << 'PRECOND'
#!/usr/bin/env bash
exit 0
PRECOND
chmod +x "$WORK_DIR/fake-plugin/scripts/sprint/visual-eval-preconditions.sh"

# Create fake capture-screenshots.sh that creates a fresh dir each call
cat > "$WORK_DIR/fake-plugin/scripts/capture-screenshots.sh" << 'CAPTURE'
#!/usr/bin/env bash
DIR=$(mktemp -d "${TMPDIR:-/tmp}/fake-inline-capture.XXXXXX")
printf '\x89PNG\r\n\x1a\n' > "$DIR/index.png"
echo "$DIR"
CAPTURE
chmod +x "$WORK_DIR/fake-plugin/scripts/capture-screenshots.sh"

# Test 5: intent_match passes on first iteration
echo -e 'visual_evaluator.integration_a_enabled=true\nvisual_evaluator.iteration_cap=2\nvisual_evaluator.iteration_threshold=3' > .claude/dso-config.conf
cat > "$WORK_DIR/fake-plugin/scripts/visual-eval-run.py" << 'EVALPY'
#!/usr/bin/env python3
import json, sys
print(json.dumps({
    "scores": {"whitespace_balance": 4, "element_density": 4, "visual_hierarchy_legibility": 4, "alignment_grid_adherence": 4, "intent_match": 4},
    "findings": [],
    "attribution_class": "implementation_drift",
    "attribution_confidence": "high"
}))
EVALPY
chmod +x "$WORK_DIR/fake-plugin/scripts/visual-eval-run.py"
assert_exit \
  "Intent match passes → exit 0" 0 \
  env CLAUDE_PLUGIN_ROOT="$WORK_DIR/fake-plugin" bash "$INLINE" "app.css"

# Test 6: intent_match fails after cap exhausted
cat > "$WORK_DIR/fake-plugin/scripts/visual-eval-run.py" << 'EVALPY'
#!/usr/bin/env python3
import json, sys
print(json.dumps({
    "scores": {"whitespace_balance": 3, "element_density": 3, "visual_hierarchy_legibility": 3, "alignment_grid_adherence": 3, "intent_match": 2},
    "findings": [],
    "attribution_class": "implementation_drift",
    "attribution_confidence": "high"
}))
EVALPY
chmod +x "$WORK_DIR/fake-plugin/scripts/visual-eval-run.py"
assert_exit \
  "Intent match fails after cap → exit 1" 1 \
  env CLAUDE_PLUGIN_ROOT="$WORK_DIR/fake-plugin" bash "$INLINE" "app.css"

# Test 7: visual_debt annotation emitted
cat > "$WORK_DIR/fake-plugin/scripts/visual-eval-run.py" << 'EVALPY'
#!/usr/bin/env python3
import json, sys
print(json.dumps({
    "scores": {"whitespace_balance": 2, "element_density": 4, "visual_hierarchy_legibility": 4, "alignment_grid_adherence": 4, "intent_match": 4},
    "findings": [],
    "attribution_class": "implementation_drift",
    "attribution_confidence": "high"
}))
EVALPY
chmod +x "$WORK_DIR/fake-plugin/scripts/visual-eval-run.py"
assert_exit_stderr \
  "Visual debt annotation emitted" 0 "visual_debt:whitespace_balance" \
  env CLAUDE_PLUGIN_ROOT="$WORK_DIR/fake-plugin" bash "$INLINE" "app.css"

echo ""
echo "Results: $pass passed, $fail failed"
[[ $fail -eq 0 ]] || exit 1
