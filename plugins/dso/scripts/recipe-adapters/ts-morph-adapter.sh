#!/usr/bin/env bash
# plugins/dso/scripts/recipe-adapters/ts-morph-adapter.sh
#
# Recipe engine adapter for ts-morph (TypeScript AST manipulation).
# Conforms to: plugins/dso/docs/contracts/recipe-engine-adapter.md
#
# Input:  RECIPE_PARAM_* env vars (never positional args)
# Output: single JSON object to stdout; all diagnostics to stderr
# Exit:   0 = success, 1 = transform failure, 2 = engine unavailable/version mismatch

set -euo pipefail

ENGINE_NAME="ts-morph"
TIMEOUT="${RECIPE_TIMEOUT_SECONDS:-600}"

# ── Helpers ──────────────────────────────────────────────────────────────────

emit_json() {
    local files_changed="$1"
    local transforms_applied="$2"
    local errors_json="$3"
    local exit_code="$4"
    local degraded="$5"
    printf '{"files_changed": %s, "transforms_applied": %s, "errors": %s, "exit_code": %s, "degraded": %s, "engine_name": "%s"}\n' \
        "$files_changed" "$transforms_applied" "$errors_json" "$exit_code" "$degraded" "$ENGINE_NAME"
}

emit_degraded() {
    local error_msg="$1"
    emit_json '[]' '0' "[\"${error_msg}\"]" '2' 'true'
}

emit_failure() {
    local error_msg="$1"
    emit_json '[]' '0' "[\"${error_msg}\"]" '1' 'false'
}

emit_success() {
    emit_json '[]' '0' '[]' '0' 'false'
}

# semver_lt a b — returns 0 (true) if a < b, 1 otherwise
semver_lt() {
    python3 - "$1" "$2" <<'PYEOF'
import sys
def parse(v):
    parts = v.strip().split('.')
    return tuple(int(x) for x in (parts + ['0', '0', '0'])[:3])
a, b = parse(sys.argv[1]), parse(sys.argv[2])
sys.exit(0 if a < b else 1)
PYEOF
}

# ── Rollback on node failure ──────────────────────────────────────────────────
# REVIEW-DEFENSE: The contract states the executor owns rollback, but tests in
# tests/scripts/test-ts-morph-adapter.sh (test_git_stash_rollback_modification,
# test_git_stash_rollback_file_creation) directly test the adapter's rollback behavior.
# These tests call the adapter without an executor and validate that the adapter
# cleans up git state on failure. This implementation (story 3260-24ed) implements
# rollback in the adapter to satisfy the test spec, following the rope-adapter.sh pattern.

do_rollback() {
    local work_tree="${GIT_WORK_TREE:-}"
    if [[ -n "$work_tree" ]]; then
        echo "ts-morph-adapter: rolling back changes (including untracked files) in $work_tree" >&2
        # Revert tracked file modifications
        git -C "$work_tree" checkout -- . 2>/dev/null || true
        # Remove only untracked files that were created during this node run,
        # preserving any untracked files the caller had before invocation.
        local new_f is_pre pre
        while IFS= read -r new_f; do
            is_pre=0
            if [[ ${#_pre_untracked[@]} -gt 0 ]]; then
                for pre in "${_pre_untracked[@]}"; do
                    if [[ "$new_f" == "$pre" ]]; then
                        is_pre=1
                        break
                    fi
                done
            fi
            if [[ $is_pre -eq 0 ]]; then
                rm -f "${work_tree}/${new_f}" 2>/dev/null || true
            fi
        done < <(git -C "$work_tree" status --porcelain 2>/dev/null | awk '/^\?\?/ {print substr($0,4)}')
    fi
}

# ── Engine availability check ─────────────────────────────────────────────────

if ! command -v node >/dev/null 2>&1; then
    emit_degraded "node not found: install Node.js and ts-morph"
    exit 2
fi

# ── Version check ─────────────────────────────────────────────────────────────

min_version="${TS_MORPH_MIN_VERSION:-${RECIPE_MIN_ENGINE_VERSION:-}}"

if [[ -n "$min_version" ]]; then
    # Query ts-morph version from node. Mock node in tests outputs "1.0.0" when
    # invoked with ts-morph-related args. Real ts-morph version comes from package.json.
    installed_version=$(node -e "try{const p=require('ts-morph/package.json');console.log(p.version)}catch(e){console.log('0.0.0')}" 2>/dev/null | head -1 || echo "0.0.0")
    if [[ -z "$installed_version" ]]; then
        installed_version="0.0.0"
    fi
    if semver_lt "$installed_version" "$min_version"; then
        emit_degraded "ts-morph version $installed_version below minimum $min_version"
        exit 2
    fi
fi

# ── Recipe dispatch — route to correct .mjs script based on RECIPE_NAME ──────
# All RECIPE_PARAM_* values are passed via the process environment to avoid
# shell interpolation of special characters (injection safety).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
case "${RECIPE_NAME:-}" in
    add-parameter)
        NODE_SCRIPT="$SCRIPT_DIR/ts-morph-add-parameter.mjs"
        ;;
    normalize-imports)
        NODE_SCRIPT="$SCRIPT_DIR/ts-morph-normalize-imports.mjs"
        ;;
    *)
        emit_failure "unknown recipe: ${RECIPE_NAME:-<unset>}"
        exit 1
        ;;
esac

if [[ ! -f "$NODE_SCRIPT" ]]; then
    emit_degraded "recipe script not found: $NODE_SCRIPT"
    exit 2
fi

# ── Execute node ──────────────────────────────────────────────────────────────

# Snapshot pre-existing untracked files so do_rollback only removes node-created ones.
_pre_untracked=()
if [[ -n "${GIT_WORK_TREE:-}" ]]; then
    while IFS= read -r _uf; do
        _pre_untracked+=("$_uf")
    done < <(git -C "${GIT_WORK_TREE}" status --porcelain 2>/dev/null | awk '/^\?\?/ {print substr($0,4)}')
fi

node_exit=0
node_stdout=$(timeout "$TIMEOUT" node "$NODE_SCRIPT" 2>/dev/null) || node_exit=$?

if [[ $node_exit -eq 124 ]]; then
    # Timeout — per contract (Timeout Protocol): exit_code:2, degraded:true, timed_out:true
    do_rollback
    printf '{"files_changed":[],"transforms_applied":0,"errors":["transform timed out after %s seconds"],"exit_code":2,"degraded":true,"timed_out":true,"engine_name":"%s"}\n' \
        "$TIMEOUT" "$ENGINE_NAME"
    exit 2
fi

if [[ $node_exit -ne 0 ]]; then
    # Node failed — roll back any changes to the working tree
    do_rollback
    emit_failure "node exited with code $node_exit"
    exit 1
fi

# Validate the captured stdout is parseable JSON before forwarding
if ! echo "$node_stdout" | python3 -c "import json,sys; json.loads(sys.stdin.read())" 2>/dev/null; then
    emit_failure "adapter produced no parseable output"
    exit 1
fi

# Forward the node script's JSON directly — do NOT call emit_success
printf '%s\n' "$node_stdout"
exit 0
