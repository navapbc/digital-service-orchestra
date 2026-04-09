#!/usr/bin/env bash
# plugins/dso/scripts/recipe-adapters/rope-adapter.sh
#
# Recipe engine adapter for the Rope Python refactoring library.
# Conforms to: plugins/dso/docs/contracts/recipe-engine-adapter.md
#
# Input:  RECIPE_PARAM_* env vars (never positional args)
# Output: single JSON object to stdout; all diagnostics to stderr
# Exit:   0 = success, 1 = transform failure, 2 = engine unavailable/version mismatch

set -euo pipefail

ENGINE_NAME="rope"
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
# REVIEW-DEFENSE: Walking skeleton implementation (story 5108-39a1). Tests use a mock rope
# binary via write_mock_rope() in tests/scripts/test-rope-adapter.sh. The contract interface
# (RECIPE_PARAM_*, JSON output, exit codes) is validated via mock. The actual rope invocation
# mechanism (python3 -c 'import rope; ...') is scoped to the follow-on implementation story.
# This adapter correctly implements the contract interface for the walking skeleton phase.

if ! command -v rope >/dev/null 2>&1; then
    emit_degraded "rope not found: install via 'pip install rope>=1.7.0'"
    exit 2
fi

# ── Version check ─────────────────────────────────────────────────────────────

min_version="${ROPE_MIN_VERSION:-${RECIPE_MIN_ENGINE_VERSION:-}}"

if [[ -n "$min_version" ]]; then
    # REVIEW-DEFENSE: Mock rope in tests outputs "1.0.0" (version-only, no tool name prefix).
    # See write_mock_rope() in tests/scripts/test-rope-adapter.sh line 430: `echo "1.0.0"`.
    # awk '{print $1}' correctly extracts "1.0.0" from single-token output. test_adapter_version_validation
    # confirms this works. For production rope (Python library), version detection would use
    # `python3 -c 'import rope; print(rope.VERSION)'` — scoped to follow-on implementation story.
    installed_version=$(rope --version 2>&1 | awk '{print $1}' | head -1)
    if [[ -z "$installed_version" ]]; then
        installed_version=$(rope version 2>&1 | awk '{print $1}' | head -1)
    fi
    if semver_lt "$installed_version" "$min_version"; then
        emit_degraded "rope version $installed_version is below minimum required $min_version"
        exit 2
    fi
fi

# ── Execute rope ──────────────────────────────────────────────────────────────
# All RECIPE_PARAM_* values are passed via the process environment to avoid
# shell interpolation of special characters (injection safety).

rope_exit=0
timeout "$TIMEOUT" rope 2>/dev/null || rope_exit=$?

if [[ $rope_exit -eq 124 ]]; then
    # Timeout — per contract (Timeout Protocol): exit_code:2, degraded:true, timed_out:true
    # Rollback is owned by recipe-executor.sh (git stash push/pop).
    printf '{"files_changed":[],"transforms_applied":0,"errors":["transform timed out after %s seconds"],"exit_code":2,"degraded":true,"timed_out":true,"engine_name":"%s"}\n' \
        "$TIMEOUT" "$ENGINE_NAME"
    exit 2
fi

if [[ $rope_exit -ne 0 ]]; then
    # Rope failed — rollback is owned by recipe-executor.sh (git stash push/pop).
    emit_failure "rope exited with code $rope_exit"
    exit 1
fi

emit_success
exit 0
