#!/usr/bin/env bash
#
# Query the recipe registry and output matching recipes.
#
# Usage:
#   consult-recipe-registry.sh [--language <lang>]
#
# Options:
#   --language <lang>   Filter recipes by language (exact match or "any").
#                       If omitted, all recipes are returned.
#
# Environment:
#   RECIPE_REGISTRY_PATH   Override the default registry path.
#
# Output:
#   One line per matching recipe containing: name, language, scope, capability_description.
#   Empty output for unknown language. Non-zero exit if registry file is missing.
#
# Exit codes:
#   0  — success (including empty result for unknown language)
#   1  — registry file not found

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REGISTRY="${RECIPE_REGISTRY_PATH:-$SCRIPT_DIR/../recipes/recipe-registry.yaml}"

# ── Argument parsing ──────────────────────────────────────────────────────────

FILTER_LANGUAGE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --language)
            if [[ $# -lt 2 ]]; then
                echo "Error: --language requires an argument" >&2
                exit 1
            fi
            FILTER_LANGUAGE="$2"
            shift 2
            ;;
        *)
            echo "Error: unknown argument: $1" >&2
            exit 1
            ;;
    esac
done

# ── Registry validation ───────────────────────────────────────────────────────

if [[ ! -f "$REGISTRY" ]]; then
    echo "Error: recipe registry not found: $REGISTRY" >&2
    exit 1
fi

# ── Query and output ──────────────────────────────────────────────────────────

python3 - "$REGISTRY" "$FILTER_LANGUAGE" <<'PYEOF'
import sys
import yaml

registry_path = sys.argv[1]
filter_lang   = sys.argv[2]  # empty string means "no filter"

with open(registry_path) as f:
    data = yaml.safe_load(f)

recipes = data.get("recipes", [])

for r in recipes:
    name     = r.get("name", "")
    language = r.get("language", "")
    scope    = r.get("scope", "")
    cap_desc = r.get("capability_description", "")

    # Apply language filter when requested.
    # language: any recipes match only when the requested language exists in the
    # registry as a concrete language (i.e., at least one recipe has that language).
    # This prevents "any" from matching completely unknown languages.
    if filter_lang:
        concrete_languages = {r.get("language", "") for r in recipes if r.get("language", "") != "any"}
        if language == "any":
            if filter_lang not in concrete_languages:
                continue
        elif language != filter_lang:
            continue

    print(f"{name}\t{language}\t{scope}\t{cap_desc}")
PYEOF
