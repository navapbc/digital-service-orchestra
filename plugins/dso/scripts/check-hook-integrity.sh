#!/usr/bin/env bash
# check-hook-integrity.sh
# Off-hot-path integrity check for the load-bearing enforcement hooks.
#
# WHY: the PreToolUse hook chain is fail-open by design — a missing file, lost
# executable bit, or syntax error degrades to "no enforcement" SILENTLY
# (run-hook.sh exits 0 on syntax/missing; a non-+x dispatcher makes run-hook's
# `"$HOOK"` exec fail with 126, which the dispatcher treats as allow). This
# script makes that silent degradation VISIBLE: it asserts each enforcement
# hook is present, `bash -n`-clean, and (for directly-invoked entries)
# executable. Run it in CI / at commit time / at session start — NOT on the
# per-tool-call hot path.
#
# Usage: check-hook-integrity.sh
# Env:   DSO_HOOK_INTEGRITY_HOOKS_DIR  override the hooks/ dir to inspect (tests)
#
# Exit codes:
#   0 — all enforcement hooks intact
#   1 — one or more integrity violations (reported to stderr)
set -uo pipefail

# Resolve the hooks/ directory: explicit override (tests) → CLAUDE_PLUGIN_ROOT →
# this script's own location (scripts/ -> plugin root -> hooks/).
if [[ -n "${DSO_HOOK_INTEGRITY_HOOKS_DIR:-}" ]]; then
    HOOKS_DIR="$DSO_HOOK_INTEGRITY_HOOKS_DIR"
elif [[ -n "${CLAUDE_PLUGIN_ROOT:-}" && -d "${CLAUDE_PLUGIN_ROOT}/hooks" ]]; then
    HOOKS_DIR="${CLAUDE_PLUGIN_ROOT}/hooks"
else
    _self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    HOOKS_DIR="$(cd "$_self_dir/.." && pwd)/hooks"
fi

# Load-bearing enforcement hooks.
#   DIRECT  = invoked as an executable (run-hook.sh execs the dispatcher;
#             pre-commit-wrapper.sh execs the git gates) → must be +x.
#   SOURCED = sourced into a running shell → must exist + parse, +x not required.
# A lost +x on a DIRECT entry is a silent fail-open vector (exec → 126 → allow).
DIRECT_HOOKS=(
    "run-hook.sh"
    "dispatchers/pre-bash.sh"
    "dispatchers/pre-edit.sh"
    "dispatchers/pre-write.sh"
    "pre-commit-review-gate.sh"
    "pre-commit-test-gate.sh"
)
SOURCED_HOOKS=(
    "lib/dispatcher.sh"
    "lib/pre-bash-functions.sh"
    "lib/review-gate-bypass-sentinel.sh"
    "lib/deps.sh"
    "lib/enforcement-gate.sh"
    "lib/hook-error-handler.sh"
)

violations=0
_fail() { printf '  VIOLATION: %s\n' "$1" >&2; violations=$((violations + 1)); }

_check_present_and_parses() {
    local path="$1"
    if [[ ! -f "$path" ]]; then
        _fail "missing: ${path#"$HOOKS_DIR"/}"
        return 1
    fi
    if ! bash -n "$path" 2>/dev/null; then
        _fail "syntax error: ${path#"$HOOKS_DIR"/}"
        return 1
    fi
    return 0
}

for rel in "${DIRECT_HOOKS[@]}"; do
    p="$HOOKS_DIR/$rel"
    _check_present_and_parses "$p" || continue
    [[ -x "$p" ]] || _fail "not executable (silent fail-open risk): $rel"
done

for rel in "${SOURCED_HOOKS[@]}"; do
    _check_present_and_parses "$HOOKS_DIR/$rel" || continue
done

if [[ "$violations" -gt 0 ]]; then
    echo "" >&2
    echo "ERROR: $violations enforcement-hook integrity violation(s) in $HOOKS_DIR." >&2
    echo "These hooks fail OPEN when broken — a violation means enforcement may be silently disabled." >&2
    exit 1
fi

exit 0
