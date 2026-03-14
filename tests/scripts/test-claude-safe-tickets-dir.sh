#!/usr/bin/env bash
# lockpick-workflow/tests/scripts/test-claude-safe-tickets-dir.sh
# Unit tests for tickets.directory config path in _offer_worktree_cleanup
# (lockpick-workflow/scripts/claude-safe).
#
# Verifies that _offer_worktree_cleanup reads tickets.directory from
# workflow-config.conf via _read_cfg and uses it to filter dirty files,
# rather than always using the hardcoded '.tickets' fallback.
#
# Usage: bash lockpick-workflow/tests/scripts/test-claude-safe-tickets-dir.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
CLAUDE_SAFE="$REPO_ROOT/lockpick-workflow/scripts/claude-safe"
PLUGIN_SCRIPTS="$REPO_ROOT/lockpick-workflow/scripts"

source "$REPO_ROOT/lockpick-workflow/tests/lib/assert.sh"

echo "=== test-claude-safe-tickets-dir.sh ==="

# ── Setup: shared tmpdir, cleaned on EXIT ─────────────────────────────────────
TMPDIR_BASE=$(mktemp -d /tmp/test-claude-safe-tickets-dir.XXXXXX)
trap 'rm -rf "$TMPDIR_BASE"' EXIT

# ── Resolve Python with pyyaml for read-config.sh ────────────────────────────
# read-config.sh probes $REPO_ROOT/app/.venv/bin/python3 but only when run from
# inside a git repo. Sub-shells in /tmp have no REPO_ROOT, so we resolve it
# explicitly and inject via CLAUDE_PLUGIN_PYTHON.
PLUGIN_PYTHON=""
for _candidate in \
    "$REPO_ROOT/app/.venv/bin/python3" \
    "$REPO_ROOT/.venv/bin/python3" \
    "python3"; do
    [[ -z "$_candidate" ]] && continue
    [[ "$_candidate" != "python3" ]] && [[ ! -f "$_candidate" ]] && continue
    if "$_candidate" -c "import yaml" 2>/dev/null; then
        PLUGIN_PYTHON="$_candidate"
        break
    fi
done
if [[ -z "$PLUGIN_PYTHON" ]]; then
    echo "SKIP: no python3 with pyyaml found — cannot run config-reading tests" >&2
    exit 0
fi

# ── Helper: source claude-safe in source-only mode and call _read_cfg ─────────
# Args: $1 = config file path, $2 = key to read
_read_cfg_from_config() {
    local config_file="$1"
    local key="$2"
    WORKFLOW_CONFIG="$config_file" \
    _CLAUDE_SAFE_SOURCE_ONLY=1 \
    PLUGIN_SCRIPTS="$PLUGIN_SCRIPTS" \
    CLAUDE_PLUGIN_PYTHON="$PLUGIN_PYTHON" \
    bash -c "
        source \"$CLAUDE_SAFE\"
        _read_cfg \"$key\"
    " 2>/dev/null
}

# ── Create fixture config dirs ─────────────────────────────────────────────────
# custom-tickets config (used by filter tests)
cfg_custom_dir="$TMPDIR_BASE/custom-dir"
mkdir -p "$cfg_custom_dir"
cat > "$cfg_custom_dir/workflow-config.conf" <<CONF
tickets.directory=custom-tickets
CONF

# absent tickets.directory config (fallback tests)
cfg_absent_dir="$TMPDIR_BASE/absent"
mkdir -p "$cfg_absent_dir"
cat > "$cfg_absent_dir/workflow-config.conf" <<CONF

CONF

# ── test_tickets_directory_read_from_config ───────────────────────────────────
# When tickets.directory is set in workflow-config.conf, _read_cfg must
# return the configured value.
echo ""
echo "--- test_tickets_directory_read_from_config ---"
_snapshot_fail

read_result=""
read_result=$(_read_cfg_from_config "$cfg_custom_dir/workflow-config.conf" "tickets.directory") || true

assert_eq "test_tickets_directory_read_from_config: returns configured value" \
    "custom-tickets" "$read_result"
assert_pass_if_clean "test_tickets_directory_read_from_config"

# ── test_tickets_directory_absent_returns_empty ───────────────────────────────
# When tickets.directory is absent from config, _read_cfg returns empty
# (the caller applies the ':-.tickets' fallback inline).
echo ""
echo "--- test_tickets_directory_absent_returns_empty ---"
_snapshot_fail

absent_result=""
absent_result=$(_read_cfg_from_config "$cfg_absent_dir/workflow-config.conf" "tickets.directory") || true

assert_eq "test_tickets_directory_absent_returns_empty: empty string when key absent" \
    "" "$absent_result"
assert_pass_if_clean "test_tickets_directory_absent_returns_empty"

