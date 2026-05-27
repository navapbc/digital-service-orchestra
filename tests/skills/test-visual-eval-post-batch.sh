#!/usr/bin/env bash
# Tests for visual-eval-post-batch.sh (Story 4: Integration B Wiring)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
POST_BATCH="$REPO_ROOT/plugins/dso/scripts/sprint/visual-eval-post-batch.sh"

pass=0
fail=0

assert_exit_contains() {
  local desc="$1" expected_exit="$2" expected_output="$3"
  shift 3
  local tmpfile
  tmpfile=$(mktemp /tmp/post-batch-test.XXXXXX)
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
  if [[ -n "$expected_output" ]] && ! echo "$output" | grep -q "$expected_output"; then
    echo "FAIL: $desc (expected '$expected_output' in output, got: $output)"
    fail=$((fail + 1))
    return
  fi
  echo "PASS: $desc"
  pass=$((pass + 1))
}

# Test: Batch with no files → silent exit 0
assert_exit_contains \
  "Empty file list → silent skip" 0 "" \
  bash "$POST_BATCH"

# Test: Batch with Python-only files → silent exit 0 (no UI files)
assert_exit_contains \
  "Python-only batch → skip" 0 "" \
  bash "$POST_BATCH" "src/main.py" "lib/utils.py"

# Controlled environment tests
WORK_DIR=$(mktemp -d /tmp/post-batch-work.XXXXXX)
cleanup() { rm -rf "$WORK_DIR"; }
trap cleanup EXIT

mkdir -p "$WORK_DIR/.claude"
mkdir -p "$WORK_DIR/fake-plugin/scripts/sprint"

# Create read-config
cat > "$WORK_DIR/fake-plugin/scripts/read-config.sh" << 'READCONF'
#!/usr/bin/env bash
key="$1"
config=".claude/dso-config.conf"
[[ -f "$config" ]] || exit 0
grep "^${key}=" "$config" 2>/dev/null | cut -d= -f2- || true
READCONF
chmod +x "$WORK_DIR/fake-plugin/scripts/read-config.sh"
cp "$REPO_ROOT/plugins/dso/scripts/detect-ui-files.sh" "$WORK_DIR/fake-plugin/scripts/"

# Create preconditions that reports not_web_project
cat > "$WORK_DIR/fake-plugin/scripts/sprint/visual-eval-preconditions.sh" << 'PRECOND'
#!/usr/bin/env bash
echo "not_web_project"
exit 1
PRECOND
chmod +x "$WORK_DIR/fake-plugin/scripts/sprint/visual-eval-preconditions.sh"

cd "$WORK_DIR"
echo 'project.type=cli' > .claude/dso-config.conf

# Test: CSS batch + preconditions fail → inapplicable
assert_exit_contains \
  "CSS batch + preconditions fail → inapplicable:not_web_project" 0 "not_web_project" \
  env CLAUDE_PLUGIN_ROOT="$WORK_DIR/fake-plugin" bash "$POST_BATCH" "app.css"

# Test: Token budget hard-stop (mock capture to return large PNGs)
# Create preconditions that pass
cat > "$WORK_DIR/fake-plugin/scripts/sprint/visual-eval-preconditions.sh" << 'PRECOND'
#!/usr/bin/env bash
exit 0
PRECOND
chmod +x "$WORK_DIR/fake-plugin/scripts/sprint/visual-eval-preconditions.sh"

# Create a fake capture-screenshots.sh that produces large files
FAKE_CAPTURE_DIR=$(mktemp -d /tmp/fake-capture.XXXXXX)
for i in $(seq 1 10); do
  dd if=/dev/zero of="$FAKE_CAPTURE_DIR/page_${i}.png" bs=1024 count=500 2>/dev/null
done

cat > "$WORK_DIR/fake-plugin/scripts/capture-screenshots.sh" << CAPTURE
#!/usr/bin/env bash
echo "$FAKE_CAPTURE_DIR"
CAPTURE
chmod +x "$WORK_DIR/fake-plugin/scripts/capture-screenshots.sh"

# Set a very low budget so the hard-stop fires
echo -e 'visual_evaluator.post_batch_token_budget=100\nvisual_evaluator.post_batch_token_hard_stop_multiplier=2' > .claude/dso-config.conf

assert_exit_contains \
  "Token budget hard-stop → budget_exceeded" 0 "budget_exceeded" \
  env CLAUDE_PLUGIN_ROOT="$WORK_DIR/fake-plugin" bash "$POST_BATCH" "styles.css"

rm -rf "$FAKE_CAPTURE_DIR"

echo ""
echo "Results: $pass passed, $fail failed"
[[ $fail -eq 0 ]] || exit 1
