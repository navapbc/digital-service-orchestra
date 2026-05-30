#!/usr/bin/env bash
# .claude/hooks/pre-commit/check-script-dir-pattern.sh
# Pre-commit hook: block REPO_ROOT="$SCRIPT_DIR/..", REPO_ROOT="${SCRIPT_DIR}/..",
# and `: "${REPO_ROOT:=$SCRIPT_DIR/..}"` patterns in plugin scripts.
#
# Bug 8229 — prevention hook for the host-portability bug class fixed in
# bugs 34b2 (check-skill-refs.sh), 3706 (qualify-skill-refs.sh), and a530
# (check-test-isolation.sh). When a plugin script derives REPO_ROOT from
# SCRIPT_DIR/.., it silently resolves to the plugin cache root on host
# projects (via the .claude/scripts/dso shim). For checker scripts this
# is a silent PASS; for mutator scripts it edits the plugin cache instead
# of the host repo (rule:no-edit-plugin-cache violation).
#
# Canonical pattern (established at check-rule-anchors.sh:48):
#   REPO_ROOT="${PROJECT_ROOT:-$(git rev-parse --show-toplevel)}"
#   if [[ -z "$REPO_ROOT" ]]; then
#     echo "ERROR: cannot resolve REPO_ROOT (...)" >&2
#     exit 1
#   fi
#
# Suppression: when a script is legitimately plugin-internal (never
# invoked on host projects), add a line-local marker:
#   # script-dir-pattern-ok: <one-sentence rationale>
# on the SAME line as the assignment.
#
# Usage:
#   check-script-dir-pattern.sh [REPO_ROOT]
#
# Exit codes:
#   0 — No violations
#   1 — One or more violations found

set -uo pipefail

# ── Resolve repo root ────────────────────────────────────────────────────────
if [[ $# -gt 0 ]]; then
    REPO_ROOT="$1"
else
    REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
fi

# ── Collect staged shell scripts under plugins/dso/ ──────────────────────────
_staged=()
while IFS= read -r _f; do
    [[ -n "$_f" ]] && _staged+=("$_f")
done < <(git diff --cached --name-only --diff-filter=ACM 2>/dev/null \
    | grep -E '^plugins/dso/.*\.sh$' || true)

if [[ ${#_staged[@]} -eq 0 ]]; then
    exit 0
fi

# ── Pattern: REPO_ROOT= ... SCRIPT_DIR/.. (with various quoting) ─────────────
# Matches:
#   REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
#   REPO_ROOT=$SCRIPT_DIR/..
#   REPO_ROOT="${SCRIPT_DIR}/.."
#   : "${REPO_ROOT:=$(cd "$SCRIPT_DIR/.." && pwd)}"
# Does NOT match a comment line (#-prefixed).
_pattern='^[[:space:]]*[^#]*REPO_ROOT[^#]*\$\{?SCRIPT_DIR\}?/\.\.'

# ── Check each staged file ───────────────────────────────────────────────────
_violations=0
_violation_details=()

for _file in "${_staged[@]}"; do
    _line_num=0
    while IFS= read -r _line; do
        (( _line_num++ )) || true
        # Skip lines that have the documented suppression marker.
        if [[ "$_line" == *"script-dir-pattern-ok"* ]]; then
            continue
        fi
        if [[ "$_line" =~ $_pattern ]]; then
            (( _violations++ )) || true
            _violation_details+=("  ${_file}:${_line_num}: ${_line}")
        fi
    done < <(git show ":${_file}" 2>/dev/null || cat "$REPO_ROOT/$_file" 2>/dev/null || true)
done

if [[ $_violations -gt 0 ]]; then
    echo "check-script-dir-pattern: BLOCKED — found REPO_ROOT=\$SCRIPT_DIR/.. anti-pattern (bug 8229):" >&2
    echo "" >&2
    for _detail in "${_violation_details[@]}"; do
        echo "$_detail" >&2
    done
    echo "" >&2
    echo "Why this is a bug:" >&2
    echo "  When the script runs on a host project via the .claude/scripts/dso shim," >&2
    echo "  SCRIPT_DIR resolves to the plugin cache, so REPO_ROOT becomes the plugin" >&2
    echo "  tree — not the host repo. Checker scripts silently PASS; mutator scripts" >&2
    echo "  edit the plugin cache (rule:no-edit-plugin-cache violation)." >&2
    echo "" >&2
    echo "Canonical fix:" >&2
    echo "  REPO_ROOT=\"\${PROJECT_ROOT:-\$(git rev-parse --show-toplevel)}\"" >&2
    echo "  if [[ -z \"\$REPO_ROOT\" ]]; then" >&2
    echo "    echo \"ERROR: cannot resolve REPO_ROOT\" >&2" >&2
    echo "    exit 1" >&2
    echo "  fi" >&2
    echo "" >&2
    echo "Suppression (plugin-internal scripts only):" >&2
    echo "  Add  # script-dir-pattern-ok: <one-sentence rationale>  on the same line." >&2
    echo "" >&2
    echo "check-script-dir-pattern: $_violations violation(s) found. Commit blocked." >&2
    exit 1
fi

exit 0
