#!/usr/bin/env bash
# tests/scripts/test-config-callers-updated.sh
# TDD tests verifying that script callers use .conf instead of .yaml,
# and that runtime scripts use .claude/dso-config.conf (not dso-config.conf).
#
# Tests:
#   test_sprint_next_batch_uses_conf — sprint-next-batch.sh references .conf
#   test_no_hardcoded_yaml_in_callers — no non-comment hardcoded workflow-config.yaml refs
#   test_validate_sh_uses_dot_claude_config — validate.sh uses $REPO_ROOT/.claude/dso-config.conf
#   test_validate_phase_sh_uses_dot_claude_config — validate-phase.sh uses .claude/dso-config.conf
#   test_sprint_next_batch_uses_dot_claude_config — sprint-next-batch.sh uses .claude/dso-config.conf
#   test_no_hardcoded_workflow_config_conf_in_scripts — no active hardcoded dso-config.conf path construction
#
# Usage: bash tests/scripts/test-config-callers-updated.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
REPO_ROOT="$(cd "$SCRIPT_DIR" && git rev-parse --show-toplevel)"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-config-callers-updated.sh ==="

# ── test_sprint_next_batch_uses_conf ─────────────────────────────────────────
# ticket-next-batch.sh (canonical implementation) should pass .conf paths (not
# .yaml) to read-config.sh. sprint-next-batch.sh is now a thin exec wrapper —
# the config references live in ticket-next-batch.sh.
_snapshot_fail
SPRINT_SCRIPT="$DSO_PLUGIN_DIR/scripts/ticket-next-batch.sh"

# Check that .claude/dso-config.conf is referenced in active (non-comment) lines
conf_refs=$(grep -v '^\s*#' "$SPRINT_SCRIPT" | grep -c '\.claude/dso-config\.conf' || true)
assert_ne "ticket-next-batch.sh references .claude/dso-config.conf" "0" "$conf_refs"

# Check that no active (non-comment) lines reference .yaml config paths
yaml_active=$(grep -v '^\s*#' "$SPRINT_SCRIPT" | grep -c 'workflow-config\.yaml' || true)
assert_eq "ticket-next-batch.sh has no active .yaml refs" "0" "$yaml_active"

assert_pass_if_clean "test_sprint_next_batch_uses_conf"

# ── test_no_hardcoded_yaml_in_callers ────────────────────────────────────────
# No non-comment references to workflow-config.yaml in scripts/
# (excluding backward-compat/fallback/migration comments and read-config.sh itself
#  which has the .yaml fallback logic)
_snapshot_fail
SCRIPTS_DIR="$DSO_PLUGIN_DIR/scripts"

# Mirror the AC verify command: grep for workflow-config.yaml, exclude comments
# and fallback/backward/compat/migration lines.
# Excluded scripts (legitimate .yaml fallback logic):
#   read-config.sh — handles .yaml fallback resolution
#   validate-config.sh — handles .yaml fallback resolution
#   submit-to-schemastore.sh — fileMatch array must list .yaml for backward compat
offending=$(
    grep -rn 'workflow-config\.yaml' "$SCRIPTS_DIR" --include='*.sh' \
    | grep -v 'read-config\.sh:' \
    | grep -v 'validate-config\.sh:' \
    | grep -v 'submit-to-schemastore\.sh:' \
    | grep -v 'fallback\|backward\|compat\|migration' \
    | head -20 \
    || true
)

