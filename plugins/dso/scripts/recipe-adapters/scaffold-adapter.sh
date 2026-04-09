#!/usr/bin/env bash
# plugins/dso/scripts/recipe-adapters/scaffold-adapter.sh
# Recipe engine adapter for scaffold-route (generative recipe).
# Conforms to: plugins/dso/docs/contracts/recipe-engine-adapter.md
#
# Input:  RECIPE_PARAM_* env vars (never positional args)
# Output: single JSON object to stdout; all diagnostics to stderr
# Exit:   0 = success, 1 = generation failure

set -euo pipefail

ENGINE_NAME="scaffold"

# ── Helpers ───────────────────────────────────────────────────────────────────

emit_json() {
    local files_changed="$1"
    local transforms_applied="$2"
    local errors_json="$3"
    local exit_code="$4"
    local degraded="$5"
    printf '{"files_changed": %s, "transforms_applied": %s, "errors": %s, "exit_code": %s, "degraded": %s, "engine_name": "%s"}\n' \
        "$files_changed" "$transforms_applied" "$errors_json" "$exit_code" "$degraded" "$ENGINE_NAME"
}

emit_failure() {
    local msg="$1"
    emit_json '[]' '0' "[\"${msg}\"]" '1' 'false'
}

emit_success_with_files() {
    local files_json="$1"
    local count="$2"
    emit_json "$files_json" "$count" '[]' '0' 'false'
}

# ── Read params ───────────────────────────────────────────────────────────────
RECIPE_FRAMEWORK="${RECIPE_PARAM_FRAMEWORK:-}"
RECIPE_ROUTE="${RECIPE_PARAM_ROUTE:-}"
RECIPE_OUTPUT_DIR="${RECIPE_PARAM_OUTPUT_DIR:-src}"
RECIPE_OVERWRITE="${RECIPE_PARAM_OVERWRITE:-0}"

# ── Validate required params ──────────────────────────────────────────────────
if [[ -z "$RECIPE_FRAMEWORK" ]]; then
    emit_failure "RECIPE_PARAM_FRAMEWORK is required (flask|nextjs)"
    exit 1
fi
if [[ -z "$RECIPE_ROUTE" ]]; then
    emit_failure "RECIPE_PARAM_ROUTE is required"
    exit 1
fi

# ── Template directory ────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
TEMPLATES_DIR="${RECIPE_TEMPLATES_DIR:-$REPO_ROOT/recipes/templates/$RECIPE_FRAMEWORK}"

if [[ ! -d "$TEMPLATES_DIR" ]]; then
    emit_failure "template directory not found: $TEMPLATES_DIR (unknown framework: $RECIPE_FRAMEWORK)"
    exit 1
fi

# ── Name variants for substitution ────────────────────────────────────────────
# Convert route name: hyphens to underscores for Python/snake_case identifiers
ROUTE_SNAKE="${RECIPE_ROUTE//-/_}"
# PascalCase: capitalize after hyphens, underscores, and first char
ROUTE_PASCAL="$(echo "$RECIPE_ROUTE" | python3 -c "
import sys, re
s = sys.stdin.read().strip()
# Split on hyphens and underscores, capitalize each part
parts = re.split(r'[-_]', s)
print(''.join(p.capitalize() for p in parts if p))
")"

# ── Rollback state ────────────────────────────────────────────────────────────
CREATED_FILES=()
ADAPTER_FAILED=0

cleanup() {
    if [[ $ADAPTER_FAILED -eq 1 ]]; then
        for f in "${CREATED_FILES[@]:-}"; do
            [[ -n "$f" ]] && rm -f "$f" 2>/dev/null || true
        done
    fi
}
trap cleanup EXIT

# ── Ensure output directory exists ────────────────────────────────────────────
mkdir -p "$RECIPE_OUTPUT_DIR"

# ── Process each template ─────────────────────────────────────────────────────
FILES_CHANGED=()

for tmpl in "$TEMPLATES_DIR"/*.tmpl; do
    [[ -f "$tmpl" ]] || continue

    # Derive output filename from template basename
    basename_tmpl="${tmpl##*/}"
    outname="${basename_tmpl%.tmpl}"

    # Substitute leading "route" in filename with the snake_case route name
    # e.g. route.py → users.py, but api-route.ts → api-route.ts (preserve compound names)
    # Only replace when "route" appears as the sole word before the extension (i.e., starts the name)
    if [[ "$outname" == route.* ]]; then
        outname="${ROUTE_SNAKE}.${outname#route.}"
    fi

    outpath="$RECIPE_OUTPUT_DIR/$outname"

    # Idempotency: skip if file exists and OVERWRITE not set
    if [[ -f "$outpath" && "$RECIPE_OVERWRITE" != "1" ]]; then
        continue
    fi

    # Substitute placeholders (use printf-safe approach via python3 to avoid sed issues
    # with special chars in route names — injection safety)
    content=$(ROUTE_SNAKE="$ROUTE_SNAKE" ROUTE_PASCAL="$ROUTE_PASCAL" python3 - "$tmpl" <<'PYEOF'
import sys, os

tmpl_path = sys.argv[1]
route_snake = os.environ['ROUTE_SNAKE']
route_pascal = os.environ['ROUTE_PASCAL']

with open(tmpl_path, 'r') as f:
    content = f.read()

content = content.replace('{{ROUTE_NAME}}', route_snake)
content = content.replace('{{route_name}}', route_snake)
content = content.replace('{{RouteName}}', route_pascal)

sys.stdout.write(content)
PYEOF
    )

    printf '%s' "$content" > "$outpath"
    CREATED_FILES+=("$outpath")
    FILES_CHANGED+=("$outpath")
done

# ── Build JSON files array ────────────────────────────────────────────────────
if [[ ${#FILES_CHANGED[@]} -eq 0 ]]; then
    emit_success_with_files '[]' '0'
else
    # Build JSON array of file paths
    files_json=$(python3 -c "
import sys, json
files = sys.argv[1:]
print(json.dumps(files))
" "${FILES_CHANGED[@]}")
    emit_success_with_files "$files_json" "${#FILES_CHANGED[@]}"
fi

exit 0
