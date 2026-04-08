#!/usr/bin/env bash
# plugins/dso/scripts/recipe-adapters/synvert-adapter.sh
# Recipe adapter for normalize-imports (Ruby/Synvert).
#
# Contract: plugins/dso/docs/contracts/recipe-engine-adapter.md
# Parameters (via RECIPE_PARAM_* env vars):
#   RECIPE_PARAM_file       — Ruby source file to normalize imports in (required)
#   RECIPE_PARAM_project_root — Project root directory (optional, defaults to CWD)
#
# Exit codes: 0=success, 1=error, 2=degraded (engine missing or version below minimum)
# Output: JSON to stdout — {files_changed, transforms_applied, errors, exit_code, degraded, engine_name}
#
# Rollback contract: adapters MUST NOT manage git state (no stash, checkout, or commit).
# The executor (recipe-executor.sh) owns all rollback via git stash push/pop.

set -euo pipefail

ENGINE_NAME="synvert"

# ── Parameter extraction ──────────────────────────────────────────────────────
FILE_PATH="${RECIPE_PARAM_file:-}"
PROJECT_ROOT="${RECIPE_PARAM_project_root:-${GIT_WORK_TREE:-$(pwd)}}"

if [[ -z "$FILE_PATH" ]]; then
    printf '{"files_changed":[],"transforms_applied":0,"errors":["RECIPE_PARAM_file is required"],"exit_code":1,"degraded":false,"engine_name":"%s"}\n' "$ENGINE_NAME"
    exit 1
fi

# ── Path safety validation (before file-exists check) ────────────────────────
# Reject paths with characters unsafe to embed in a Ruby heredoc string.
# Allowed: alphanumeric, slash, dot, hyphen, underscore.
_REL_PATH_CHECK="${FILE_PATH#$PROJECT_ROOT/}"
if [[ "$_REL_PATH_CHECK" =~ [^a-zA-Z0-9/_.\-] ]]; then
    printf '{"files_changed":[],"transforms_applied":0,"errors":["unsafe characters in file path"],"exit_code":1,"degraded":false,"engine_name":"%s"}\n' "$ENGINE_NAME"
    exit 1
fi

if [[ ! -f "$FILE_PATH" ]]; then
    printf '{"files_changed":[],"transforms_applied":0,"errors":["file not found"],"exit_code":1,"degraded":false,"engine_name":"%s"}\n' "$ENGINE_NAME"
    exit 1
fi

# ── Engine availability check ─────────────────────────────────────────────────
if ! command -v synvert >/dev/null 2>&1 && ! command -v synvert-ruby >/dev/null 2>&1; then
    printf '{"files_changed":[],"transforms_applied":0,"errors":["synvert engine not found — install with: gem install synvert"],"exit_code":2,"degraded":true,"engine_name":"%s"}\n' "$ENGINE_NAME"
    exit 2
fi

SYNVERT_CMD="synvert"
command -v synvert >/dev/null 2>&1 || SYNVERT_CMD="synvert-ruby"

# ── Engine version check ──────────────────────────────────────────────────────
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

MIN_VERSION="${RECIPE_MIN_ENGINE_VERSION:-}"
if [[ -n "$MIN_VERSION" ]]; then
    installed_version=$("$SYNVERT_CMD" --version 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "")
    if [[ -z "$installed_version" ]]; then
        installed_version=$("$SYNVERT_CMD" version 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "0.0.0")
    fi
    if semver_lt "$installed_version" "$MIN_VERSION"; then
        printf '{"files_changed":[],"transforms_applied":0,"errors":["synvert version %s is below minimum required %s"],"exit_code":2,"degraded":true,"engine_name":"%s"}\n' \
            "$installed_version" "$MIN_VERSION" "$ENGINE_NAME"
        exit 2
    fi
fi

# ── Capture pre-run state (Python-based, portable across macOS/Linux) ─────────
# FILE_PATH is passed via sys.argv[1] to avoid single-quote injection in the -c string.
pre_hash=$(python3 - "$FILE_PATH" <<'PYEOF'
import hashlib, sys
try:
    print(hashlib.sha256(open(sys.argv[1], 'rb').read()).hexdigest())
except Exception:
    print('')
PYEOF
) || pre_hash=""

# ── Compute relative path (already validated above) ──────────────────────────
_REL_PATH="${FILE_PATH#$PROJECT_ROOT/}"

# ── Write snippet to temp file for synvert CLI ────────────────────────────────
# synvert-ruby expects a snippet file, not an inline string.
# The snippet is scoped to the specific _REL_PATH (single-file scope).
# The snippet file is cleaned up on exit regardless of success/failure.
_SNIPPET_FILE=$(mktemp /tmp/synvert-snippet-XXXXXX.rb)
trap 'rm -f "$_SNIPPET_FILE"' EXIT

cat > "$_SNIPPET_FILE" <<SNIPPET
Synvert::Rewriter.new "normalize_imports", "sort_requires" do
  within_file "${_REL_PATH}" do
    # Sort require/require_relative statements at the top of the file.
    # This is a stub — actual AST rewrite logic to be implemented when
    # synvert snippet API is confirmed against target synvert version.
  end
end
SNIPPET

# ── Run synvert to normalize imports ─────────────────────────────────────────
synvert_exit=0
# Use --run (standard synvert-ruby CLI flag for executing a snippet file).
"$SYNVERT_CMD" --run "$_SNIPPET_FILE" --path "$PROJECT_ROOT" 2>/dev/null || synvert_exit=$?

if [[ $synvert_exit -ne 0 ]]; then
    # Do NOT manage git state here — the executor owns rollback via stash pop.
    printf '{"files_changed":[],"transforms_applied":0,"errors":["synvert execution failed with exit code %d"],"exit_code":1,"degraded":false,"engine_name":"%s"}\n' \
        "$synvert_exit" "$ENGINE_NAME"
    exit 1
fi

# ── Detect changes (Python-based hash, portable) ──────────────────────────────
post_hash=$(python3 - "$FILE_PATH" <<'PYEOF'
import hashlib, sys
try:
    print(hashlib.sha256(open(sys.argv[1], 'rb').read()).hexdigest())
except Exception:
    print('')
PYEOF
) || post_hash=""

files_changed="[]"
transforms_applied=0
if [[ -n "$pre_hash" ]] && [[ -n "$post_hash" ]] && [[ "$pre_hash" != "$post_hash" ]]; then
    rel_path="${FILE_PATH#$PROJECT_ROOT/}"
    files_changed='["'"$rel_path"'"]'
    transforms_applied=1
fi

printf '{"files_changed":%s,"transforms_applied":%d,"errors":[],"exit_code":0,"degraded":false,"engine_name":"%s"}\n' \
    "$files_changed" "$transforms_applied" "$ENGINE_NAME"
exit 0
