#!/usr/bin/env bash
# check-recipe-engines.sh
# Scans the sprint task list for recipe: tasks and validates that each referenced
# engine is installed and meets the minimum version requirement from the registry.
#
# Environment:
#   RECIPE_REGISTRY_PATH  — path to recipe-registry.yaml (injectable for test isolation)
#   TASK_LIST_FILE        — path to JSON array of tasks (injectable for test isolation)
#
# Output lines:
#   NO_RECIPE_TASKS               — no recipe: tasks found; exits 0
#   ENGINES_OK                    — all engines present and version-compatible; exits 0
#   MISSING_ENGINE: <e> minimum:<v>  — engine not installed; exits 1
#   OUTDATED_ENGINE: <e> found:<v> minimum:<v>  — engine below min version; exits 1
#   MISSING_ENGINES_LIST=<e1,e2>  — always last; comma-separated missing/outdated engines
#
# Exit: 0 when OK or no recipe tasks; 1 when any engine is missing or outdated.

set -uo pipefail

REGISTRY="${RECIPE_REGISTRY_PATH:-}"
TASK_FILE="${TASK_LIST_FILE:-}"

if [[ -z "$REGISTRY" || ! -f "$REGISTRY" ]]; then
    echo "Error: recipe registry not found: ${REGISTRY:-<RECIPE_REGISTRY_PATH not set>}" >&2
    exit 1
fi

if [[ -z "$TASK_FILE" || ! -f "$TASK_FILE" ]]; then
    echo "Error: task list file not found: ${TASK_FILE:-<TASK_LIST_FILE not set>}" >&2
    exit 1
fi

# Extract unique recipe names from task list JSON (tags matching "recipe:<name>").
# Uses grep/sed to avoid python3 dependency (stubs intercept python3 calls for engine checks).
recipe_names=()
while IFS= read -r name; do
    [[ -n "$name" ]] && recipe_names+=("$name")
done < <(grep -oE '"recipe:[^"]*"' "$TASK_FILE" | tr -d '"' | sed 's/^recipe://' | sort -u)

if [[ ${#recipe_names[@]} -eq 0 ]]; then
    echo "NO_RECIPE_TASKS"
    exit 0
fi

# Look up engine + min_engine_version for a recipe in the registry using awk.
_lookup_engine() {
    local recipe="$1"
    awk -v recipe="$recipe" '
        /- name:/ {
            split($0, a, ":")
            cur_name = a[2]
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", cur_name)
            cur_engine = ""; cur_min_ver = ""
        }
        cur_name == recipe && /engine:/ && !/min_engine/ {
            split($0, a, ":")
            cur_engine = a[2]
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", cur_engine)
        }
        cur_name == recipe && /min_engine_version:/ {
            split($0, a, ":")
            cur_min_ver = a[2]
            gsub(/^[[:space:]]+|[[:space:]]+"|"[[:space:]]*$/, "", cur_min_ver)
            gsub(/"/, "", cur_min_ver)
        }
        cur_name == recipe && cur_engine && cur_min_ver {
            print cur_engine " " cur_min_ver
            exit
        }
    ' "$REGISTRY"
}

# Pure-bash semver comparison: returns 0 (true) if $1 >= $2
_version_gte() {
    local v1="$1" v2="$2"
    IFS='.' read -ra a1 <<< "$v1"
    IFS='.' read -ra a2 <<< "$v2"
    local i
    for i in 0 1 2; do
        local n1="${a1[$i]:-0}" n2="${a2[$i]:-0}"
        (( 10#$n1 > 10#$n2 )) && return 0
        (( 10#$n1 < 10#$n2 )) && return 1
    done
    return 0
}

missing_engines=()
any_problem=0

for recipe in "${recipe_names[@]}"; do
    lookup_result="$(_lookup_engine "$recipe")"
    if [[ -z "$lookup_result" ]]; then
        echo "Warning: recipe '$recipe' not found in registry" >&2
        continue
    fi

    engine="${lookup_result%% *}"
    min_ver="${lookup_result#* }"

    case "$engine" in
        rope)
            # python3 -c is intercepted by stubs: exit 1 = missing, output = version string
            found_ver="$(python3 -c 'import rope; print(rope.version.VERSION)' 2>/dev/null)" || {
                echo "MISSING_ENGINE: $engine minimum:$min_ver"
                missing_engines+=("$engine")
                any_problem=1
                continue
            }
            if ! _version_gte "$found_ver" "$min_ver"; then
                echo "OUTDATED_ENGINE: $engine found:$found_ver minimum:$min_ver"
                missing_engines+=("$engine")
                any_problem=1
            fi
            ;;
        *)
            if ! command -v "$engine" >/dev/null 2>&1; then
                echo "MISSING_ENGINE: $engine minimum:$min_ver"
                missing_engines+=("$engine")
                any_problem=1
            fi
            ;;
    esac
done

if [[ $any_problem -eq 0 ]]; then
    echo "ENGINES_OK"
fi

# Always emit MISSING_ENGINES_LIST for S5 fallback consumption
engines_csv=""
if [[ ${#missing_engines[@]} -gt 0 ]]; then
    engines_csv="$(printf '%s,' "${missing_engines[@]}")"
    engines_csv="${engines_csv%,}"
fi
echo "MISSING_ENGINES_LIST=$engines_csv"

exit $any_problem
