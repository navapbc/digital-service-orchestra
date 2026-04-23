#!/usr/bin/env bash
# tests/scripts/test-recipe-registry.sh
# Behavioral tests for recipe registry schema validation.
#
# Testing mode: RED — schema and registry files do not yet exist.
# These tests must FAIL before recipes/recipe-registry.yaml and
# recipes/schemas/recipe-registry-schema.json are created.
#
# Usage: bash tests/scripts/test-recipe-registry.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR" && git rev-parse --show-toplevel)"
SCHEMA_PATH="$REPO_ROOT/plugins/dso/recipes/schemas/recipe-registry-schema.json"
REGISTRY_PATH="$REPO_ROOT/plugins/dso/recipes/recipe-registry.yaml"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-recipe-registry.sh ==="

# ── test_schema_file_exists ───────────────────────────────────────────────────
# Given: the repo has been set up with the recipe registry schema
# When:  we check for the schema file at recipes/schemas/recipe-registry-schema.json
# Then:  the file exists
if [ -f "$SCHEMA_PATH" ]; then
    actual="exists"
else
    actual="missing"
fi
assert_eq "test_schema_file_exists" "exists" "$actual"

# ── test_valid_entry_passes_schema ────────────────────────────────────────────
# Given: a minimal valid registry entry with all required fields
# When:  we validate it against the recipe-registry-schema.json using python3 -m jsonschema
# Then:  jsonschema exits 0 (validation succeeds)
_snapshot_fail
_tmpfile_valid=$(mktemp /tmp/test-recipe-registry-valid.XXXXXX)
cat > "$_tmpfile_valid" <<'PYEOF'
import json, sys, os, subprocess

repo_root = subprocess.check_output(
    ["git", "rev-parse", "--show-toplevel"], text=True
).strip()
schema_path = os.path.join(repo_root, "plugins", "dso", "recipes", "schemas", "recipe-registry-schema.json")

if not os.path.exists(schema_path):
    print(f"MISSING_SCHEMA: {schema_path}")
    sys.exit(1)

valid_entry = {
    "name": "add-parameter",
    "language": "python",
    "engine": "ast",
    "adapter": "libcst",
    "capability_description": "Adds a parameter to a function signature",
    "scope": "function",
    "min_engine_version": "1.0.0",
    "installation_instructions": "pip install libcst"
}

schema = json.load(open(schema_path))

import jsonschema
jsonschema.validate(valid_entry, schema)
print("OK")
PYEOF
valid_exit=0
valid_output=""
valid_output=$(python3 "$_tmpfile_valid" 2>&1) || valid_exit=$?
rm -f "$_tmpfile_valid"
assert_eq "test_valid_entry_passes_schema: exit 0" "0" "$valid_exit"
assert_eq "test_valid_entry_passes_schema: output is OK" "OK" "$valid_output"
assert_pass_if_clean "test_valid_entry_passes_schema"

# ── test_malformed_entry_caught_by_schema ─────────────────────────────────────
# Given: a registry entry missing the required 'engine' field
# When:  we validate it against the schema
# Then:  jsonschema exits with code 2 (ValidationError caught), NOT exit 0 or exit 1
# Note: exit 1 = schema file missing (infrastructure failure, not schema validation failure).
#       This test only PASSes when the schema exists and actively rejects the malformed entry.
_tmpfile_malformed=$(mktemp /tmp/test-recipe-registry-malformed.XXXXXX)
cat > "$_tmpfile_malformed" <<'PYEOF'
import json, sys, os, subprocess

repo_root = subprocess.check_output(
    ["git", "rev-parse", "--show-toplevel"], text=True
).strip()
schema_path = os.path.join(repo_root, "plugins", "dso", "recipes", "schemas", "recipe-registry-schema.json")

if not os.path.exists(schema_path):
    print(f"MISSING_SCHEMA: {schema_path}")
    sys.exit(1)

# Entry missing the required 'engine' field
malformed_entry = {
    "name": "add-parameter",
    "language": "python",
    "adapter": "libcst",
    "capability_description": "Adds a parameter to a function signature",
    "scope": "function",
    "min_engine_version": "1.0.0",
    "installation_instructions": "pip install libcst"
}

schema = json.load(open(schema_path))

import jsonschema
try:
    jsonschema.validate(malformed_entry, schema)
    print("VALIDATION_SHOULD_HAVE_FAILED")
    sys.exit(0)
