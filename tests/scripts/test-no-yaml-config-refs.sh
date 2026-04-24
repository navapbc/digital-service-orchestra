#!/usr/bin/env bash
# tests/scripts/test-no-yaml-config-refs.sh
# TDD tests verifying zero YAML config file references remain in scripts/hooks.
#
# "YAML config" means workflow-config.yaml or workflow-config.yml — NOT
# legitimate uses of YAML for ticket frontmatter (yaml_field, YAML frontmatter, etc.).
#
# Tests:
#   test_no_workflow_config_yaml_in_scripts — no active workflow-config.yaml refs
#   test_no_workflow_config_yaml_in_hooks   — no active workflow-config.yaml refs in hooks
#   test_sample_yaml_fixture_removed        — evals/fixtures/sample-workflow-config.yaml gone
#   test_schemastore_no_yaml_filematch      — submit-to-schemastore.sh only references .conf
#
# Usage: bash tests/scripts/test-no-yaml-config-refs.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
REPO_ROOT="$(cd "$SCRIPT_DIR" && git rev-parse --show-toplevel)"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-no-yaml-config-refs.sh ==="

# ── test_no_workflow_config_yaml_in_scripts ───────────────────────────────────
# No active (non-comment) lines in scripts/ should reference
# workflow-config.yaml or workflow-config.yml as a config file path.
# Exclusions:
#   tk — interpreter probe (fo76's responsibility) and YAML frontmatter functions
#         are legitimate (tickets use YAML frontmatter)
#   read-config.sh — reads config files by format; .yaml support may be vestigial
#   sprint-next-batch.sh, issue-batch.sh — YAML frontmatter for ticket parsing
#   archive-closed-tickets.sh, orphaned-tasks.sh — ticket frontmatter parsing
#   issue-quality-check.sh — ticket frontmatter parsing
#   merge-to-main.sh, validate.sh, validate-phase.sh — frontmatter/syntax mentions
#   retype-epic-children.sh — ticket frontmatter
#   plugin-reference-catalog.sh, validate-ui-cache.sh — file extension patterns
#   sprint-next-batch.sh, issue-batch.sh — python regex with yaml extension
#   claude-safe — doc comments (not executable config paths)
_snapshot_fail

# Find active (non-comment) lines that reference workflow-config.yaml as a path
# in scripts that are within my ownership scope
scripts_hits=$(
    grep -rn 'workflow-config\.yaml\|workflow-config\.yml' \
        "$DSO_PLUGIN_DIR/scripts/" \
        "$DSO_PLUGIN_DIR/hooks/" \
    | grep -v '/scripts/read-config\.sh:' \
    | grep -v '/scripts/claude-safe:' \
    || true
)

# Strip comment lines from results
real_offenders=""
while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    # Extract content after file:lineno: prefix
    content="${line#*:*:}"
    trimmed="${content#"${content%%[![:space:]]*}"}"
    # Skip pure comment lines
    [[ "$trimmed" == \#* ]] && continue
    real_offenders+="$line"$'\n'
done <<< "$scripts_hits"

assert_eq "test_no_workflow_config_yaml_in_scripts: no active refs" "" "$real_offenders"

if [[ -n "$real_offenders" ]]; then
    echo "  Remaining active workflow-config.yaml refs:" >&2
    echo "$real_offenders" | head -20 >&2
fi

assert_pass_if_clean "test_no_workflow_config_yaml_in_scripts"

# ── test_sample_yaml_fixture_removed ─────────────────────────────────────────
# evals/fixtures/sample-workflow-config.yaml must not exist.
_snapshot_fail

FIXTURE="$PLUGIN_ROOT/tests/evals/fixtures/sample-workflow-config.yaml"
fixture_exists="absent"
if [[ -f "$FIXTURE" ]]; then
    fixture_exists="present"
fi

assert_eq "test_sample_yaml_fixture_removed: fixture is absent" "absent" "$fixture_exists"

assert_pass_if_clean "test_sample_yaml_fixture_removed"

# ── test_schemastore_no_yaml_filematch ────────────────────────────────────────
# submit-to-schemastore.sh must not reference workflow-config.yaml or .yml in fileMatch.
# AC verify: { grep -q 'workflow-config.yaml\|workflow-config.yml' submit-to-schemastore.sh; test $? -ne 0; }
_snapshot_fail

SCHEMASTORE="$DSO_PLUGIN_DIR/scripts/submit-to-schemastore.sh"
yaml_filematch="absent"
if grep -q 'workflow-config\.yaml\|workflow-config\.yml' "$SCHEMASTORE" 2>/dev/null; then
    yaml_filematch="present"
fi

assert_eq "test_schemastore_no_yaml_filematch: no .yaml/.yml in fileMatch" "absent" "$yaml_filematch"

assert_pass_if_clean "test_schemastore_no_yaml_filematch"

print_summary
