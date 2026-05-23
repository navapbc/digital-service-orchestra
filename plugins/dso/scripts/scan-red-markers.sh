#!/usr/bin/env bash
# scan-red-markers.sh
# Scan the merged .test-index for RED markers using git merge-tree.
#
# Usage: scan-red-markers.sh <base-sha> <head-sha>
#
#   base-sha   Base commit SHA (7-40 hex chars). Branch names are rejected:
#              the caller MUST supply an explicit SHA. Never pass a branch name.
#   head-sha   Head commit SHA (7-40 hex chars).
#
# Exit codes:
#   0   No RED markers found in the merged .test-index (or .test-index absent
#       / repo objects not locatable — treated as "no markers present").
#   1   One or more RED markers found, or merge conflicts present in .test-index.
#
# Stderr: RED_MARKER: <marker_name> for <source_file>  (one line per marker)
#
# Git context:
#   Set GIT_DIR to point to the target repo's .git directory (e.g.
#   GIT_DIR=/path/to/repo/.git). Without GIT_DIR, the script first checks the
#   current working directory, then performs a TMPDIR scan to locate a git
#   repository that contains both the provided SHAs. The TMPDIR scan supports
#   test harnesses that create isolated repos in a temporary directory and invoke
#   the script from a different CWD.
#
# Positional args: BASE_SHA and HEAD_SHA ($1 and $2).
# No internal git rev-parse calls on branch names.
#
# Requires git >= 2.38 for `git merge-tree --write-tree`. Fails loud on older git.

set -euo pipefail

# ── Preflight: git version check ─────────────────────────────────────────────
# Require git >= 2.38 (merge-tree --write-tree was added in 2.38).
_git_ver=$(git --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1 || echo "0.0")
_git_major=$(echo "$_git_ver" | cut -d. -f1)
_git_minor=$(echo "$_git_ver" | cut -d. -f2)
if [[ "$_git_major" -lt 2 ]] || { [[ "$_git_major" -eq 2 ]] && [[ "$_git_minor" -lt 38 ]]; }; then
    echo "ERROR: scan-red-markers.sh requires git >= 2.38 (found: $_git_ver)" >&2
    exit 1
fi

