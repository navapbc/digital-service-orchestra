#!/usr/bin/env bash
# tests/scripts/test-consult-recipe-registry.sh
# RED-phase tests for plugins/dso/scripts/consult-recipe-registry.sh.
#
# The script under test does NOT exist yet; all tests must FAIL.
# Injectable env var: RECIPE_REGISTRY_PATH — overrides the default registry path
# for CI isolation.
#
# Usage: bash tests/scripts/test-consult-recipe-registry.sh
# Returns: exit 1 (all tests fail — RED phase)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR" && git rev-parse --show-toplevel)"

source "$REPO_ROOT/tests/lib/assert.sh"

RECIPE_REGISTRY_PATH="${RECIPE_REGISTRY_PATH:-$REPO_ROOT/plugins/dso/recipes/recipe-registry.yaml}"
SCRIPT_UNDER_TEST="$REPO_ROOT/plugins/dso/scripts/consult-recipe-registry.sh"

echo "=== test-consult-recipe-registry.sh ==="
echo "Registry: $RECIPE_REGISTRY_PATH"
echo "Script:   $SCRIPT_UNDER_TEST"
echo ""

# ── (a) List all recipes — no filter ──────────────────────────────────────────
# Each entry in the registry must appear with its name, language, scope, and
# capability_description.

output_all=""
output_all="$(RECIPE_REGISTRY_PATH="$RECIPE_REGISTRY_PATH" bash "$SCRIPT_UNDER_TEST" 2>/dev/null)" || true

# add-parameter / python
assert_contains \
    "list_all: add-parameter python name present" \
    "add-parameter" \
    "$output_all"

assert_contains \
    "list_all: add-parameter python language present" \
    "python" \
    "$output_all"

assert_contains \
    "list_all: add-parameter python scope present" \
    "cross-file" \
    "$output_all"

assert_contains \
    "list_all: add-parameter python capability_description present" \
    "Add a parameter to a function signature and update all callers across files" \
    "$output_all"

# add-parameter / typescript
assert_contains \
    "list_all: add-parameter typescript language present" \
    "typescript" \
    "$output_all"

assert_contains \
    "list_all: add-parameter typescript capability_description present" \
    "Add a parameter to a TypeScript function signature" \
    "$output_all"

# scaffold-route / any / generative
assert_contains \
    "list_all: scaffold-route name present" \
    "scaffold-route" \
    "$output_all"

assert_contains \
    "list_all: scaffold-route scope generative present" \
    "generative" \
    "$output_all"

assert_contains \
    "list_all: scaffold-route capability_description present" \
    "Generate framework-specific route boilerplate" \
    "$output_all"

# normalize-imports / python
assert_contains \
    "list_all: normalize-imports python name present" \
    "normalize-imports" \
    "$output_all"

assert_contains \
    "list_all: normalize-imports python scope single-file present" \
    "single-file" \
    "$output_all"

assert_contains \
    "list_all: normalize-imports python capability_description present" \
    "Sort and deduplicate Python import statements" \
    "$output_all"

# normalize-imports / typescript
assert_contains \
    "list_all: normalize-imports typescript capability_description present" \
    "Sort and deduplicate TypeScript import statements" \
    "$output_all"

# normalize-imports / ruby
assert_contains \
    "list_all: normalize-imports ruby language present" \
    "ruby" \
    "$output_all"

assert_contains \
    "list_all: normalize-imports ruby capability_description present" \
    "Sort and deduplicate Ruby require/require_relative statements" \
    "$output_all"

# ── (b) --language python filter ──────────────────────────────────────────────
# Must contain python recipes; must NOT contain typescript or ruby recipes.

output_python=""
output_python="$(RECIPE_REGISTRY_PATH="$RECIPE_REGISTRY_PATH" bash "$SCRIPT_UNDER_TEST" --language python 2>/dev/null)" || true

assert_contains \
    "filter_python: add-parameter python name present" \
    "add-parameter" \
    "$output_python"

assert_contains \
    "filter_python: python language tag present" \
    "python" \
    "$output_python"

assert_contains \
    "filter_python: normalize-imports python capability present" \
    "Sort and deduplicate Python import statements" \
    "$output_python"

assert_not_contains \
    "filter_python: typescript language absent" \
    "typescript" \
    "$output_python"

assert_not_contains \
    "filter_python: ruby language absent" \
    "ruby" \
    "$output_python"

assert_not_contains \
    "filter_python: TypeScript capability absent" \
    "Sort and deduplicate TypeScript import statements" \
    "$output_python"

assert_not_contains \
    "filter_python: Ruby capability absent" \
    "Sort and deduplicate Ruby require" \
    "$output_python"

# ── (c) --language typescript filter ──────────────────────────────────────────
# Must contain typescript recipes; must NOT contain python-only or ruby recipes.

output_ts=""
output_ts="$(RECIPE_REGISTRY_PATH="$RECIPE_REGISTRY_PATH" bash "$SCRIPT_UNDER_TEST" --language typescript 2>/dev/null)" || true

assert_contains \
    "filter_ts: add-parameter typescript name present" \
    "add-parameter" \
    "$output_ts"

assert_contains \
    "filter_ts: typescript language tag present" \
    "typescript" \
    "$output_ts"

assert_contains \
    "filter_ts: add-parameter typescript capability present" \
    "Add a parameter to a TypeScript function signature" \
    "$output_ts"

assert_contains \
    "filter_ts: normalize-imports typescript capability present" \
    "Sort and deduplicate TypeScript import statements" \
    "$output_ts"

assert_not_contains \
    "filter_ts: python-only capability absent (isort)" \
    "isort" \
    "$output_ts"

assert_not_contains \
    "filter_ts: ruby language absent" \
    "ruby" \
    "$output_ts"

assert_not_contains \
    "filter_ts: Ruby capability absent" \
    "Sort and deduplicate Ruby require" \
    "$output_ts"

# ── (d) Unknown language returns empty output and exits 0 ─────────────────────

exit_code_unknown=0
output_unknown=""
output_unknown="$(RECIPE_REGISTRY_PATH="$RECIPE_REGISTRY_PATH" bash "$SCRIPT_UNDER_TEST" --language cobol 2>/dev/null)" \
    || exit_code_unknown=$?

assert_eq \
    "unknown_lang: exits 0" \
    "0" \
    "$exit_code_unknown"

assert_eq \
    "unknown_lang: output is empty" \
    "" \
    "$output_unknown"

# ── (e) Missing registry file — exits non-zero with stderr message ─────────────

missing_registry="$(mktemp "${TMPDIR:-/tmp}/missing-registry.XXXXXX")"
rm -f "$missing_registry"   # ensure it does not exist

exit_code_missing=0
stderr_missing=""
stderr_missing="$(RECIPE_REGISTRY_PATH="$missing_registry" bash "$SCRIPT_UNDER_TEST" 2>&1 >/dev/null)" \
    || exit_code_missing=$?

assert_ne \
    "missing_registry: exits non-zero" \
    "0" \
    "$exit_code_missing"

assert_ne \
    "missing_registry: stderr is non-empty" \
    "" \
    "$stderr_missing"

print_summary
