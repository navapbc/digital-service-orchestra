#!/usr/bin/env bash
# tests/scripts/test-config-callers-updated.sh
# TDD tests verifying that script callers use .conf instead of .yaml.
#
# Tests:
#   test_sprint_next_batch_uses_conf — sprint-next-batch.sh references .conf
#   test_no_hardcoded_yaml_in_callers — no non-comment hardcoded workflow-config.yaml refs
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
# sprint-next-batch.sh should pass .conf paths (not .yaml) to read-config.sh
_snapshot_fail
SPRINT_SCRIPT="$DSO_PLUGIN_DIR/scripts/sprint-next-batch.sh"

# Check that .conf is referenced in config path lines
conf_refs=$(grep -c 'workflow-config\.conf' "$SPRINT_SCRIPT" || true)
assert_ne "sprint-next-batch.sh references .conf" "0" "$conf_refs"

# Check that no active (non-comment) lines reference .yaml config paths
yaml_active=$(grep -v '^\s*#' "$SPRINT_SCRIPT" | grep -c 'workflow-config\.yaml' || true)
assert_eq "sprint-next-batch.sh has no active .yaml refs" "0" "$yaml_active"

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

print_summary