# Further filter: strip file:lineno: prefix and skip actual comment lines
real_offenders=""
while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    content="${line#*:*:}"
    trimmed="${content#"${content%%[![:space:]]*}"}"
    [[ "$trimmed" == \#* ]] && continue
    real_offenders+="$line"$'\n'
done <<< "$offending"

assert_eq "no active workflow-config.yaml refs in scripts" "" "$real_offenders"

assert_pass_if_clean "test_no_hardcoded_yaml_in_callers"

# ── test_validate_sh_uses_dot_claude_config ───────────────────────────────────
# validate.sh should construct CONFIG_FILE as $REPO_ROOT/.claude/dso-config.conf
# (not $REPO_ROOT/dso-config.conf). This test is RED until dso-2vwl is implemented.
_snapshot_fail
VALIDATE_SCRIPT="$DSO_PLUGIN_DIR/scripts/validate.sh"

# Check that .claude/dso-config.conf is referenced in active (non-comment) lines
dot_claude_refs=$(grep -v '^\s*#' "$VALIDATE_SCRIPT" | grep -c '\.claude/dso-config\.conf' || true)
assert_ne "validate.sh references .claude/dso-config.conf" "0" "$dot_claude_refs"

# Check that no active (non-comment) lines construct the old dso-config.conf path
old_path_active=$(grep -v '^\s*#' "$VALIDATE_SCRIPT" | grep -c "\$REPO_ROOT/workflow-config\\.conf" || true)
assert_eq "validate.sh has no active \$REPO_ROOT/dso-config.conf refs" "0" "$old_path_active"

assert_pass_if_clean "test_validate_sh_uses_dot_claude_config"

# ── test_validate_phase_sh_uses_dot_claude_config ────────────────────────────
# validate-phase.sh should use $REPO_ROOT/.claude/dso-config.conf, not
# $REPO_ROOT/dso-config.conf. RED until dso-2vwl is implemented.
_snapshot_fail
VALIDATE_PHASE_SCRIPT="$DSO_PLUGIN_DIR/scripts/validate-phase.sh"

dot_claude_refs=$(grep -v '^\s*#' "$VALIDATE_PHASE_SCRIPT" | grep -c '\.claude/dso-config\.conf' || true)
assert_ne "validate-phase.sh references .claude/dso-config.conf" "0" "$dot_claude_refs"

old_path_active=$(grep -v '^\s*#' "$VALIDATE_PHASE_SCRIPT" | grep -c "\$REPO_ROOT/workflow-config\\.conf" || true)
assert_eq "validate-phase.sh has no active \$REPO_ROOT/dso-config.conf refs" "0" "$old_path_active"

assert_pass_if_clean "test_validate_phase_sh_uses_dot_claude_config"

# ── test_sprint_next_batch_uses_dot_claude_config ────────────────────────────
# ticket-next-batch.sh (canonical implementation) should pass
# $REPO_ROOT/.claude/dso-config.conf to read-config.sh, not
# $REPO_ROOT/dso-config.conf. sprint-next-batch.sh is now a thin exec wrapper —
# the config references live in ticket-next-batch.sh.
_snapshot_fail
SPRINT_SCRIPT2="$DSO_PLUGIN_DIR/scripts/ticket-next-batch.sh"

dot_claude_refs=$(grep -v '^\s*#' "$SPRINT_SCRIPT2" | grep -c '\.claude/dso-config\.conf' || true)
assert_ne "ticket-next-batch.sh references .claude/dso-config.conf" "0" "$dot_claude_refs"

old_path_active=$(grep -v '^\s*#' "$SPRINT_SCRIPT2" | grep -c "\$REPO_ROOT/workflow-config\\.conf" || true)
assert_eq "ticket-next-batch.sh has no active \$REPO_ROOT/dso-config.conf refs" "0" "$old_path_active"

assert_pass_if_clean "test_sprint_next_batch_uses_dot_claude_config"

# ── test_no_hardcoded_workflow_config_conf_in_scripts ────────────────────────
# No active (non-comment) lines in plugins/dso/scripts/*.sh should hard-code
# the $REPO_ROOT/dso-config.conf path construction.
# Excluded scripts with legitimate use of the filename:
#   read-config.sh     — handles format detection / path resolution
#   validate-config.sh — handles legacy config validation
# RED until dso-2vwl updates all runtime scripts.
_snapshot_fail
SCRIPTS_DIR2="$DSO_PLUGIN_DIR/scripts"

raw_matches=$(
    grep -rn "\$REPO_ROOT/workflow-config\\.conf\\|\${REPO_ROOT}/workflow-config\\.conf" \
        "$SCRIPTS_DIR2" --include='*.sh' \
    | grep -v 'read-config\.sh:' \
    | grep -v 'validate-config\.sh:' \
    | head -30 \
    || true
)

# Strip comment lines (lines where code portion starts with #)
active_offenders=""
while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    # Extract the code portion after file:lineno: prefix
    content="${line#*:*:}"
    trimmed="${content#"${content%%[![:space:]]*}"}"
    [[ "$trimmed" == \#* ]] && continue
    active_offenders+="$line"$'\n'
done <<< "$raw_matches"

assert_eq "no active \$REPO_ROOT/dso-config.conf path construction in scripts" "" "$active_offenders"

assert_pass_if_clean "test_no_hardcoded_workflow_config_conf_in_scripts"

print_summary
