#!/usr/bin/env bash
# tests/scripts/test-gate-format-check.sh
# Behavioral RED tests for commands.format_check support in gate-2b and gate-2d
#
# Tests verify that when commands.format_check is configured, each gate:
#   (a) invokes the command (sentinel-based detection), and
#   (b) emits [DSO WARN] when commands.format_check is not configured
#
# All tests FAIL before implementation tasks 1675-2ba3 and 65e9-840f add
# the config-reading code to the respective gate scripts.
#
# Usage: bash tests/scripts/test-gate-format-check.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR" && git rev-parse --show-toplevel)"
GATE2B="$REPO_ROOT/plugins/dso/scripts/gate-2b-blast-radius.sh"
GATE2D="$REPO_ROOT/plugins/dso/scripts/gate-2d-dependency-check.sh"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-gate-format-check.sh ==="

# Shared temp dir for all test artifacts
_GFC_DIR=$(mktemp -d /tmp/test-gate-format-check-XXXXXX)
trap 'rm -rf "$_GFC_DIR"' EXIT

# Stub file to analyze — gate scripts need a real file arg
_GFC_FILE="$REPO_ROOT/plugins/dso/scripts/validate.sh"

# ── test_gate2b_reads_format_check_from_config ─────────────────────────────
# Behavioral RED: when commands.format_check is configured, gate-2b must invoke
# it. Before task 1675-2ba3, gate-2b does not read config → sentinel not called.
_snapshot_fail

_GFC2B_SENTINEL="$_GFC_DIR/gate2b-format-check-called"
_GFC2B_CMD="$_GFC_DIR/mock-format-check-2b.sh"
printf '#!/usr/bin/env bash\ntouch "%s"\nexit 0\n' "$_GFC2B_SENTINEL" > "$_GFC2B_CMD"
chmod +x "$_GFC2B_CMD"
_GFC2B_CFG="$_GFC_DIR/dso-config-2b.conf"
printf 'commands.format_check=%s\n' "$_GFC2B_CMD" > "$_GFC2B_CFG"

WORKFLOW_CONFIG_FILE="$_GFC2B_CFG" bash "$GATE2B" "$_GFC_FILE" \
    --repo-root "$REPO_ROOT" >/dev/null 2>&1 || true

_gfc2b_called=0
[[ -f "$_GFC2B_SENTINEL" ]] && _gfc2b_called=1
assert_eq "gate-2b invokes commands.format_check when configured" "1" "$_gfc2b_called"
assert_pass_if_clean "test_gate2b_reads_format_check_from_config"

# ── test_gate2b_warn_when_format_check_absent ──────────────────────────────
# Behavioral RED: when commands.format_check is absent, gate-2b must emit
# [DSO WARN]. Before task 1675-2ba3, no warn is emitted.
_snapshot_fail

_GFC2B_WARN_CFG="$_GFC_DIR/dso-config-2b-no-fc.conf"
printf '# no commands.format_check\n' > "$_GFC2B_WARN_CFG"

_gfc2b_out=""
_gfc2b_out=$(WORKFLOW_CONFIG_FILE="$_GFC2B_WARN_CFG" bash "$GATE2B" "$_GFC_FILE" \
    --repo-root "$REPO_ROOT" 2>&1 || true)

_gfc2b_has_warn=0
grep -q '\[DSO WARN\]' <<< "$_gfc2b_out" && _gfc2b_has_warn=1
assert_eq "gate-2b emits [DSO WARN] when commands.format_check absent" "1" "$_gfc2b_has_warn"
assert_pass_if_clean "test_gate2b_warn_when_format_check_absent"

# ── test_gate2d_reads_format_check_from_config ─────────────────────────────
# Behavioral RED: when commands.format_check is configured, gate-2d must invoke
# it. Before task 65e9-840f, gate-2d does not read config → sentinel not called.
_snapshot_fail

_GFC2D_SENTINEL="$_GFC_DIR/gate2d-format-check-called"
_GFC2D_CMD="$_GFC_DIR/mock-format-check-2d.sh"
printf '#!/usr/bin/env bash\ntouch "%s"\nexit 0\n' "$_GFC2D_SENTINEL" > "$_GFC2D_CMD"
chmod +x "$_GFC2D_CMD"
_GFC2D_CFG="$_GFC_DIR/dso-config-2d.conf"
printf 'commands.format_check=%s\n' "$_GFC2D_CMD" > "$_GFC2D_CFG"

WORKFLOW_CONFIG_FILE="$_GFC2D_CFG" bash "$GATE2D" "$_GFC_FILE" \
    --repo-root "$REPO_ROOT" >/dev/null 2>&1 || true

_gfc2d_called=0
[[ -f "$_GFC2D_SENTINEL" ]] && _gfc2d_called=1
assert_eq "gate-2d invokes commands.format_check when configured" "1" "$_gfc2d_called"
assert_pass_if_clean "test_gate2d_reads_format_check_from_config"

# ── test_gate2d_warn_when_format_check_absent ──────────────────────────────
# Behavioral RED: when commands.format_check is absent, gate-2d must emit
# [DSO WARN]. Before task 65e9-840f, no warn is emitted.
_snapshot_fail

_GFC2D_WARN_CFG="$_GFC_DIR/dso-config-2d-no-fc.conf"
printf '# no commands.format_check\n' > "$_GFC2D_WARN_CFG"

_gfc2d_out=""
_gfc2d_out=$(WORKFLOW_CONFIG_FILE="$_GFC2D_WARN_CFG" bash "$GATE2D" "$_GFC_FILE" \
    --repo-root "$REPO_ROOT" 2>&1 || true)

_gfc2d_has_warn=0
grep -q '\[DSO WARN\]' <<< "$_gfc2d_out" && _gfc2d_has_warn=1
assert_eq "gate-2d emits [DSO WARN] when commands.format_check absent" "1" "$_gfc2d_has_warn"
assert_pass_if_clean "test_gate2d_warn_when_format_check_absent"

# Summary
print_summary
