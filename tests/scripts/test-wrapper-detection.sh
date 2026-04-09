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
DETECTION_SNIPPET='_dso_out=$(timeout 3 claude plugin list 2>/dev/null); [[ "$_dso_out" == *"digital-service-orchestra"* ]] && echo "PLUGIN_DETECTED" || echo "LOCAL_FALLBACK"'

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

# ── test_wrapper_references_correct_skill ────────────────────────────────────
# Each .claude/commands/<skill>.md must reference /dso:<skill> by name.
# This confirms the wrapper file routes to the correct skill.
test_wrapper_references_correct_skill() {
    local commands_dir="$PLUGIN_ROOT/.claude/commands"
    local skills=(brainstorm sprint fix-bug debug-everything preplanning)
    local all_pass=1

    for skill in "${skills[@]}"; do
        local wrapper="$commands_dir/${skill}.md"
        if [[ ! -f "$wrapper" ]]; then
            (( ++FAIL ))
            printf "FAIL: test_wrapper_references_correct_skill\n  missing wrapper: %s\n" "$wrapper" >&2
            all_pass=0
            continue
        fi
        if grep -q "dso:${skill}" "$wrapper"; then
            (( ++PASS ))
        else
            (( ++FAIL ))
            printf "FAIL: test_wrapper_references_correct_skill\n  %s does not reference dso:%s\n" "$wrapper" "$skill" >&2
            all_pass=0
        fi
    done
}

# ── test_wrappers_contain_skill_tool_failure_fallback ────────────────────────
# Every .claude/commands/<skill>.md must contain a fallback instruction for when
# the Skill tool fails (e.g., "Unknown skill" error). Without this fallback,
# a PLUGIN_DETECTED + Skill-tool-failure scenario causes an infinite loop.
# Structural boundary test per behavioral-testing-standard Rule 5.
test_wrappers_contain_skill_tool_failure_fallback() {
    local commands_dir="$PLUGIN_ROOT/.claude/commands"
    local missing=()

    for wrapper in "$commands_dir"/*.md; do
        [[ -f "$wrapper" ]] || continue
        local name
        name="$(basename "$wrapper" .md)"

        # Each wrapper that uses the PLUGIN_DETECTED/Skill tool path must also
        # have a fallback for Skill tool failure (e.g., "Unknown skill", error).
        if grep -q "PLUGIN_DETECTED" "$wrapper" && ! grep -qi "fail\|error\|unknown skill\|does not work\|cannot\|unable" "$wrapper"; then
            missing+=("$name")
        fi
    done

    if [[ "${#missing[@]}" -eq 0 ]]; then
        (( ++PASS ))
        echo "test_wrappers_contain_skill_tool_failure_fallback ... PASS"
    else
        (( ++FAIL ))
        printf "FAIL: test_wrappers_contain_skill_tool_failure_fallback\n" >&2
        for name in "${missing[@]}"; do
            printf "  %s.md has PLUGIN_DETECTED but no Skill tool failure fallback\n" "$name" >&2
        done
    fi
}

# ── Run all tests ─────────────────────────────────────────────────────────────
test_detection_finds_installed_plugin
test_detection_falls_back_when_no_plugin
test_detection_falls_back_on_command_failure
test_detection_falls_back_when_no_binary
test_wrapper_references_correct_skill
test_wrappers_contain_skill_tool_failure_fallback

print_summary
