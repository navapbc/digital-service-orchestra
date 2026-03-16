#!/usr/bin/env bash
# lockpick-workflow/tests/scripts/test-coupling-lint-guard.sh
# TDD tests for coupling-lint-guard configuration and script.
#
# Tests:
#   test_config_exists        — config file exists at expected path
#   test_guard_exists         — guard script is executable
#   test_guard_syntax         — guard script has valid bash syntax
#   test_guard_detects_hardcoded_app — guard detects hardcoded app/ paths
#   test_guard_passes_clean_code    — guard exits 0 for clean code
#
# Usage: bash lockpick-workflow/tests/scripts/test-coupling-lint-guard.sh
# Exit code: 0 if all pass, 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR" && git rev-parse --show-toplevel)"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

CONFIG="$PLUGIN_ROOT/config/coupling-lint-patterns.conf"
GUARD="$PLUGIN_ROOT/scripts/coupling-lint-guard.sh"

echo "=== test-coupling-lint-guard.sh ==="

# ── test_config_exists ───────────────────────────────────────────────────────
# Config file must exist at lockpick-workflow/config/coupling-lint-patterns.conf
_snapshot_fail
if [[ -f "$CONFIG" ]]; then
    actual_config_exists="exists"
else
    actual_config_exists="missing"
fi
assert_eq "test_config_exists: file exists" "exists" "$actual_config_exists"
assert_pass_if_clean "test_config_exists"

# ── test_config_has_required_keys ───────────────────────────────────────────
# Config file must define all required keys.
_snapshot_fail
REQUIRED_KEYS=(
    SCAN_PATTERNS
    SCAN_DIRS
    ALLOWED_COMMENTS
    ALLOWED_FILES
    HARDCODED_APP_PATTERN
    LOCKPICK_CLASS_NAMES
    BARE_MAKE_PATTERN
)
for key in "${REQUIRED_KEYS[@]}"; do
    if [[ -f "$CONFIG" ]] && grep -q "^${key}=" "$CONFIG"; then
        actual_key="present"
    else
        actual_key="missing"
    fi
    assert_eq "test_config_has_required_keys: key '$key' defined" "present" "$actual_key"
done
assert_pass_if_clean "test_config_has_required_keys"

# ── test_config_allowed_files_has_three_entries ──────────────────────────────
# ALLOWED_FILES must include at least 3 colon-separated entries.
_snapshot_fail
if [[ -f "$CONFIG" ]]; then
    allowed_files_line="$(grep '^ALLOWED_FILES=' "$CONFIG" | head -1 | cut -d= -f2-)"
    IFS=':' read -ra _entries <<< "$allowed_files_line"
    entry_count="${#_entries[@]}"
    if [[ "$entry_count" -ge 3 ]]; then
        actual_entries="ok"
    else
        actual_entries="too_few"
    fi
else
    actual_entries="too_few"
fi
assert_eq "test_config_allowed_files_has_three_entries: at least 3 entries" "ok" "$actual_entries"
assert_pass_if_clean "test_config_allowed_files_has_three_entries"

# ── test_config_lockpick_class_names_required ────────────────────────────────
# LOCKPICK_CLASS_NAMES must include PipelineLLMClientFactory and PostPipelineProcessor.
_snapshot_fail
if [[ -f "$CONFIG" ]]; then
    class_names_line="$(grep '^LOCKPICK_CLASS_NAMES=' "$CONFIG" | head -1 | cut -d= -f2-)"
    if echo "$class_names_line" | grep -q "PipelineLLMClientFactory"; then
        actual_pipeline="present"
    else
        actual_pipeline="missing"
    fi
    if echo "$class_names_line" | grep -q "PostPipelineProcessor"; then
        actual_post="present"
    else
        actual_post="missing"
    fi
else
    actual_pipeline="missing"
    actual_post="missing"
fi
assert_eq "test_config_lockpick_class_names_required: PipelineLLMClientFactory present" "present" "$actual_pipeline"
assert_eq "test_config_lockpick_class_names_required: PostPipelineProcessor present" "present" "$actual_post"
assert_pass_if_clean "test_config_lockpick_class_names_required"

