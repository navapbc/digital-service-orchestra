#!/usr/bin/env bash
# tests/scripts/test-wrapper-detection.sh
# Behavioral tests for the wrapper detection snippet used in .claude/commands/ files.
#
# The detection snippet detects whether the DSO marketplace plugin is installed
# via `claude plugin list`. These tests exercise the snippet with mock claude
# binaries to verify correct detection and fallback behavior.
#
# Usage: bash tests/scripts/test-wrapper-detection.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-wrapper-detection.sh ==="

TMPDIR_BASE="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_BASE"' EXIT

# The detection snippet embedded in .claude/commands/ wrapper files.
# This is the canonical snippet — wrapper files will use this exact pattern.
DETECTION_SNIPPET='timeout 3 claude plugin list 2>/dev/null | grep -q "digital-service-orchestra" && echo "PLUGIN_DETECTED" || echo "LOCAL_FALLBACK"'

# ── test_detection_finds_installed_plugin ─────────────────────────────────────
# Mock claude returns "digital-service-orchestra" → PLUGIN_DETECTED
test_detection_finds_installed_plugin() {
    local mock_dir="$TMPDIR_BASE/mock-installed"
    mkdir -p "$mock_dir"
    cat > "$mock_dir/claude" <<'MOCK'
#!/usr/bin/env bash
if [[ "${1:-}" == "plugin" && "${2:-}" == "list" ]]; then
    echo "digital-service-orchestra"
    exit 0
fi
exit 1
MOCK
    chmod +x "$mock_dir/claude"

    local result
    result=$(PATH="$mock_dir:$PATH" bash -c "$DETECTION_SNIPPET" 2>/dev/null) || true
    assert_eq "test_detection_finds_installed_plugin" "PLUGIN_DETECTED" "$result"
}

# ── test_detection_falls_back_when_no_plugin ──────────────────────────────────
# Mock claude returns empty list → LOCAL_FALLBACK
test_detection_falls_back_when_no_plugin() {
    local mock_dir="$TMPDIR_BASE/mock-empty"
    mkdir -p "$mock_dir"
    cat > "$mock_dir/claude" <<'MOCK'
#!/usr/bin/env bash
if [[ "${1:-}" == "plugin" && "${2:-}" == "list" ]]; then
    echo ""
    exit 0
fi
exit 1
MOCK
    chmod +x "$mock_dir/claude"

    local result
    result=$(PATH="$mock_dir:$PATH" bash -c "$DETECTION_SNIPPET" 2>/dev/null) || true
    assert_eq "test_detection_falls_back_when_no_plugin" "LOCAL_FALLBACK" "$result"
}

# ── test_detection_falls_back_on_command_failure ──────────────────────────────
# Mock claude exits non-zero → LOCAL_FALLBACK
test_detection_falls_back_on_command_failure() {
    local mock_dir="$TMPDIR_BASE/mock-failure"
    mkdir -p "$mock_dir"
    cat > "$mock_dir/claude" <<'MOCK'
#!/usr/bin/env bash
exit 1
MOCK
    chmod +x "$mock_dir/claude"

    local result
    result=$(PATH="$mock_dir:$PATH" bash -c "$DETECTION_SNIPPET" 2>/dev/null) || true
    assert_eq "test_detection_falls_back_on_command_failure" "LOCAL_FALLBACK" "$result"
}

# ── test_detection_falls_back_when_no_binary ──────────────────────────────────
# No claude binary on PATH at all → LOCAL_FALLBACK
test_detection_falls_back_when_no_binary() {
    local result
    result=$(PATH="/usr/bin:/bin" bash -c "$DETECTION_SNIPPET" 2>/dev/null) || true
    assert_eq "test_detection_falls_back_when_no_binary" "LOCAL_FALLBACK" "$result"
}

# ── Run all tests ─────────────────────────────────────────────────────────────
test_detection_finds_installed_plugin
test_detection_falls_back_when_no_plugin
test_detection_falls_back_on_command_failure
test_detection_falls_back_when_no_binary

print_summary
