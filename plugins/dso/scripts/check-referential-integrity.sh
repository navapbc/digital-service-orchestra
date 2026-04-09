#!/usr/bin/env bash
# plugins/dso/scripts/check-referential-integrity.sh
# Verify that path references in skill/agent/workflow/prompt markdown files
# point to files that actually exist in the repository.
#
# Scanned pattern: plugins/dso/(scripts|agents|docs)/[^\s]+\.(sh|py|md)
#
# Exclusions:
#   - Lines containing # shim-exempt: (case-insensitive)
#   - Paths inside triple-backtick fenced code blocks
#
# Existence check:
#   1. File exists on disk relative to REPO_ROOT, OR
#   2. File appears in git ls-files --cached (in-flight renames)
#
# Usage:
#   check-referential-integrity.sh [--repo-root <path>] [file ...]
#
# When no file arguments are given, scans the default in-scope set:
#   plugins/dso/{skills,agents,docs/workflows,docs/prompts}/**/*.md + CLAUDE.md
#
# Exit codes:
#   0 — All referenced files exist
#   1 — One or more referenced files are missing

set -uo pipefail

# ── Parse arguments ──────────────────────────────────────────────────────────
REPO_ROOT=""
_file_args=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --repo-root)
            REPO_ROOT="$2"
            shift 2
            ;;
        *)
            _file_args+=("$1")
            shift
            ;;
    esac
done

# Default REPO_ROOT: derive from git repo root
if [[ -z "$REPO_ROOT" ]]; then
    REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || true
    if [[ -z "$REPO_ROOT" ]]; then
        echo "check-referential-integrity: not in a git repository and --repo-root not provided" >&2
        exit 0
    fi
fi

PLUGIN_DIR="$REPO_ROOT/plugins/dso"

# ── Temp files for intermediate data ─────────────────────────────────────────
_git_cache_file=$(mktemp)
_refs_file=$(mktemp)
_cleanup() {
    rm -f "$_git_cache_file" "$_refs_file"
}
trap '_cleanup' EXIT

# ── Build git cached file list for in-flight rename support ──────────────────
if command -v git >/dev/null 2>&1; then
    (cd "$REPO_ROOT" && git ls-files --cached 2>/dev/null) > "$_git_cache_file" || true
fi

# ── Determine scan targets ───────────────────────────────────────────────────
_scan_targets=()

if [[ ${#_file_args[@]} -gt 0 ]]; then
    _scan_targets=("${_file_args[@]}")
else
    # Default scan: plugins/dso/{skills,agents,docs/workflows,docs/prompts}/**/*.md + CLAUDE.md
    for _dir in skills agents docs/workflows docs/prompts; do
        if [[ -d "$PLUGIN_DIR/$_dir" ]]; then
            while IFS= read -r -d '' _f; do
                _scan_targets+=("$_f")
            done < <(find -P "$PLUGIN_DIR/$_dir" -type f -name '*.md' -print0 2>/dev/null)
        fi
    done
    # Also scan CLAUDE.md at repo root
    if [[ -f "$REPO_ROOT/CLAUDE.md" ]]; then
        _scan_targets+=("$REPO_ROOT/CLAUDE.md")
    fi
fi

if [[ ${#_scan_targets[@]} -eq 0 ]]; then
    echo "check-referential-integrity: no files to scan" >&2
    exit 0
fi

# ── Reference pattern ────────────────────────────────────────────────────────
# Matches: plugins/dso/(scripts|agents|docs)/...(sh|py|md)
_REF_PATTERN='plugins/dso/(scripts|agents|docs)/[^[:space:]`,)>"|'"'"']+\.(sh|py|md)'

# ── Scan (optimized: awk does all filtering + reference extraction) ──────────
#
# Single awk pass over all files:
#   1. Tracks code fence state per file
#   2. Skips shim-exempt lines
#   3. Extracts path references matching the pattern
#   4. Outputs file:linenum:ref for each reference found
#
# This eliminates all per-line subprocess spawning.

awk -v ref_pat="$_REF_PATTERN" '
    FILENAME != _prev_file {
        _in_fence = 0
        _prev_file = FILENAME
    }
    /^```/ {
        _in_fence = !_in_fence
        next
    }
    _in_fence { next }
    {
        lower = tolower($0)
        if (index(lower, "# shim-exempt:") > 0) next

        line = $0
        # Extract all matching references from this line
        while (match(line, ref_pat)) {
            ref = substr(line, RSTART, RLENGTH)
            # Strip trailing punctuation that the pattern may have included
            while (ref ~ /[.,)]$/) {
                ref = substr(ref, 1, length(ref) - 1)
            }
            # Skip glob patterns — they are prose references, not concrete paths
            if (index(ref, "*") > 0 || index(ref, "?") > 0) {
                line = substr(line, RSTART + RLENGTH)
                continue
            }
            print FILENAME "\t" FNR "\t" ref
            line = substr(line, RSTART + RLENGTH)
        }
    }
' "${_scan_targets[@]}" > "$_refs_file" 2>/dev/null || true

# If no references found at all, exit clean
if [[ ! -s "$_refs_file" ]]; then
    exit 0
fi

# ── Check existence of each extracted reference ──────────────────────────────
_missing=0

while IFS=$'\t' read -r _file _linenum _ref; do
    [[ -z "$_ref" ]] && continue

    # Check filesystem
    if [[ -e "$REPO_ROOT/$_ref" ]]; then
        continue
    fi
    # Check git staged files (temp file, no subprocess per check)
    if [[ -s "$_git_cache_file" ]]; then
        if grep -qxF "$_ref" "$_git_cache_file"; then
            continue
        fi
    fi

    echo "MISSING: $_file:$_linenum: $_ref" >&2
    (( _missing++ )) || true
done < "$_refs_file"

# ── Result ───────────────────────────────────────────────────────────────────
if [[ $_missing -gt 0 ]]; then
    echo "check-referential-integrity: $_missing missing reference(s) found." >&2
    exit 1
fi

exit 0