# ── Argument validation ───────────────────────────────────────────────────────
# Positional args: $1 = BASE_SHA, $2 = HEAD_SHA.
# Both must be supplied and non-empty. Branch names should not be passed —
# do not call this script with symbolic refs like HEAD, main, or session
# branch names; supply the resolved commit SHA.
if [[ $# -lt 2 ]] || [[ -z "${1:-}" ]] || [[ -z "${2:-}" ]]; then
    echo "Usage: scan-red-markers.sh <base-sha> <head-sha>" >&2
    echo "  BASE_SHA and HEAD_SHA must be explicit commit SHAs (\$1 and \$2)." >&2
    exit 1
fi

BASE_SHA="$1"
HEAD_SHA="$2"

# Warn when args don't look like SHAs (7-40 hex chars) but continue — the
# git object lookup will fail and exit 0 (no markers found), which is correct
# behaviour when the repo cannot be located.
_sha_pattern='^[0-9a-fA-F]{7,40}$'
if ! [[ "$BASE_SHA" =~ $_sha_pattern ]] || ! [[ "$HEAD_SHA" =~ $_sha_pattern ]]; then
    echo "WARNING: base-sha '$BASE_SHA' or head-sha '$HEAD_SHA' does not look like a commit SHA." >&2
    echo "         Pass explicit SHAs, not branch names. Treating as no markers." >&2
    exit 0
fi

# ── Git context resolution ────────────────────────────────────────────────────
# Locate a git repository that contains both BASE_SHA and HEAD_SHA.
#
# Priority:
#   1. Explicit GIT_DIR env var (set by caller; highest authority).
#   2. Current working directory's git repo (normal production usage).
#   3. TMPDIR scan — search ${TMPDIR:-/tmp} for git repos containing BOTH SHAs.
#      Required for test harnesses that create isolated repos in tmpdir and invoke
#      the script from the main repo root. We check for BOTH SHAs to avoid false
#      matches: test repos may share identical base-commit SHAs when committed
#      within the same timestamp window, but their head SHAs differ.

_find_git_dir_for_shas() {
    local base_sha="$1" head_sha="$2"

    # 1. Explicit GIT_DIR.
    if [[ -n "${GIT_DIR:-}" ]]; then
        if GIT_DIR="$GIT_DIR" git cat-file -t "$base_sha" >/dev/null 2>&1; then
            echo "$GIT_DIR"
            return 0
        fi
        # GIT_DIR set but SHA not found — do NOT fall through (caller misconfiguration).
        echo "ERROR: GIT_DIR=$GIT_DIR does not contain SHA $base_sha" >&2
        return 1
    fi

    # 2. Current working directory.
    if git cat-file -t "$base_sha" >/dev/null 2>&1 && \
       git cat-file -t "$head_sha" >/dev/null 2>&1; then
        echo ""  # Empty → no GIT_DIR override needed.
        return 0
    fi

    # 3. TMPDIR scan: find a repo containing BOTH SHAs.
    local _tmpdir="${TMPDIR:-/tmp}"
    _tmpdir="${_tmpdir%/}"  # strip trailing slash
    local _gdir
    while IFS= read -r _gdir; do
        if GIT_DIR="$_gdir" git cat-file -t "$base_sha" >/dev/null 2>&1 && \
           GIT_DIR="$_gdir" git cat-file -t "$head_sha" >/dev/null 2>&1; then
            echo "$_gdir"
            return 0
        fi
    done < <(find "$_tmpdir" -maxdepth 3 -name '.git' -type d 2>/dev/null | sort)

    # No repo found — treat as "no .test-index accessible" → no markers.
    return 2  # Distinct code so caller can exit 0 cleanly.
}

_effective_git_dir=""
_find_result=0
_effective_git_dir=$(_find_git_dir_for_shas "$BASE_SHA" "$HEAD_SHA") || _find_result=$?

if [[ "$_find_result" -eq 2 ]]; then
    # Repo not found — cannot determine markers. Treat as clean (no markers).
    exit 0
elif [[ "$_find_result" -ne 0 ]]; then
    exit 1
fi

# Helper: run a git command with the resolved GIT_DIR (if any).
_git() {
    if [[ -n "$_effective_git_dir" ]]; then
        GIT_DIR="$_effective_git_dir" git "$@"
    else
        git "$@"
    fi
}

# ── Compute merged tree ───────────────────────────────────────────────────────
# git merge-tree --write-tree emits a tree SHA on stdout representing the
# result of merging HEAD_SHA onto BASE_SHA without touching the working tree.
_tree=""
_tree=$(_git merge-tree --write-tree "$BASE_SHA" "$HEAD_SHA" 2>/dev/null | head -1 || true)

if [[ -z "$_tree" ]]; then
    # merge-tree failed — cannot determine markers. Treat as clean.
    exit 0
fi

# ── Read merged .test-index content ──────────────────────────────────────────
_content=""
_content=$(_git show "${_tree}:.test-index" 2>/dev/null || true)

# Missing .test-index in merged tree → no markers, clean exit.
if [[ -z "$_content" ]]; then
    exit 0
fi

# ── Conflict marker check ─────────────────────────────────────────────────────
# If the merged .test-index contains git conflict markers, we cannot safely parse it.
if echo "$_content" | grep -qE '^(<{7}|={7}|>{7})'; then
    echo "ERROR: cannot scan .test-index: merge conflicts present" >&2
    exit 1
fi

# ── Parse markers from a .test-index content string ──────────────────────────
# Reads .test-index content from $1 (string). Emits one line per marker on
# stdout: "<source_file><TAB><marker_name>". WARNINGs for malformed lines go
# to stderr.
#
# Grammar (canonical source: bash-runner.sh _RED_MARKER_MAP):
#   source_file: test_file1 [marker_name], test_file2 [other_marker], test_file3
#
# Rules:
#   - Blank lines → skip.
#   - Lines starting with '#' → skip (comments).
#   - Lines without ':' separator → warn to stderr, continue (malformed).
#   - Right-hand side is comma-separated; each part may have a trailing [marker_name].
#   - Marker regex: ^(.*[^[:space:]])[[:space:]]+\[([^]]+)\]$
#     (identical to bash-runner.sh _RED_MARKER_MAP detection).
_parse_markers() {
    local _content="$1"
    local _line _left _right _part _pmarker _local_IFS

    while IFS= read -r _line || [[ -n "$_line" ]]; do
        # Skip blank lines.
        [[ -z "$_line" ]] && continue

        # Skip comment lines (leading '#', possibly with whitespace).
        [[ "$_line" =~ ^[[:space:]]*# ]] && continue

        # Require a colon separator. Warn on malformed lines but continue.
        if ! [[ "$_line" =~ : ]]; then
            echo "WARNING: malformed .test-index line (no ':' separator): $_line" >&2
            continue
        fi

        _left="${_line%%:*}"
        _right="${_line#*:}"

        # Trim leading/trailing whitespace from source file path.
        _left="${_left#"${_left%%[![:space:]]*}"}"
        _left="${_left%"${_left##*[![:space:]]}"}"

        # Split right side on commas; inspect each part for a [marker_name] suffix.
        _local_IFS="$IFS"
        IFS=','
        # shellcheck disable=SC2086
        set -- $_right
        IFS="$_local_IFS"

        for _part in "$@"; do
            # Trim leading/trailing whitespace.
            _part="${_part#"${_part%%[![:space:]]*}"}"
            _part="${_part%"${_part##*[![:space:]]}"}"

            [[ -z "$_part" ]] && continue

            # Detect marker: "test_file_path [marker_name]"
            if [[ "$_part" =~ ^(.*[^[:space:]])[[:space:]]+\[([^]]+)\]$ ]]; then
                _pmarker="${BASH_REMATCH[2]}"
                printf '%s\t%s\n' "$_left" "$_pmarker"
            fi
        done
    done <<< "$_content"
}

# ── Delta-mode: emit RED_MARKER and exit 1 only for NEW markers ──────────────
# DESIGN DECISION (bug 535a-9d42-cb16-445c):
#
# Previous behavior ("all-or-nothing"): exit 1 if ANY `[marker]` appears in the
# merged tree's .test-index. This blocked every PR to main once main accumulated
# pre-existing markers, because the merged tree always contained them.
#
# Current behavior ("delta-mode"): exit 1 ONLY when HEAD introduces a marker
# that was NOT present in BASE_SHA's .test-index. Pre-existing markers already
# on main are treated as intentional RED tolerances accepted in prior PRs —
# the gate must not penalize new PRs for accepting their merged-tree presence.
# Re-introduction of a marker that BASE removed (sub-PR 1 removes, sub-PR 2
# re-adds against the new BASE) is correctly detected as new vs the post-
# removal BASE; see tests/workflows/test-red-test-blocker-merged-tree-scan.sh
# Test 1.
#
# Implementation: parse BASE and HEAD .test-index into source<TAB>marker sets,
# `comm -23` head_set base_set yields the new-marker delta. Emit RED_MARKER
# lines and exit 1 only when the delta is non-empty. Existing exit-0 fall-
# throughs (missing .test-index, merge-tree failure, conflict markers) are
# preserved.
_head_tmp=$(mktemp /tmp/scan-red-head.XXXXXX)
_base_tmp=$(mktemp /tmp/scan-red-base.XXXXXX)
trap 'rm -f "$_head_tmp" "$_base_tmp"' EXIT

_parse_markers "$_content" | sort -u > "$_head_tmp"

# BASE_SHA:.test-index — missing/empty → empty baseline set (any HEAD marker is new).
_base_content=$(_git show "${BASE_SHA}:.test-index" 2>/dev/null || true)
if [[ -n "$_base_content" ]]; then
    _parse_markers "$_base_content" | sort -u > "$_base_tmp"
fi

# comm -23: lines in head_tmp but not in base_tmp. Both inputs must be sorted.
_new_markers=$(comm -23 "$_head_tmp" "$_base_tmp")

if [[ -n "$_new_markers" ]]; then
    while IFS=$'\t' read -r _src _mk; do
        [[ -z "$_src" ]] && continue
        echo "RED_MARKER: $_mk for $_src" >&2
    done <<< "$_new_markers"
    exit 1
fi
exit 0
