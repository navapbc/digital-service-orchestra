#!/usr/bin/env bash
# scripts/check-rule-anchors.sh
# Validate CLAUDE.md rule anchors (R13 of project-audit-2026-05-19).
#
# Mechanism: CLAUDE.md numbers its Never / Architectural Invariants / Always Do
# rules. Other docs and scripts cite those rules by number ("rule #15") — a
# pattern that silently rots when CLAUDE.md is renumbered. To stabilize citations,
# every rule now carries an HTML-comment anchor of the form
#   <!-- rule:<slug> --> | <!-- invariant:<slug> --> | <!-- always:<slug> -->
# inline on its opener. Other in-scope files cite by anchor name
# (e.g., "CLAUDE.md `rule:fabrication`") instead of by ordinal.
#
# This script:
#   1. Builds the set of anchors defined in CLAUDE.md.
#   2. Builds the set of anchors cited across in-scope files.
#   3. Reports each cited anchor that has no matching definition (BROKEN citation).
#   4. Optionally reports each defined anchor with zero citations (DEAD anchor;
#      warning only — not all rules need to be cited externally).
#
# Usage:
#   scripts/check-rule-anchors.sh [file|dir ...]
#
# When no arguments are given, scans the default in-scope file set:
#   CLAUDE.md plus the plugin's skills/, docs/, hooks/, agents/, scripts/, and commands/
#   subdirectories (resolved from this script's location, two levels up).
#
# Exit codes:
#   0 — No broken citations found
#   1 — One or more broken citations found
#   2 — CLAUDE.md missing or unreadable (cannot build the defined set)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Plugin root = one level up from scripts/ (canonical script-relative resolution).
# REPO_ROOT = three levels up from scripts/ (REPO/<plugin>/scripts -> REPO).
# CLAUDE_PLUGIN_ROOT is intentionally NOT consulted here: when set in an interactive
# session it typically points at the host project's plugin cache (e.g.,
# ~/.claude/plugins/...) or a sibling main repo, which would cause the pre-commit hook
# to scan the wrong tree and silently fail to detect broken citations in the worktree's
# current changes (R13 follow-up — important finding from PR-D reviewer pass).
_PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
CLAUDE_MD="$REPO_ROOT/CLAUDE.md"

# Anchor pattern: <!-- (rule|invariant|always):<slug> -->
# Slug allows lowercase letters, digits, hyphens, colons (intra-slug separators are unused today
# but reserved for forward-compat; the colon between prefix and slug is fixed).
_ANCHOR_PREFIX_RE='rule|invariant|always'
_ANCHOR_DEF_RE="<!-- (${_ANCHOR_PREFIX_RE}):[a-z0-9-]+ -->"

# Citation pattern: backtick-wrapped `<prefix>:<slug>` (the documented convention).
# Backticks are required to avoid false positives from prose / structured-output field
# strings like "file:line:rule:message" that incidentally match the prefix:slug shape.
# When citing in non-Markdown contexts (shell comments, etc.) the backticks are still
# required — they make the citation grep-stable and parser-discoverable.
_CITE_RE='`('"${_ANCHOR_PREFIX_RE}"'):[a-z0-9-]+`'

# ── Build defined set ─────────────────────────────────────────────────────────

if [[ ! -f "$CLAUDE_MD" ]]; then
    echo "check-rule-anchors: CLAUDE.md not found at $CLAUDE_MD" >&2
    exit 2
fi

_defined_file=$(mktemp /tmp/check-rule-anchors-defined.XXXXXX)
# shellcheck disable=SC2154
# _rc is assigned inside the trap body itself (the single-quoted string is evaluated by
# bash when the trap fires, not at parse time). SC2154 cannot see that assignment.
trap '_rc=$?; rm -f "$_defined_file" "${_cited_file:-}" "${_cited_locations:-}" "${_broken_file:-}" "${_dead_file:-}"; exit $_rc' EXIT

grep -oE "$_ANCHOR_DEF_RE" "$CLAUDE_MD" \
    | sed -E 's|<!-- ||; s| -->||' \
    | sort -u > "$_defined_file"

