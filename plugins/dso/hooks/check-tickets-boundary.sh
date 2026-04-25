#!/usr/bin/env bash
# hook-boundary: enforcement
# check-tickets-boundary.sh
# Pre-commit hook: enforce the tickets boundary.
#
# Blocks commits where non-allowlisted files reference:
#   Pattern A: .tickets-tracker/  (direct tracker access)
#   Pattern B: sprint-next-batch.sh, sprint-list-epics.sh,
#              purge-non-project-tickets.sh  (absorbed scripts)
#
# Suppression: append '# tickets-boundary-ok' to the offending line.
# Allowlist:   .claude/hooks/pre-commit/check-tickets-boundary-allowlist.conf
#              (or override via TICKETS_BOUNDARY_ALLOWLIST env var)
#
# Path exclusions (always exempt, regardless of allowlist):
#   $plugin_git_path/docs/*   — structural docs describing architecture
#   docs/adr/*                — historical ADR records
#
# Exit codes:
#   0 — no violations (or allowlisted / suppressed)
#   1 — one or more violations found

set -uo pipefail

# ── Resolve repo root and plugin path ────────────────────────────────────────
# _PLUGIN_ROOT / _PLUGIN_GIT_PATH: always BASH_SOURCE-based (correct for exclusion prefix).
# _REAL_REPO_ROOT: prefer BASH_SOURCE-based (avoids CWD confusion in test repos), then
#   fall back to CWD-based git rev-parse (reliable in git hook / worktree contexts).
_HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_PLUGIN_ROOT="$(cd "$_HOOK_DIR/.." && pwd)"
# shellcheck disable=SC2295  # inner $(…) in pattern expansion — safe here
_PLUGIN_GIT_PATH="${_PLUGIN_ROOT#$(cd "$_PLUGIN_ROOT" && git rev-parse --show-toplevel)/}"
_REAL_REPO_ROOT_FROM_PLUGIN="$(cd "$_PLUGIN_ROOT" && git rev-parse --show-toplevel 2>/dev/null || echo "")"
_REAL_REPO_ROOT_FROM_CWD="$(git rev-parse --show-toplevel 2>/dev/null || echo "")"
# Use plugin-based root when the allowlist exists there (normal and worktree sessions).
# Fall back to CWD-based root (test repo invocations where hook is called from outside).
_ALLOWLIST_DEFAULT="${_REAL_REPO_ROOT_FROM_PLUGIN}/.claude/hooks/pre-commit/check-tickets-boundary-allowlist.conf"
if [[ ! -f "$_ALLOWLIST_DEFAULT" && -n "$_REAL_REPO_ROOT_FROM_CWD" ]]; then
    _REAL_REPO_ROOT="$_REAL_REPO_ROOT_FROM_CWD"
else
    _REAL_REPO_ROOT="$_REAL_REPO_ROOT_FROM_PLUGIN"
fi

# ── Resolve allowlist ────────────────────────────────────────────────────────
if [[ -n "${TICKETS_BOUNDARY_ALLOWLIST:-}" ]]; then
    _ALLOWLIST="$TICKETS_BOUNDARY_ALLOWLIST"
else
    _ALLOWLIST="$_REAL_REPO_ROOT/.claude/hooks/pre-commit/check-tickets-boundary-allowlist.conf"
fi

# ── Path-scoped exclusion prefixes (always exempt) ───────────────────────────
_PATH_EXCLUSION_PREFIXES=(
    "${_PLUGIN_GIT_PATH}/docs/"
    "docs/adr/"
)

# ── Violation patterns and their CLI replacements ────────────────────────────
# Each entry: "pattern|display_name|replacement"
_PATTERNS=(
    ".tickets-tracker/|direct .tickets-tracker/ access|.claude/scripts/dso ticket list"
    "sprint-next-batch.sh|sprint-next-batch.sh|.claude/scripts/dso ticket next-batch"
    "sprint-list-epics.sh|sprint-list-epics.sh|.claude/scripts/dso ticket list-epics"
    "purge-non-project-tickets.sh|purge-non-project-tickets.sh|.claude/scripts/dso ticket purge"
)

# ── Read allowlist patterns ──────────────────────────────────────────────────
_allowlist_patterns=()
if [[ -f "$_ALLOWLIST" && -r "$_ALLOWLIST" ]]; then
    while IFS= read -r _line; do
        [[ -z "$_line" ]] && continue
        [[ "$_line" == \#* ]] && continue
        _allowlist_patterns+=("$_line")
    done < "$_ALLOWLIST"
fi

# ── Helper: match a file path against allowlist patterns ─────────────────────
# Uses bash glob (case/extglob) via a subshell. Returns 0 if matched.
_is_allowlisted() {
    local _path="$1"
    local _pat
    for _pat in "${_allowlist_patterns[@]}"; do
        # Use [[ == ]] for glob pattern matching (unquoted RHS enables glob).
        # shellcheck disable=SC2254  # SC2254 does not apply here — [[ == ]] used, not case
        # shellcheck disable=SC2053  # glob matching intentional: $_pat unquoted on RHS of ==
        if [[ "$_path" == $_pat ]]; then
            return 0
        fi
    done
    return 1
}

# ── Helper: check if a file path is path-scoped exempt ───────────────────────
_is_path_excluded() {
    local _path="$1"
    local _prefix
    for _prefix in "${_PATH_EXCLUSION_PREFIXES[@]}"; do
        if [[ "$_path" == "$_prefix"* ]]; then
            return 0
        fi
    done
    return 1
}

# ── Collect staged files ──────────────────────────────────────────────────────
_staged_files=()
while IFS= read -r _f; do
    [[ -n "$_f" ]] && _staged_files+=("$_f")
done < <(git diff --cached --name-only 2>/dev/null || true)

if [[ ${#_staged_files[@]} -eq 0 ]]; then
    exit 0
fi

# ── Scan each staged file for violations ─────────────────────────────────────
_found_violation=0

for _file in "${_staged_files[@]}"; do
    # Path-scoped exclusion check (always exempt)
    if _is_path_excluded "$_file"; then
        continue
    fi

    # Allowlist check
    if _is_allowlisted "$_file"; then
        continue
    fi

    # Scan staged content line by line
    while IFS= read -r _line; do
        # Suppression annotation: skip lines with # tickets-boundary-ok
        case "$_line" in
            *'# tickets-boundary-ok'*) continue ;;
        esac

        # Check each violation pattern
        for _entry in "${_PATTERNS[@]}"; do
            IFS='|' read -r _pattern _display _replacement <<< "$_entry"
            case "$_line" in
                *"$_pattern"*)
                    echo "ERROR: Disallowed reference in ${_file}: '${_display}'" >&2
                    echo "  Use '${_replacement}' instead." >&2
                    echo "  To suppress: add '# tickets-boundary-ok' to the line." >&2
                    _found_violation=1
                    ;;
            esac
        done
    done < <(git show ":${_file}" 2>/dev/null || true)
done

if [[ $_found_violation -ne 0 ]]; then
    exit 1
fi

exit 0
