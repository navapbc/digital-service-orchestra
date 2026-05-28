#!/usr/bin/env bash
# test-resolve-copy-artifact-path.sh
# Unit tests for resolve-copy-artifact-path.sh
#
# Covers task b7f6-80cd-d9f7-4623 (wire copy.artifact_dir dispatch for gov-copy-writer).
# DDs tested:
#   - Valid config with copy.artifact_dir set: resolves expected path (exit 0)
#   - No config (key absent): falls back to default "copy/" (exit 0)
#   - Absolute path in copy.artifact_dir: rejected (exit non-zero)
#   - Path traversal in copy.artifact_dir: rejected (exit non-zero)
#   - Missing epic_id argument: exits non-zero with usage message
set -euo pipefail

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_PLUGIN_ROOT="$(cd "$_SCRIPT_DIR/../../plugins/dso" && pwd)"

RESOLVER="$_PLUGIN_ROOT/scripts/resolve-copy-artifact-path.sh"

PASS=0
FAIL=0

pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

echo "=== resolve-copy-artifact-path.sh tests ==="

# Prerequisite: script exists and is executable
echo ""
echo "--- prerequisite: script exists and is executable ---"
if [[ -x "$RESOLVER" ]]; then
    pass "script exists and is executable"
else
    fail "script not found or not executable at: $RESOLVER"
    echo "TOTAL: $PASS passed, $FAIL failed"
    exit 1
fi

# ── Test helpers ─────────────────────────────────────────────────────────────

# Create a temp project root and an optional dso-config.conf
make_project_root() {
    local root
    root=$(mktemp -d "${TMPDIR:-/tmp}/resolve-cap-test.XXXXXX")
    echo "$root"
}

write_config() {
    local root="$1" content="$2"
    mkdir -p "$root/.claude"
    printf '%s\n' "$content" > "$root/.claude/dso-config.conf"
}

cleanup() {
    rm -rf "$1"
}

# ── Test 1: custom copy.artifact_dir resolves expected path (exit 0) ─────────
echo ""
echo "--- test: custom copy.artifact_dir set in config ---"
_root=$(make_project_root)
write_config "$_root" "copy.artifact_dir=artifacts/copy/"
_out=$(WORKFLOW_CONFIG_FILE="$_root/.claude/dso-config.conf" \
    bash "$RESOLVER" "f360-3a5b-b8f3-4f86" --project-root "$_root" 2>/dev/null)
if [[ "$_out" == *"f360-3a5b-b8f3-4f86.yaml" && "$_out" == *"artifacts/copy"* ]]; then
    pass "custom artifact_dir resolves to <dir>/<epic_id>.yaml"
else
    fail "unexpected output from custom artifact_dir: '$_out'"
fi
cleanup "$_root"

# ── Test 2: no config → fallback to default "copy/" (exit 0) ─────────────────
echo ""
echo "--- test: no config — defaults to 'copy/' ---"
_root=$(make_project_root)
# Provide a config file with an unrelated key so read-config.sh gets a file
# but copy.artifact_dir is absent (triggering the default)
write_config "$_root" "dso.workflow=local"
_out=$(WORKFLOW_CONFIG_FILE="$_root/.claude/dso-config.conf" \
    bash "$RESOLVER" "abc-123-def-456" --project-root "$_root" 2>/dev/null)
if [[ "$_out" == *"abc-123-def-456.yaml" && "$_out" == *"/copy/"* ]]; then
    pass "absent copy.artifact_dir falls back to 'copy/'"
else
    fail "unexpected output from default fallback: '$_out'"
fi
cleanup "$_root"

# ── Test 3: missing config file → fallback to default "copy/" (exit 0) ───────
echo ""
echo "--- test: missing config file — defaults to 'copy/' ---"
_root=$(make_project_root)
# No .claude/dso-config.conf at all; read-config.sh will exit 0 with empty output
_out=$(WORKFLOW_CONFIG_FILE="$_root/.claude/dso-config.conf" \
    bash "$RESOLVER" "epic-no-config" --project-root "$_root" 2>/dev/null)
if [[ "$_out" == *"epic-no-config.yaml" && "$_out" == *"/copy/"* ]]; then
    pass "missing config file falls back to 'copy/'"
else
    fail "unexpected output when config file missing: '$_out'"
fi
cleanup "$_root"

# ── Test 4: absolute path in copy.artifact_dir → rejected (exit non-zero) ────
echo ""
echo "--- test: absolute path in copy.artifact_dir is rejected ---"
_root=$(make_project_root)
write_config "$_root" "copy.artifact_dir=/etc/evil/"
if WORKFLOW_CONFIG_FILE="$_root/.claude/dso-config.conf" \
    bash "$RESOLVER" "some-epic" --project-root "$_root" >/dev/null 2>&1; then
    fail "absolute artifact_dir should be rejected but was accepted"
else
    pass "absolute artifact_dir correctly rejected (exit non-zero)"
fi
cleanup "$_root"

# ── Test 5: path traversal in copy.artifact_dir → rejected (exit non-zero) ───
echo ""
echo "--- test: path traversal in copy.artifact_dir is rejected ---"
_root=$(make_project_root)
write_config "$_root" "copy.artifact_dir=../../outside/"
if WORKFLOW_CONFIG_FILE="$_root/.claude/dso-config.conf" \
    bash "$RESOLVER" "some-epic" --project-root "$_root" >/dev/null 2>&1; then
    fail "traversal artifact_dir should be rejected but was accepted"
else
    pass "traversal artifact_dir correctly rejected (exit non-zero)"
fi
cleanup "$_root"

# ── Test 6: missing epic_id argument → exits non-zero ────────────────────────
echo ""
echo "--- test: missing epic_id argument exits non-zero ---"
if bash "$RESOLVER" >/dev/null 2>&1; then
    fail "missing epic_id should exit non-zero but did not"
else
    pass "missing epic_id argument exits non-zero"
fi

# ── Test 7: resolved path is absolute ────────────────────────────────────────
echo ""
echo "--- test: output path is absolute ---"
_root=$(make_project_root)
write_config "$_root" "dso.workflow=local"
_out=$(WORKFLOW_CONFIG_FILE="$_root/.claude/dso-config.conf" \
    bash "$RESOLVER" "my-epic" --project-root "$_root" 2>/dev/null)
if [[ "$_out" == /* ]]; then
    pass "resolved artifact path is absolute"
else
    fail "resolved artifact path is not absolute: '$_out'"
fi
cleanup "$_root"

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "TOTAL: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