_defined_count=$(wc -l < "$_defined_file" | tr -d ' ')
if [[ "$_defined_count" -eq 0 ]]; then
    echo "check-rule-anchors: FATAL: no anchors defined in CLAUDE.md — refusing to run with empty defined set" >&2
    exit 2
fi

# ── Determine scan targets ────────────────────────────────────────────────────

_scan_targets=()
if [[ $# -gt 0 ]]; then
    _scan_targets=("$@")
else
    _scan_targets+=("$CLAUDE_MD")
    for _dir in skills docs hooks agents scripts commands; do
        if [[ -d "$_PLUGIN_ROOT/$_dir" ]]; then
            _scan_targets+=("$_PLUGIN_ROOT/$_dir")
        fi
    done
fi

# ── Build cited set ───────────────────────────────────────────────────────────

_cited_file=$(mktemp /tmp/check-rule-anchors-cited.XXXXXX)

# Track each citation with file:line for broken-citation reporting.
_cited_locations=$(mktemp /tmp/check-rule-anchors-cited-locations.XXXXXX)

# Single-pass grep across all scan targets (one fork instead of one-per-file).
# The citation regex requires backticks (`prefix:slug`); anchor definitions use
# HTML comments (<!-- prefix:slug -->), so the two surface forms never collide —
# no anchor-strip pass needed.
_grep_args=(-rEonH
    "--include=*.md"
    "--include=*.sh"
    "--include=*.py"
    "--include=*.yaml"
    "--include=*.yml"
    "--exclude-dir=node_modules"
    "--exclude-dir=.git")

_raw_matches=$(grep "${_grep_args[@]}" -- "$_CITE_RE" "${_scan_targets[@]}" 2>/dev/null || true)

if [[ -n "$_raw_matches" ]]; then
    while IFS=: read -r _f _line _match; do
        # _match is the backticked citation, e.g., `rule:fabrication`
        # Strip leading and trailing backticks to recover the bare prefix:slug
        _slug="${_match//\`/}"
        printf '%s\n' "$_slug" >> "$_cited_file"
        printf '%s\t%s:%s\n' "$_slug" "$_f" "$_line" >> "$_cited_locations"
    done <<< "$_raw_matches"
fi

# De-duplicate the cited set
if [[ -s "$_cited_file" ]]; then
    sort -u "$_cited_file" -o "$_cited_file"
fi

# ── Compute broken citations ──────────────────────────────────────────────────

_broken_file=$(mktemp /tmp/check-rule-anchors-broken.XXXXXX)
comm -23 "$_cited_file" "$_defined_file" > "$_broken_file"
_broken_count=$(wc -l < "$_broken_file" | tr -d ' ')

if [[ "$_broken_count" -gt 0 ]]; then
    echo "check-rule-anchors: $_broken_count broken citation(s) found:" >&2
    while IFS= read -r _slug; do
        echo "" >&2
        echo "  BROKEN: '$_slug' is cited but not defined in CLAUDE.md" >&2
        # Show first 3 citation locations
        grep -F "$(printf '%s\t' "$_slug")" "$_cited_locations" | head -3 | while IFS=$'\t' read -r _s _loc; do
            echo "    at $_loc" >&2
        done
    done < "$_broken_file"
    echo "" >&2
    echo "  Hint: Add the anchor to CLAUDE.md (e.g., '<!-- $(head -1 "$_broken_file") -->' on the relevant rule)" >&2
    echo "  or correct the citation to match an existing anchor." >&2
    exit 1
fi

# ── Dead-anchor warning (non-fatal) ───────────────────────────────────────────

_dead_file=$(mktemp /tmp/check-rule-anchors-dead.XXXXXX)
comm -23 "$_defined_file" "$_cited_file" > "$_dead_file"
_dead_count=$(wc -l < "$_dead_file" | tr -d ' ')

if [[ "$_dead_count" -gt 0 && "${DSO_RULE_ANCHORS_WARN_DEAD:-0}" == "1" ]]; then
    echo "check-rule-anchors: $_dead_count defined anchor(s) have zero citations (warning only):" >&2
    head -10 "$_dead_file" | while IFS= read -r _slug; do
        echo "    $_slug" >&2
    done
fi

rm -f "$_dead_file"
exit 0