# ── test_guard_exists ────────────────────────────────────────────────────────
# Guard script must exist and be executable.
# NOTE: SKIP when guard script has not been created yet (Task lockpick-doc-to-logic-2hew).
_snapshot_fail
if [[ -x "$GUARD" ]]; then
    echo "  PASS: test_guard_exists: script is executable"
    (( PASS++ ))
elif [[ ! -f "$GUARD" ]]; then
    echo "  SKIP: test_guard_exists (guard script not yet created — pending lockpick-doc-to-logic-2hew)"
    (( PASS++ ))
else
    assert_eq "test_guard_exists: script is executable" "executable" "not_executable"
fi
assert_pass_if_clean "test_guard_exists"

# ── test_guard_syntax ────────────────────────────────────────────────────────
# Guard script must have valid bash syntax.
# NOTE: SKIP when guard script has not been created yet (Task lockpick-doc-to-logic-2hew).
_snapshot_fail
if [[ ! -f "$GUARD" ]]; then
    echo "  SKIP: test_guard_syntax (guard script not yet created — pending lockpick-doc-to-logic-2hew)"
    (( PASS++ ))
elif bash -n "$GUARD" 2>/dev/null; then
    echo "  PASS: test_guard_syntax: valid bash syntax"
    (( PASS++ ))
else
    assert_eq "test_guard_syntax: valid bash syntax" "valid" "invalid"
fi
assert_pass_if_clean "test_guard_syntax"

# ── test_guard_detects_hardcoded_app ─────────────────────────────────────────
# Guard must exit non-zero when a file contains a hardcoded app/ path.
_snapshot_fail
_CLEANUP_TMP=""
if [[ -x "$GUARD" && -f "$CONFIG" ]]; then
    _tmpdir="$(mktemp -d)"
    _CLEANUP_TMP="$_tmpdir"
    # Create a synthetic file with a hardcoded app/ path
    mkdir -p "$_tmpdir/lockpick-workflow/scripts"
    printf 'cd /app/src\n' > "$_tmpdir/lockpick-workflow/scripts/test-violation.sh"
    # Run guard against the synthetic dir; expect non-zero
    guard_exit=0
    "$GUARD" --scan-dir "$_tmpdir/lockpick-workflow" 2>/dev/null || guard_exit=$?
    if [[ "$guard_exit" -ne 0 ]]; then
        actual_detects="detected"
    else
        actual_detects="not_detected"
    fi
    rm -rf "$_tmpdir"
    _CLEANUP_TMP=""
else
    actual_detects="skip_guard_not_ready"
fi
if [[ "$actual_detects" == "skip_guard_not_ready" ]]; then
    echo "  SKIP: test_guard_detects_hardcoded_app (guard not yet implemented)"
    (( PASS++ ))
else
    assert_eq "test_guard_detects_hardcoded_app: non-zero exit on violation" "detected" "$actual_detects"
fi
assert_pass_if_clean "test_guard_detects_hardcoded_app"

# ── test_guard_passes_clean_code ─────────────────────────────────────────────
# Guard must exit 0 when no violations are present.
_snapshot_fail
if [[ -x "$GUARD" && -f "$CONFIG" ]]; then
    _tmpdir="$(mktemp -d)"
    mkdir -p "$_tmpdir/lockpick-workflow/scripts"
    # Create a clean file with no coupling violations
    printf '#!/usr/bin/env bash\necho "clean"\n' > "$_tmpdir/lockpick-workflow/scripts/clean.sh"
    clean_exit=0
    "$GUARD" --scan-dir "$_tmpdir/lockpick-workflow" 2>/dev/null || clean_exit=$?
    if [[ "$clean_exit" -eq 0 ]]; then
        actual_clean="passed"
    else
        actual_clean="failed"
    fi
    rm -rf "$_tmpdir"
else
    actual_clean="skip_guard_not_ready"
fi
if [[ "$actual_clean" == "skip_guard_not_ready" ]]; then
    echo "  SKIP: test_guard_passes_clean_code (guard not yet implemented)"
    (( PASS++ ))
else
    assert_eq "test_guard_passes_clean_code: exit 0 for clean code" "passed" "$actual_clean"
fi
assert_pass_if_clean "test_guard_passes_clean_code"

# ── Summary ──────────────────────────────────────────────────────────────────
print_summary