except jsonschema.ValidationError as e:
    print(f"CAUGHT: {e.message}")
    sys.exit(2)
PYEOF
malformed_exit=0
malformed_output=""
malformed_output=$(python3 "$_tmpfile_malformed" 2>&1) || malformed_exit=$?
rm -f "$_tmpfile_malformed"
# Exit 2 = schema exists and correctly rejected the malformed entry (PASS)
# Exit 1 = schema file missing (RED, fail)
# Exit 0 = schema accepted an invalid entry (fail)
assert_eq "test_malformed_entry_caught_by_schema: exit 2" "2" "$malformed_exit"

# ── test_registry_yaml_parseable ──────────────────────────────────────────────
# Given: recipes/recipe-registry.yaml exists
# When:  we parse it with python3 yaml.safe_load
# Then:  it parses without error (exit 0)
_snapshot_fail
registry_parse_exit=0
registry_parse_output=""
registry_parse_output=$(python3 -c "import yaml; yaml.safe_load(open('$REGISTRY_PATH'))" 2>&1) || registry_parse_exit=$?
assert_eq "test_registry_yaml_parseable: exit 0" "0" "$registry_parse_exit"
assert_pass_if_clean "test_registry_yaml_parseable"

# ── test_registry_has_add_parameter_python ────────────────────────────────────
# Given: recipes/recipe-registry.yaml exists and has been populated
# When:  we search for an entry with name=add-parameter and language=python
# Then:  exactly one such entry is found
_snapshot_fail
_tmpfile_registry=$(mktemp /tmp/test-recipe-registry-check.XXXXXX)
cat > "$_tmpfile_registry" <<'PYEOF'
import yaml, sys, os, subprocess

repo_root = subprocess.check_output(
    ["git", "rev-parse", "--show-toplevel"], text=True
).strip()
registry_path = os.path.join(repo_root, "plugins", "dso", "recipes", "recipe-registry.yaml")

if not os.path.exists(registry_path):
    print(f"MISSING_REGISTRY: {registry_path}")
    sys.exit(1)

data = yaml.safe_load(open(registry_path))
if not isinstance(data, (list, dict)):
    print(f"UNEXPECTED_FORMAT: expected list or dict, got {type(data)}")
    sys.exit(1)

# Support both top-level list and dict with 'recipes' key
entries = data if isinstance(data, list) else data.get("recipes", [])

matches = [
    e for e in entries
    if e.get("name") == "add-parameter" and e.get("language") == "python"
]
if not matches:
    print("NOT_FOUND: no entry with name=add-parameter and language=python")
    sys.exit(1)
print(f"OK: found {len(matches)} match(es)")
PYEOF
has_entry_exit=0
has_entry_output=""
has_entry_output=$(python3 "$_tmpfile_registry" 2>&1) || has_entry_exit=$?
rm -f "$_tmpfile_registry"
assert_eq "test_registry_has_add_parameter_python: exit 0" "0" "$has_entry_exit"
assert_contains "test_registry_has_add_parameter_python: found match" "OK: found" "$has_entry_output"
assert_pass_if_clean "test_registry_has_add_parameter_python"

# ── test_registry_has_add_parameter_typescript ───────────────────────────────
# Given: recipes/recipe-registry.yaml exists and has been populated
# When:  we search for an entry with name=add-parameter and language=typescript
# Then:  exactly one such entry is found
_snapshot_fail
_tmpfile_registry_ts=$(mktemp /tmp/test-recipe-registry-ts-check.XXXXXX)
cat > "$_tmpfile_registry_ts" <<'PYEOF'
import yaml, sys, os, subprocess

repo_root = subprocess.check_output(
    ["git", "rev-parse", "--show-toplevel"], text=True
).strip()
registry_path = os.path.join(repo_root, "plugins", "dso", "recipes", "recipe-registry.yaml")

if not os.path.exists(registry_path):
    print(f"MISSING_REGISTRY: {registry_path}")
    sys.exit(1)

data = yaml.safe_load(open(registry_path))
if not isinstance(data, (list, dict)):
    print(f"UNEXPECTED_FORMAT: expected list or dict, got {type(data)}")
    sys.exit(1)

# Support both top-level list and dict with 'recipes' key
entries = data if isinstance(data, list) else data.get("recipes", [])