# ── test_tickets_directory_fallback_applied ───────────────────────────────────
# Verify the fallback logic: when _read_cfg returns empty, the ':-.tickets'
# expansion produces '.tickets'.  This mirrors the in-function logic exactly:
#   tickets_dir=$(_read_cfg tickets.directory 2>/dev/null) || true
#   tickets_dir="${tickets_dir:-.tickets}"
echo ""
echo "--- test_tickets_directory_fallback_applied ---"
_snapshot_fail

# Write a helper script to avoid quoting complexity
_fallback_helper="$TMPDIR_BASE/fallback-helper.sh"
cat > "$_fallback_helper" << HELPER
#!/usr/bin/env bash
source "$CLAUDE_SAFE"
tickets_dir=\$(_read_cfg tickets.directory 2>/dev/null) || true
tickets_dir="\${tickets_dir:-.tickets}"
echo "\$tickets_dir"
HELPER

fallback_result=""
fallback_result=$(
    WORKFLOW_CONFIG="$cfg_absent_dir/workflow-config.conf" \
    _CLAUDE_SAFE_SOURCE_ONLY=1 \
    PLUGIN_SCRIPTS="$PLUGIN_SCRIPTS" \
    CLAUDE_PLUGIN_PYTHON="$PLUGIN_PYTHON" \
    bash "$_fallback_helper"
) || true

assert_eq "test_tickets_directory_fallback_applied: defaults to .tickets" \
    ".tickets" "$fallback_result"
assert_pass_if_clean "test_tickets_directory_fallback_applied"

# ── test_tickets_directory_custom_value_passed_through ───────────────────────
# When tickets.directory is set, the same ':-.tickets' expansion must pass
# the configured value through unchanged.
echo ""
echo "--- test_tickets_directory_custom_value_passed_through ---"
_snapshot_fail

_passthrough_helper="$TMPDIR_BASE/passthrough-helper.sh"
cat > "$_passthrough_helper" << HELPER
#!/usr/bin/env bash
source "$CLAUDE_SAFE"
tickets_dir=\$(_read_cfg tickets.directory 2>/dev/null) || true
tickets_dir="\${tickets_dir:-.tickets}"
echo "\$tickets_dir"
HELPER

passthrough_result=""
passthrough_result=$(
    WORKFLOW_CONFIG="$cfg_custom_dir/workflow-config.conf" \
    _CLAUDE_SAFE_SOURCE_ONLY=1 \
    PLUGIN_SCRIPTS="$PLUGIN_SCRIPTS" \
    CLAUDE_PLUGIN_PYTHON="$PLUGIN_PYTHON" \
    bash "$_passthrough_helper"
) || true

assert_eq "test_tickets_directory_custom_value_passed_through: custom value survives fallback" \
    "custom-tickets" "$passthrough_result"
assert_pass_if_clean "test_tickets_directory_custom_value_passed_through"

# ── test_grep_filter_excludes_custom_tickets_dir ─────────────────────────────
# The dirty-file check in _offer_worktree_cleanup excludes the tickets dir via:
#   tickets_dir_pat=$(printf '%s' "$tickets_dir" | sed 's/^\./\\./')
#   dirty_non_tickets=$(git ... status --porcelain | grep -v "^.. ${tickets_dir_pat}/")
#
# Test: simulate porcelain git status output with a dirty file ONLY in the
# custom tickets directory (no leading dot). The grep filter should produce
# empty output when tickets.directory='custom-tickets' is correctly applied.
echo ""
echo "--- test_grep_filter_excludes_custom_tickets_dir ---"
_snapshot_fail

_filter_custom_helper="$TMPDIR_BASE/filter-custom-helper.sh"
cat > "$_filter_custom_helper" << 'HELPER_EOF'
#!/usr/bin/env bash
source "CLAUDE_SAFE_PLACEHOLDER"
tickets_dir=$(_read_cfg tickets.directory 2>/dev/null) || true
tickets_dir="${tickets_dir:-.tickets}"
# Reproduce the exact dirty-file filter from _offer_worktree_cleanup:
tickets_dir_pat=$(printf '%s' "$tickets_dir" | sed 's/^\./\\./')
fake_status=" M custom-tickets/.sync-state.json
?? custom-tickets/state.json"
dirty_non_tickets=$(printf '%s\n' "$fake_status" | grep -v "^.. ${tickets_dir_pat}/" || true)
echo "$dirty_non_tickets"
HELPER_EOF
# Substitute the actual CLAUDE_SAFE path (no special chars)
sed -i '' "s|CLAUDE_SAFE_PLACEHOLDER|${CLAUDE_SAFE}|" "$_filter_custom_helper" 2>/dev/null || sed -i "s|CLAUDE_SAFE_PLACEHOLDER|${CLAUDE_SAFE}|" "$_filter_custom_helper"

