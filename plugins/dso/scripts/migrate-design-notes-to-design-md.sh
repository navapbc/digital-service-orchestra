#!/usr/bin/env bash
# migrate-design-notes-to-design-md.sh
# One-time migration: converts .claude/design-notes.md into a spec-compliant DESIGN.md
# with YAML front-matter, then replaces design-notes.md with a deprecation tombstone.
#
# Usage:
#   migrate-design-notes-to-design-md.sh [--target <host-project-root>]
#
# Flags:
#   --target <path>     Path to the host project root (default: git rev-parse --show-toplevel)
#
# Exit codes:
#   0 — Success (including greenfield guard, idempotent re-run)
#   1 — Fatal error

set -euo pipefail

# ── Self-location ────────────────────────────────────────────────────────────
_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Parse arguments ──────────────────────────────────────────────────────────
_TARGET=""

while [ $# -gt 0 ]; do
    case "$1" in
        --target)
            _TARGET="$2"
            shift 2
            ;;
        --target=*)
            _TARGET="${1#--target=}"
            shift
            ;;
        *)
            echo "Error: unknown argument '$1'" >&2
            exit 1
            ;;
    esac
done

# Resolve target (default: git rev-parse --show-toplevel from within script context)
if [ -z "$_TARGET" ]; then
    _TARGET="$(git rev-parse --show-toplevel)"
fi

# ── Greenfield guard ─────────────────────────────────────────────────────────
# If .claude/design-notes.md does not exist, this is a greenfield project.
# Do NOT create a hollow DESIGN.md that would confuse the linter.
_DESIGN_NOTES="$_TARGET/.claude/design-notes.md"
if [ ! -f "$_DESIGN_NOTES" ]; then
    exit 0
fi

# ── Migration marker (idempotency) ───────────────────────────────────────────
_MARKER="<!-- dso-migrate-design-notes-to-design-md:v1 -->"
if grep -qF "$_MARKER" "$_DESIGN_NOTES" 2>/dev/null; then
    exit 0
fi

# ── Read design-notes.md ─────────────────────────────────────────────────────
_content="$(cat "$_DESIGN_NOTES")"

# ── Extract design system name ────────────────────────────────────────────────
# Look for a top-level heading (# ...) or a "Design System:" / "System:" label
_name=""
_name=$(printf '%s\n' "$_content" | awk '
    /^# / && NR == 1 { sub(/^# /, ""); print; exit }
    /^# / { sub(/^# /, ""); print; exit }
' 2>/dev/null || true)

if [ -z "$_name" ]; then
    _name="Design System"
fi

# ── Section extraction helper ─────────────────────────────────────────────────
# Extract content under a heading (## Heading) until the next ## heading
_extract_section() {
    local content="$1"
    local heading="$2"
    printf '%s\n' "$content" | awk -v h="## $heading" '
        found && /^## / { exit }
        found { print }
        $0 == h { found=1 }
    '
}

# ── Map sections ──────────────────────────────────────────────────────────────
# Mapping rules from task spec:
#   Vision / User Archetypes / Visual Language → ## Overview
#   Anti-Patterns → ## Dos and Donts
#   Others → custom sections (preserve as-is)

_overview_sections=("Vision" "User Archetypes" "Visual Language")
_dos_donts_sections=("Anti-Patterns")

# Collect all ## headings from the source
_all_headings=()
while IFS= read -r _line; do
    if [[ "$_line" =~ ^##[[:space:]](.+)$ ]]; then
        _all_headings+=("${BASH_REMATCH[1]}")
    fi
done < "$_DESIGN_NOTES"

# ── Build DESIGN.md content ───────────────────────────────────────────────────
_output=""

# YAML front-matter
_output+="---"$'\n'
_output+="name: ${_name}"$'\n'
_output+="---"$'\n'
_output+=$'\n'

# Build Overview section from mapped headings
_overview_content=""
for _sec in "${_overview_sections[@]}"; do
    _sec_content="$(_extract_section "$_content" "$_sec")"
    if [ -n "$_sec_content" ]; then
        if [ -n "$_overview_content" ]; then
            _overview_content+=$'\n'
        fi
        _overview_content+="### ${_sec}"$'\n'
        _overview_content+="$_sec_content"
    fi
done

if [ -n "$_overview_content" ]; then
    _output+="## Overview"$'\n'
    _output+="$_overview_content"
    _output+=$'\n'
fi

# Build Dos and Donts section from Anti-Patterns
_dos_donts_content=""
for _sec in "${_dos_donts_sections[@]}"; do
    _sec_content="$(_extract_section "$_content" "$_sec")"
    if [ -n "$_sec_content" ]; then
        _dos_donts_content+="$_sec_content"
    fi
done

if [ -n "$_dos_donts_content" ]; then
    _output+="## Dos and Donts"$'\n'
    _output+="$_dos_donts_content"
    _output+=$'\n'
fi

# Passthrough: all other sections not in the mapped lists
_mapped_headings=("${_overview_sections[@]}" "${_dos_donts_sections[@]}")
for _heading in "${_all_headings[@]}"; do
    _is_mapped=0
    for _mapped in "${_mapped_headings[@]}"; do
        if [ "$_heading" = "$_mapped" ]; then
            _is_mapped=1
            break
        fi
    done
    if [ "$_is_mapped" = "0" ]; then
        _sec_content="$(_extract_section "$_content" "$_heading")"
        _output+="## ${_heading}"$'\n'
        if [ -n "$_sec_content" ]; then
            _output+="$_sec_content"
        fi
        _output+=$'\n'
    fi
done

# ── Write DESIGN.md ───────────────────────────────────────────────────────────
printf '%s' "$_output" > "$_TARGET/DESIGN.md"

# ── Replace design-notes.md with deprecation tombstone ───────────────────────
cat > "$_DESIGN_NOTES" <<EOF
<!-- dso-migrate-design-notes-to-design-md:v1 -->
# DEPRECATED

This file has been migrated to DESIGN.md at the project root.

Migration performed by: migrate-design-notes-to-design-md.sh

See DESIGN.md for the current design system specification.
EOF

exit 0