matches = [
    e for e in entries
    if e.get("name") == "add-parameter" and e.get("language") == "typescript"
]
if not matches:
    print("NOT_FOUND: no entry with name=add-parameter and language=typescript")
    sys.exit(1)
print(f"OK: found {len(matches)} match(es)")
PYEOF
has_ts_entry_exit=0
has_ts_entry_output=""
has_ts_entry_output=$(python3 "$_tmpfile_registry_ts" 2>&1) || has_ts_entry_exit=$?
rm -f "$_tmpfile_registry_ts"
assert_eq "test_registry_has_add_parameter_typescript: exit 0" "0" "$has_ts_entry_exit"
assert_contains "test_registry_has_add_parameter_typescript: found match" "OK: found" "$has_ts_entry_output"
assert_pass_if_clean "test_registry_has_add_parameter_typescript"

# ── test_registry_has_scaffold_route_flask ───────────────────────────────────
# Given: recipes/recipe-registry.yaml has a unified scaffold-route entry
# When:  we search for name=scaffold-route with recipe_type=generative
# Then:  exactly one such entry is found and its capability_description mentions flask
# NOTE: The registry now has a single scaffold-route entry that serves both flask
# and nextjs — framework is selected at runtime via RECIPE_PARAM_FRAMEWORK rather
# than via separate registry entries (avoids duplicate-name lookup failure).
_snapshot_fail
_tmpfile_scaffold_flask=$(mktemp /tmp/test-recipe-registry-scaffold-flask.XXXXXX)
cat > "$_tmpfile_scaffold_flask" <<'PYEOF'
import yaml, sys, os, subprocess

repo_root = subprocess.check_output(
    ["git", "rev-parse", "--show-toplevel"], text=True
).strip()
registry_path = os.path.join(repo_root, "plugins", "dso", "recipes", "recipe-registry.yaml")

if not os.path.exists(registry_path):
    print(f"MISSING_REGISTRY: {registry_path}")
    sys.exit(1)

data = yaml.safe_load(open(registry_path))
entries = data if isinstance(data, list) else data.get("recipes", [])

matches = [
    e for e in entries
    if e.get("name") == "scaffold-route" and e.get("recipe_type") == "generative"
]
if not matches:
    print("NOT_FOUND: no entry with name=scaffold-route and recipe_type=generative")
    sys.exit(1)
entry = matches[0]
cap = entry.get("capability_description", "")
if "flask" not in cap.lower():
    print(f"MISSING_FLASK: capability_description does not mention flask: {cap}")
    sys.exit(1)
print(f"OK: found {len(matches)} match(es) with recipe_type=generative")
PYEOF
scaffold_flask_exit=0
scaffold_flask_output=""
scaffold_flask_output=$(python3 "$_tmpfile_scaffold_flask" 2>&1) || scaffold_flask_exit=$?
rm -f "$_tmpfile_scaffold_flask"
assert_eq "test_registry_has_scaffold_route_flask: exit 0" "0" "$scaffold_flask_exit"
assert_contains "test_registry_has_scaffold_route_flask: found match" "OK: found" "$scaffold_flask_output"
assert_pass_if_clean "test_registry_has_scaffold_route_flask"

# ── test_registry_has_scaffold_route_nextjs ───────────────────────────────────
# Given: recipes/recipe-registry.yaml has a unified scaffold-route entry
# When:  we search for name=scaffold-route with recipe_type=generative
# Then:  exactly one such entry is found and its capability_description mentions nextjs
# NOTE: The registry now has a single scaffold-route entry that serves both flask
# and nextjs — framework is selected at runtime via RECIPE_PARAM_FRAMEWORK rather
# than via separate registry entries (avoids duplicate-name lookup failure).
_snapshot_fail
_tmpfile_scaffold_nextjs=$(mktemp /tmp/test-recipe-registry-scaffold-nextjs.XXXXXX)
cat > "$_tmpfile_scaffold_nextjs" <<'PYEOF'
import yaml, sys, os, subprocess

repo_root = subprocess.check_output(
    ["git", "rev-parse", "--show-toplevel"], text=True
).strip()
registry_path = os.path.join(repo_root, "plugins", "dso", "recipes", "recipe-registry.yaml")

if not os.path.exists(registry_path):
    print(f"MISSING_REGISTRY: {registry_path}")
    sys.exit(1)

