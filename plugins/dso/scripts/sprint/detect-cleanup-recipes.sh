#!/usr/bin/env bash
# detect-cleanup-recipes.sh
# Examines a git diff and identifies applicable cleanup recipes from the registry.
#
# Environment:
#   RECIPE_REGISTRY_PATH  — path to recipe-registry.yaml (required)
#   DIFF_INPUT            — path to diff file (optional; reads git diff --cached if absent)
#
# Options:
#   --format=json         — output JSON array instead of plain text
#
# Output (text):  one line per applicable recipe: "normalize-imports python"
# Output (json):  [{"name":"normalize-imports","language":"python"}]
# Empty output when no applicable recipes found. Exit 0 always.

set -uo pipefail

FORMAT="text"
for arg in "$@"; do
    case "$arg" in
        --format=json) FORMAT="json" ;;
    esac
done

REGISTRY="${RECIPE_REGISTRY_PATH:-}"
if [[ -z "$REGISTRY" ]]; then
    echo "Error: RECIPE_REGISTRY_PATH is required" >&2
    exit 1
fi
if [[ ! -f "$REGISTRY" ]]; then
    echo "Error: registry not found: $REGISTRY" >&2
    exit 1
fi

# Read diff input
if [[ -n "${DIFF_INPUT:-}" ]]; then
    diff_content="$(cat "$DIFF_INPUT")"
else
    diff_content="$(git diff --cached 2>/dev/null || true)"
fi

[[ -z "$diff_content" ]] && exit 0

# Extract unique languages from file extensions in diff headers
declare -A seen_langs
while IFS= read -r line; do
    [[ "$line" =~ ^diff\ --git\ a/(.+)\ b/ ]] || continue
    filepath="${BASH_REMATCH[1]}"
    case "$filepath" in
        *.py)       seen_langs["python"]=1 ;;
        *.ts|*.tsx) seen_langs["typescript"]=1 ;;
        *.rb)       seen_langs["ruby"]=1 ;;
    esac
done <<< "$diff_content"

[[ ${#seen_langs[@]} -eq 0 ]] && exit 0

# Check if normalize-imports recipe exists for a given language using awk (no python3 needed).
_registry_has_normalize_imports() {
    local target_lang="$1"
    awk -v target="$target_lang" '
        /- name:/ {
            split($0, a, ":")
            name = a[2]
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", name)
            in_normalize = (name == "normalize-imports")
            engine = ""; lang = ""
        }
        in_normalize && /language:/ {
            split($0, a, ":")
            lang = a[2]
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", lang)
            if (lang == target) { print "FOUND"; exit }
        }
    ' "$REGISTRY" | grep -q FOUND
}

results=()
for lang in "${!seen_langs[@]}"; do
    _registry_has_normalize_imports "$lang" && results+=("normalize-imports $lang")
done

[[ ${#results[@]} -eq 0 ]] && exit 0

if [[ "$FORMAT" == "json" ]]; then
    # Build JSON array from results (each item is "name lang")
    json_items=()
    for item in "${results[@]}"; do
        name="${item%% *}"
        lang="${item#* }"
        json_items+=("{\"name\":\"$name\",\"language\":\"$lang\"}")
    done
    (IFS=','; joined="${json_items[*]}"; echo "[$joined]")
else
    printf '%s\n' "${results[@]}"
fi
