#!/usr/bin/env bash
# tests/scripts/test-bug-classification-registry.sh
# Schema validation for plugins/dso/docs/bug-classification-registry.json.
#
# Tests:
#   1. Registry file exists
#   2. JSON has `entries` array of exactly 27 items
#   3. Each entry has all required fields: slug, classification_question,
#      primary_defense_layer, defense_artifact_ref, applies_to_project_classes
#   4. primary_defense_layer values are within the allowed enum
#   5. defense_artifact_ref uses a recognized prefix: repo:, plugin:, or absolute:
#   6. applies_to_project_classes is either "all" or "agent_orchestration"
#   7. Each slug matches kebab-case (lowercase letters, digits, hyphens; starts with letter)
#
# Usage: bash tests/scripts/test-bug-classification-registry.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-bug-classification-registry.sh ==="

REGISTRY="$REPO_ROOT/plugins/dso/docs/bug-classification-registry.json"

# ── test_registry_file_exists ─────────────────────────────────────────────────
test_registry_file_exists() {
    local actual
    if [ -f "$REGISTRY" ] && [ -s "$REGISTRY" ]; then
        actual="exists_nonempty"
    elif [ -f "$REGISTRY" ]; then
        actual="exists_empty"
    else
        actual="missing"
    fi
    assert_eq "test_registry_file_exists: file exists and is non-empty" "exists_nonempty" "$actual"
}

# ── test_entries_array_count ──────────────────────────────────────────────────
test_entries_array_count() {
    if [ ! -f "$REGISTRY" ]; then
        assert_eq "test_entries_array_count: registry file must exist" "exists" "missing"
        return
    fi
    local count
    count=$(python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    data = json.load(f)
entries = data.get('entries', [])
print(len(entries))
" "$REGISTRY" 2>/dev/null) || count="error"
    assert_eq "test_entries_array_count: entries array has exactly 27 items" "27" "$count"
}

# ── test_required_fields ──────────────────────────────────────────────────────
test_required_fields() {
    if [ ! -f "$REGISTRY" ]; then
        assert_eq "test_required_fields: registry file must exist" "exists" "missing"
        return
    fi
    local result
    result=$(python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    data = json.load(f)
entries = data.get('entries', [])
required = {'slug', 'classification_question', 'primary_defense_layer',
            'defense_artifact_ref', 'applies_to_project_classes'}
missing_report = []
for i, entry in enumerate(entries):
    missing = required - set(entry.keys())
    if missing:
        missing_report.append('entry[{}] missing: {}'.format(i, sorted(missing)))
if missing_report:
    print('FAIL: ' + '; '.join(missing_report))
else:
    print('ok')
" "$REGISTRY" 2>/dev/null) || result="error"
    assert_eq "test_required_fields: all entries have required fields" "ok" "$result"
}

# ── test_primary_defense_layer_enum ──────────────────────────────────────────
test_primary_defense_layer_enum() {
    if [ ! -f "$REGISTRY" ]; then
        assert_eq "test_primary_defense_layer_enum: registry file must exist" "exists" "missing"
        return
    fi
    local result
    result=$(python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    data = json.load(f)
entries = data.get('entries', [])
allowed = {
    'planning_review',
    'code_review',
    'matrix_ci',
    'concurrency_test',
    'failure_path_test',
    'defense_manifest_test',
    'release_e2e',
    'operational_process',
    'prose_manifest_test',
}
invalid = []
for i, entry in enumerate(entries):
    val = entry.get('primary_defense_layer', '')
    if val not in allowed:
        invalid.append('entry[{}] has invalid primary_defense_layer: {!r}'.format(i, val))
if invalid:
    print('FAIL: ' + '; '.join(invalid))
else:
    print('ok')
" "$REGISTRY" 2>/dev/null) || result="error"
    assert_eq "test_primary_defense_layer_enum: all primary_defense_layer values are in allowed enum" "ok" "$result"
}

# ── test_defense_artifact_ref_prefix ─────────────────────────────────────────
test_defense_artifact_ref_prefix() {
    if [ ! -f "$REGISTRY" ]; then
        assert_eq "test_defense_artifact_ref_prefix: registry file must exist" "exists" "missing"
        return
    fi
    local result
    result=$(python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    data = json.load(f)
entries = data.get('entries', [])
allowed_prefixes = ('repo:', 'plugin:', 'absolute:')
invalid = []
for i, entry in enumerate(entries):
    ref = entry.get('defense_artifact_ref', '')
    if not any(ref.startswith(p) for p in allowed_prefixes):
        invalid.append('entry[{}] has invalid defense_artifact_ref prefix: {!r}'.format(i, ref))
if invalid:
    print('FAIL: ' + '; '.join(invalid))
else:
    print('ok')
" "$REGISTRY" 2>/dev/null) || result="error"
    assert_eq "test_defense_artifact_ref_prefix: all defense_artifact_ref values use a recognized prefix" "ok" "$result"
}

# ── test_applies_to_project_classes_enum ─────────────────────────────────────
test_applies_to_project_classes_enum() {
    if [ ! -f "$REGISTRY" ]; then
        assert_eq "test_applies_to_project_classes_enum: registry file must exist" "exists" "missing"
        return
    fi
    local result
    result=$(python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    data = json.load(f)
entries = data.get('entries', [])
allowed = {'all', 'agent_orchestration'}
invalid = []
for i, entry in enumerate(entries):
    val = entry.get('applies_to_project_classes', '')
    if val not in allowed:
        invalid.append('entry[{}] has invalid applies_to_project_classes: {!r}'.format(i, val))
if invalid:
    print('FAIL: ' + '; '.join(invalid))
else:
    print('ok')
" "$REGISTRY" 2>/dev/null) || result="error"
    assert_eq "test_applies_to_project_classes_enum: all applies_to_project_classes values are 'all' or 'agent_orchestration'" "ok" "$result"
}

# ── test_slug_kebab_case ──────────────────────────────────────────────────────
test_slug_kebab_case() {
    if [ ! -f "$REGISTRY" ]; then
        assert_eq "test_slug_kebab_case: registry file must exist" "exists" "missing"
        return
    fi
    local result
    result=$(python3 -c "
import json, re, sys
with open(sys.argv[1]) as f:
    data = json.load(f)
entries = data.get('entries', [])
pattern = re.compile(r'^[a-z][a-z0-9-]*$')
invalid = []
for i, entry in enumerate(entries):
    slug = entry.get('slug', '')
    if not pattern.match(slug):
        invalid.append('entry[{}] has invalid slug: {!r}'.format(i, slug))
if invalid:
    print('FAIL: ' + '; '.join(invalid))
else:
    print('ok')
" "$REGISTRY" 2>/dev/null) || result="error"
    assert_eq "test_slug_kebab_case: all slugs match kebab-case pattern" "ok" "$result"
}

# ── run all tests ─────────────────────────────────────────────────────────────
test_registry_file_exists
test_entries_array_count
test_required_fields
test_primary_defense_layer_enum
test_defense_artifact_ref_prefix
test_applies_to_project_classes_enum
test_slug_kebab_case

print_summary
