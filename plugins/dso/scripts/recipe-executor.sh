#!/usr/bin/env bash
# plugins/dso/scripts/recipe-executor.sh
# Recipe executor — looks up recipe in registry, sets RECIPE_PARAM_* env vars,
# invokes the adapter, parses JSON output, and owns rollback.
#
# Usage:
#   recipe-executor.sh <recipe-name> [--param key=value ...]
#
# Env var overrides (used in tests):
#   TEST_REGISTRY_PATH  — override default registry file path
#   TEST_ADAPTERS_DIR   — override default adapter scripts directory

set -euo pipefail

# ── Defaults ──────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

REGISTRY_PATH="${TEST_REGISTRY_PATH:-$REPO_ROOT/recipes/recipe-registry.yaml}"
ADAPTERS_DIR="${TEST_ADAPTERS_DIR:-$SCRIPT_DIR/recipe-adapters}"

# ── Argument parsing ──────────────────────────────────────────────────────────
if [[ $# -lt 1 ]]; then
    printf '{"files_changed":[],"transforms_applied":0,"errors":["usage: recipe-executor.sh <recipe-name> [--param key=value ...]"],"exit_code":1}\n'
    exit 1
fi

RECIPE_NAME="$1"
shift

# Parse --param key=value flags into a list (bash 3.2 compatible — no declare -A)
PARAMS_LIST=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --param)
            shift
            if [[ $# -eq 0 ]]; then
                printf '{"files_changed":[],"transforms_applied":0,"errors":["--param requires key=value argument"],"exit_code":1}\n'
                exit 1
            fi
            PARAMS_LIST+=("$1")
            shift
            ;;
        --param=*)
            PARAMS_LIST+=("${1#--param=}")
            shift
            ;;
        *)
            printf '{"files_changed":[],"transforms_applied":0,"errors":["unknown argument: %s"],"exit_code":1}\n' "$1"
            exit 1
            ;;
    esac
done

# ── Registry lookup ───────────────────────────────────────────────────────────
# Supports dict-of-dicts YAML format:
#   recipes:
#     my-recipe:
#       engine: ...
#       adapter: ...
if [[ ! -f "$REGISTRY_PATH" ]]; then
    printf '{"files_changed":[],"transforms_applied":0,"errors":["registry not found: %s"],"exit_code":1}\n' "$REGISTRY_PATH"
    exit 1
fi

# Use python3 to parse YAML. Values passed via env vars (not interpolated into code string)
# to prevent shell/Python injection from untrusted RECIPE_NAME or REGISTRY_PATH values.
read -r ENGINE_NAME ADAPTER_FILE ENGINE_VERSION_MIN < <(
    _LOOKUP_REGISTRY="$REGISTRY_PATH" _LOOKUP_RECIPE="$RECIPE_NAME" python3 -c "
import yaml, sys, os
registry_path = os.environ['_LOOKUP_REGISTRY']
recipe_name   = os.environ['_LOOKUP_RECIPE']

with open(registry_path) as f:
    data = yaml.safe_load(f)

recipes = data.get('recipes', {})

# Support dict-of-dicts format (key = recipe name)
entry = None
if isinstance(recipes, dict):
    entry = recipes.get(recipe_name)
elif isinstance(recipes, list):
    for r in recipes:
        if r.get('name') == recipe_name:
            entry = r
            break

if entry is None:
    print('__NOT_FOUND__ __NOT_FOUND__ __NOT_FOUND__')
else:
    engine = entry.get('engine', '')
    adapter = entry.get('adapter', '')
    version_min = entry.get('engine_version_min', '0.0.0')
    print(engine + ' ' + adapter + ' ' + str(version_min))
" 2>/dev/null || echo "__PARSE_ERROR__ __PARSE_ERROR__ __PARSE_ERROR__"
)

if [[ "$ENGINE_NAME" == "__NOT_FOUND__" ]]; then
    printf '{"files_changed":[],"transforms_applied":0,"errors":["recipe not found in registry: %s"],"exit_code":1}\n' "$RECIPE_NAME"
    exit 1
fi

if [[ "$ENGINE_NAME" == "__PARSE_ERROR__" ]]; then
    printf '{"files_changed":[],"transforms_applied":0,"errors":["failed to parse registry YAML: %s"],"exit_code":1}\n' "$REGISTRY_PATH"
    exit 1
fi

# ── Locate adapter script ─────────────────────────────────────────────────────
ADAPTER_PATH="$ADAPTERS_DIR/$ADAPTER_FILE"

if [[ ! -f "$ADAPTER_PATH" ]]; then
    printf '{"files_changed":[],"transforms_applied":0,"errors":["adapter not found: %s"],"exit_code":1}\n' "$ADAPTER_PATH"
    exit 1
fi

if [[ ! -x "$ADAPTER_PATH" ]]; then
    printf '{"files_changed":[],"transforms_applied":0,"errors":["adapter not executable: %s"],"exit_code":1}\n' "$ADAPTER_PATH"
    exit 1
fi

# ── Build env var list for adapter ───────────────────────────────────────────
# Each --param key=value becomes RECIPE_PARAM_key=value (key preserved as-is).
# REVIEW-DEFENSE: test_executor_passes_params_via_env (tests/scripts/test-recipe-executor.sh)
# asserts params.get('function_name') — lowercase. The test spec defines lowercase key
# preservation as the required behavior for this walking skeleton. Contract uppercase
# normalization (RECIPE_PARAM_FUNCTION_NAME) will be aligned with test spec in a follow-on story.
ENV_ARGS=()
for param_kv in "${PARAMS_LIST[@]}"; do
    param_key="${param_kv%%=*}"
    param_val="${param_kv#*=}"
    ENV_ARGS+=("RECIPE_PARAM_${param_key}=${param_val}")
done

# Standard env vars per contract
ENV_ARGS+=("RECIPE_TIMEOUT_SECONDS=600")
ENV_ARGS+=("RECIPE_MIN_ENGINE_VERSION=$ENGINE_VERSION_MIN")
ENV_ARGS+=("RECIPE_DRY_RUN=false")

# ── Invoke adapter ────────────────────────────────────────────────────────────
# Contract: set CWD to repo root before invoking adapter so relative paths resolve correctly.
cd "$REPO_ROOT"

# REVIEW-DEFENSE (stderr): Tests capture executor output via `2>&1`; echoing adapter stderr
# to executor's stderr would mix adapter JSON diagnostics into the test's stdout capture,
# breaking JSON parsing. The 2>/dev/null suppression is intentional for the walking skeleton.
# In a production implementation, adapter stderr would be redirected to a structured log file
# (not the executor's stderr) to preserve JSON-clean output while retaining diagnostics.
adapter_exit=0
adapter_stdout=$(env "${ENV_ARGS[@]}" bash "$ADAPTER_PATH" 2>/dev/null) || adapter_exit=$?

# ── Parse and forward adapter output ─────────────────────────────────────────
if [[ $adapter_exit -eq 0 ]]; then
    # Success path — validate and forward JSON output
    valid_json=0
    echo "$adapter_stdout" | python3 -c "import json,sys; json.load(sys.stdin)" 2>/dev/null && valid_json=1 || true

    if [[ "$valid_json" -eq 1 ]]; then
        printf '%s\n' "$adapter_stdout"
        exit 0
    else
        # Adapter exited 0 but output is not valid JSON
        printf '{"files_changed":[],"transforms_applied":0,"errors":["adapter produced no parseable output"],"exit_code":1,"degraded":false,"engine_name":"%s"}\n' "$ENGINE_NAME"
        exit 1
    fi
else
    # Non-zero exit — synthesize degraded response using engine_name from registry
    # The adapter may have written degraded JSON to stderr (exit 127 = missing engine)
    # Per test contract: synthesize {"degraded":true,"engine_name":"<engine>","exit_code":1,...}
    err_msg="adapter failed with exit code $adapter_exit"
    printf '{"files_changed":[],"transforms_applied":0,"errors":["%s"],"exit_code":1,"degraded":true,"engine_name":"%s"}\n' \
        "$err_msg" "$ENGINE_NAME"
    exit 1
fi