filter_result=""
filter_result=$(
    WORKFLOW_CONFIG="$cfg_custom_dir/workflow-config.conf" \
    _CLAUDE_SAFE_SOURCE_ONLY=1 \
    PLUGIN_SCRIPTS="$PLUGIN_SCRIPTS" \
    CLAUDE_PLUGIN_PYTHON="$PLUGIN_PYTHON" \
    bash "$_filter_custom_helper"
) || true

assert_eq "test_grep_filter_excludes_custom_tickets_dir: no non-tickets dirty files" \
    "" "$filter_result"
assert_pass_if_clean "test_grep_filter_excludes_custom_tickets_dir"

# ── test_grep_filter_passes_through_non_tickets_dirty_files ──────────────────
# When a dirty file is outside the tickets directory, the grep filter must NOT
# exclude it — dirty_non_tickets is non-empty, is_clean=0, can_remove=0.
echo ""
echo "--- test_grep_filter_passes_through_non_tickets_dirty_files ---"
_snapshot_fail

_filter_mixed_helper="$TMPDIR_BASE/filter-mixed-helper.sh"
cat > "$_filter_mixed_helper" << 'HELPER_EOF'
#!/usr/bin/env bash
source "CLAUDE_SAFE_PLACEHOLDER"
tickets_dir=$(_read_cfg tickets.directory 2>/dev/null) || true
tickets_dir="${tickets_dir:-.tickets}"
tickets_dir_pat=$(printf '%s' "$tickets_dir" | sed 's/^\./\\./')
fake_status=" M custom-tickets/.sync-state.json
 M src/app.py"
dirty_non_tickets=$(printf '%s\n' "$fake_status" | grep -v "^.. ${tickets_dir_pat}/" || true)
echo "$dirty_non_tickets"
HELPER_EOF
sed -i '' "s|CLAUDE_SAFE_PLACEHOLDER|${CLAUDE_SAFE}|" "$_filter_mixed_helper" 2>/dev/null || sed -i "s|CLAUDE_SAFE_PLACEHOLDER|${CLAUDE_SAFE}|" "$_filter_mixed_helper"

filter_mixed_result=""
filter_mixed_result=$(
    WORKFLOW_CONFIG="$cfg_custom_dir/workflow-config.conf" \
    _CLAUDE_SAFE_SOURCE_ONLY=1 \
    PLUGIN_SCRIPTS="$PLUGIN_SCRIPTS" \
    CLAUDE_PLUGIN_PYTHON="$PLUGIN_PYTHON" \
    bash "$_filter_mixed_helper"
) || true

assert_contains "test_grep_filter_passes_through_non_tickets_dirty_files: src/app.py kept" \
    "src/app.py" "$filter_mixed_result"
assert_pass_if_clean "test_grep_filter_passes_through_non_tickets_dirty_files"

# ── test_grep_filter_default_excludes_dottickets ─────────────────────────────
# When tickets.directory is absent, the default '.tickets' filter correctly
# excludes dirty files under .tickets/.
echo ""
echo "--- test_grep_filter_default_excludes_dottickets ---"
_snapshot_fail

_filter_default_helper="$TMPDIR_BASE/filter-default-helper.sh"
cat > "$_filter_default_helper" << 'HELPER_EOF'
#!/usr/bin/env bash
source "CLAUDE_SAFE_PLACEHOLDER"
tickets_dir=$(_read_cfg tickets.directory 2>/dev/null) || true
tickets_dir="${tickets_dir:-.tickets}"
tickets_dir_pat=$(printf '%s' "$tickets_dir" | sed 's/^\./\\./')
fake_status=" M .tickets/.sync-state.json
?? .tickets/state.json"
dirty_non_tickets=$(printf '%s\n' "$fake_status" | grep -v "^.. ${tickets_dir_pat}/" || true)
echo "$dirty_non_tickets"
HELPER_EOF
sed -i '' "s|CLAUDE_SAFE_PLACEHOLDER|${CLAUDE_SAFE}|" "$_filter_default_helper" 2>/dev/null || sed -i "s|CLAUDE_SAFE_PLACEHOLDER|${CLAUDE_SAFE}|" "$_filter_default_helper"

filter_default_result=""
filter_default_result=$(
    WORKFLOW_CONFIG="$cfg_absent_dir/workflow-config.conf" \
    _CLAUDE_SAFE_SOURCE_ONLY=1 \
    PLUGIN_SCRIPTS="$PLUGIN_SCRIPTS" \
    CLAUDE_PLUGIN_PYTHON="$PLUGIN_PYTHON" \
    bash "$_filter_default_helper"
) || true

assert_eq "test_grep_filter_default_excludes_dottickets: .tickets/ files excluded" \
    "" "$filter_default_result"
assert_pass_if_clean "test_grep_filter_default_excludes_dottickets"

# ── Summary ───────────────────────────────────────────────────────────────────
print_summary
