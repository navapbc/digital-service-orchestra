#!/usr/bin/env bash
# plugins/dso/scripts/recipe-adapters/isort-adapter.sh
#
# Recipe engine adapter for the isort Python import sorter.
# Conforms to: plugins/dso/docs/contracts/recipe-engine-adapter.md
#
# Input:  RECIPE_PARAM_* env vars (never positional args)
# Output: single JSON object to stdout; all diagnostics to stderr
# Exit:   0 = success, 1 = transform failure, 2 = engine unavailable/version mismatch

set -euo pipefail

ENGINE_NAME="isort"
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

# ── Engine availability check ─────────────────────────────────────────────────
# Try isort binary first, fall back to python3 -m isort.

ISORT_CMD=""
if command -v isort >/dev/null 2>&1; then
    ISORT_CMD="isort"
elif python3 -m isort --version >/dev/null 2>&1; then
    ISORT_CMD="python3 -m isort"
else
    emit_degraded "isort not found: install via 'pip install isort>=5'"
    exit 2
fi

# ── Version check ─────────────────────────────────────────────────────────────

min_version="${ISORT_MIN_VERSION:-${RECIPE_MIN_ENGINE_VERSION:-}}"

if [[ -n "$min_version" ]]; then
    # Extract version from isort --version output.
    # isort outputs "VERSION X.Y.Z" or just "X.Y.Z".
    installed_version=$(${ISORT_CMD} --version 2>&1 | awk '/VERSION/ {print $2; exit} /^[0-9]/ {print $1; exit}' | head -1)
    if [[ -z "$installed_version" ]]; then
        installed_version="0.0.0"
    fi
    if semver_lt "$installed_version" "$min_version"; then
        emit_degraded "isort version $installed_version below minimum $min_version"
        exit 2
    fi
fi

# ── Execute isort ──────────────────────────────────────────────────────────────
# All RECIPE_PARAM_* values are passed via the process environment to avoid
# shell interpolation of special characters (injection safety).

# Validate required input
TARGET="${RECIPE_PARAM_FILE:-}"
TARGET_DIR="${RECIPE_PARAM_DIR:-}"
if [[ -z "$TARGET" && -z "$TARGET_DIR" ]]; then
    emit_failure "RECIPE_PARAM_FILE or RECIPE_PARAM_DIR is required"
    exit 1
fi

isort_exit=0
if [[ -n "$TARGET" ]]; then
    timeout "$TIMEOUT" $ISORT_CMD -- "$TARGET" 2>/dev/null || isort_exit=$?
else
    timeout "$TIMEOUT" $ISORT_CMD -- "$TARGET_DIR" 2>/dev/null || isort_exit=$?
fi

if [[ $isort_exit -eq 124 ]]; then
    # Timeout — per contract (Timeout Protocol): exit_code:2, degraded:true, timed_out:true
    # Rollback is owned by recipe-executor.sh (git stash push/pop).
    printf '{"files_changed":[],"transforms_applied":0,"errors":["transform timed out after %s seconds"],"exit_code":2,"degraded":true,"timed_out":true,"engine_name":"%s"}\n' \
        "$TIMEOUT" "$ENGINE_NAME"
    exit 2
fi

if [[ $isort_exit -ne 0 ]]; then
    # isort failed — rollback is owned by recipe-executor.sh (git stash push/pop).
    emit_failure "isort exited with code $isort_exit"
    exit 1
fi

emit_success
exit 0