data = yaml.safe_load(open(registry_path))
entries = data if isinstance(data, list) else data.get("recipes", [])

matches = [
    e for e in entries
    if e.get("name") == "scaffold-route" and e.get("recipe_type") == "generative"
]
if not matches:
    print("NOT_FOUND: no entry with name=scaffold-route and recipe_type=generative")
    sys.exit(1)
entry = matches[0]
cap = entry.get("capability_description", "")
if "nextjs" not in cap.lower():
    print(f"MISSING_NEXTJS: capability_description does not mention nextjs: {cap}")
    sys.exit(1)
print(f"OK: found {len(matches)} match(es) with recipe_type=generative")
PYEOF
scaffold_nextjs_exit=0
scaffold_nextjs_output=""
scaffold_nextjs_output=$(python3 "$_tmpfile_scaffold_nextjs" 2>&1) || scaffold_nextjs_exit=$?
rm -f "$_tmpfile_scaffold_nextjs"
assert_eq "test_registry_has_scaffold_route_nextjs: exit 0" "0" "$scaffold_nextjs_exit"
assert_contains "test_registry_has_scaffold_route_nextjs: found match" "OK: found" "$scaffold_nextjs_output"
assert_pass_if_clean "test_registry_has_scaffold_route_nextjs"

# ── test_generative_recipe_type_valid ────────────────────────────────────────
# Given: a registry entry with recipe_type=generative
# When:  we validate it against the schema
# Then:  jsonschema exits 0 (validation succeeds)
_snapshot_fail
_tmpfile_generative=$(mktemp /tmp/test-recipe-registry-generative.XXXXXX)
cat > "$_tmpfile_generative" <<'PYEOF'
import json, sys, os, subprocess

repo_root = subprocess.check_output(
    ["git", "rev-parse", "--show-toplevel"], text=True
).strip()
schema_path = os.path.join(repo_root, "plugins", "dso", "recipes", "schemas", "recipe-registry-schema.json")

if not os.path.exists(schema_path):
    print(f"MISSING_SCHEMA: {schema_path}")
    sys.exit(1)

generative_entry = {
    "name": "scaffold-route",
    "language": "python",
    "framework": "flask",
    "engine": "scaffold",
    "adapter": "scaffold-adapter.sh",
    "recipe_type": "generative",
    "capability_description": "Generate Flask route boilerplate",
    "scope": "generative",
    "min_engine_version": "0.0.0",
    "installation_instructions": "No external engine required"
}

schema = json.load(open(schema_path))

import jsonschema
jsonschema.validate(generative_entry, schema)
print("OK")
PYEOF
generative_exit=0
generative_output=""
generative_output=$(python3 "$_tmpfile_generative" 2>&1) || generative_exit=$?
rm -f "$_tmpfile_generative"
assert_eq "test_generative_recipe_type_valid: exit 0" "0" "$generative_exit"
assert_eq "test_generative_recipe_type_valid: output is OK" "OK" "$generative_output"
assert_pass_if_clean "test_generative_recipe_type_valid"

# ── test_transform_recipe_type_valid ─────────────────────────────────────────
# Given: a registry entry with recipe_type=transform
# When:  we validate it against the schema
# Then:  jsonschema exits 0 (validation succeeds)
_snapshot_fail
_tmpfile_transform=$(mktemp /tmp/test-recipe-registry-transform.XXXXXX)
cat > "$_tmpfile_transform" <<'PYEOF'
import json, sys, os, subprocess

repo_root = subprocess.check_output(
    ["git", "rev-parse", "--show-toplevel"], text=True
).strip()
schema_path = os.path.join(repo_root, "plugins", "dso", "recipes", "schemas", "recipe-registry-schema.json")

if not os.path.exists(schema_path):
    print(f"MISSING_SCHEMA: {schema_path}")
    sys.exit(1)

transform_entry = {
    "name": "add-parameter",
    "language": "python",
    "engine": "rope",
    "adapter": "rope-adapter.sh",
    "recipe_type": "transform",
    "capability_description": "Add a parameter to a function signature",
    "scope": "cross-file",
    "min_engine_version": "1.7.0",
    "installation_instructions": "pip install rope>=1.7.0"
}

schema = json.load(open(schema_path))

import jsonschema
jsonschema.validate(transform_entry, schema)
print("OK")
PYEOF
transform_exit=0
transform_output=""
transform_output=$(python3 "$_tmpfile_transform" 2>&1) || transform_exit=$?
rm -f "$_tmpfile_transform"
assert_eq "test_transform_recipe_type_valid: exit 0" "0" "$transform_exit"
assert_eq "test_transform_recipe_type_valid: output is OK" "OK" "$transform_output"
assert_pass_if_clean "test_transform_recipe_type_valid"

# ── test_registry_has_normalize_imports_python ────────────────────────────────
# Given: recipes/recipe-registry.yaml exists and has normalize-imports entries
# When:  we search for an entry with name=normalize-imports and language=python
# Then:  exactly one such entry is found
_snapshot_fail
_tmpfile_normalize_py=$(mktemp /tmp/test-recipe-registry-normalize-py.XXXXXX)
cat > "$_tmpfile_normalize_py" <<'PYEOF'
import yaml, sys, os, subprocess

repo_root = subprocess.check_output(
    ["git", "rev-parse", "--show-toplevel"], text=True
).strip()
registry_path = os.path.join(repo_root, "plugins", "dso", "recipes", "recipe-registry.yaml")

if not os.path.exists(registry_path):
    print(f"MISSING_REGISTRY: {registry_path}")
    sys.exit(1)

data = yaml.safe_load(open(registry_path))
if not isinstance(data, (list, dict)):
    print(f"UNEXPECTED_FORMAT: expected list or dict, got {type(data)}")
    sys.exit(1)

# Support both top-level list and dict with 'recipes' key
entries = data if isinstance(data, list) else data.get("recipes", [])

matches = [
    e for e in entries
    if e.get("name") == "normalize-imports" and e.get("language") == "python"
]
if not matches:
    print("NOT_FOUND: no entry with name=normalize-imports and language=python")
    sys.exit(1)
print(f"OK: found {len(matches)} match(es)")
PYEOF
normalize_py_exit=0
normalize_py_output=""
normalize_py_output=$(python3 "$_tmpfile_normalize_py" 2>&1) || normalize_py_exit=$?
rm -f "$_tmpfile_normalize_py"
assert_eq "test_registry_has_normalize_imports_python: exit 0" "0" "$normalize_py_exit"
assert_contains "test_registry_has_normalize_imports_python: found match" "OK: found" "$normalize_py_output"
assert_pass_if_clean "test_registry_has_normalize_imports_python"

# ── test_registry_has_normalize_imports_typescript ───────────────────────────
# Given: recipes/recipe-registry.yaml exists and has normalize-imports entries
# When:  we search for an entry with name=normalize-imports and language=typescript
# Then:  exactly one such entry is found
_snapshot_fail
_tmpfile_normalize_ts=$(mktemp /tmp/test-recipe-registry-normalize-ts.XXXXXX)
cat > "$_tmpfile_normalize_ts" <<'PYEOF'
import yaml, sys, os, subprocess

repo_root = subprocess.check_output(
    ["git", "rev-parse", "--show-toplevel"], text=True
).strip()
registry_path = os.path.join(repo_root, "plugins", "dso", "recipes", "recipe-registry.yaml")

if not os.path.exists(registry_path):
    print(f"MISSING_REGISTRY: {registry_path}")
    sys.exit(1)

data = yaml.safe_load(open(registry_path))
if not isinstance(data, (list, dict)):
    print(f"UNEXPECTED_FORMAT: expected list or dict, got {type(data)}")
    sys.exit(1)

# Support both top-level list and dict with 'recipes' key
entries = data if isinstance(data, list) else data.get("recipes", [])

matches = [
    e for e in entries
    if e.get("name") == "normalize-imports" and e.get("language") == "typescript"
]
if not matches:
    print("NOT_FOUND: no entry with name=normalize-imports and language=typescript")
    sys.exit(1)
print(f"OK: found {len(matches)} match(es)")
PYEOF
normalize_ts_exit=0
normalize_ts_output=""
normalize_ts_output=$(python3 "$_tmpfile_normalize_ts" 2>&1) || normalize_ts_exit=$?
rm -f "$_tmpfile_normalize_ts"
assert_eq "test_registry_has_normalize_imports_typescript: exit 0" "0" "$normalize_ts_exit"
assert_contains "test_registry_has_normalize_imports_typescript: found match" "OK: found" "$normalize_ts_output"
assert_pass_if_clean "test_registry_has_normalize_imports_typescript"

print_summary
