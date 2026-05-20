#!/usr/bin/env bash
# shellcheck disable=SC2016
# Rationale: this script uses single-quoted regex patterns containing literal
# backticks (e.g., `'`dso:[a-z][a-z0-9-]*`'`) to match AGENTS.md citation form.
# Backticks are literal characters in the regex, not command-substitution markers.
#
# scripts/check-agents-doc.sh
# Validate AGENTS.md stays in sync with the filesystem (R9 / R21 follow-up).
#
# Mechanism: every agent file under the plugin's agents/ directory should be
# documented in ${CLAUDE_PLUGIN_ROOT}/docs/AGENTS.md, and every agent name
# referenced in AGENTS.md should resolve to a real file. Drift between the two
# surfaces is what the project audit (2026-05-19) found in R9.
#
# This script:
#   1. Builds the set of agent identifiers from `agents/*.md` (basename minus `.md`).
#   2. Builds the set of agent identifiers documented in AGENTS.md (extracted
#      from `` `dso:<name>` `` references in table rows).
#   3. Reports each file-only agent (file exists, not documented) and each
#      doc-only agent (documented, no file).
#   4. Fails loudly when either set has gaps; emits a fix hint.
#
# Usage:
#   scripts/check-agents-doc.sh
#
# Exit codes:
#   0 — Documentation is in sync with the filesystem
#   1 — One or more drift entries (file-only or doc-only)
#   2 — Required input missing (agents/ dir or AGENTS.md)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
AGENTS_DIR="$_PLUGIN_ROOT/agents"
AGENTS_MD="$_PLUGIN_ROOT/docs/AGENTS.md"

if [[ ! -d "$AGENTS_DIR" ]]; then
    echo "check-agents-doc: FATAL: agents/ dir not found at $AGENTS_DIR" >&2
    exit 2
fi
if [[ ! -f "$AGENTS_MD" ]]; then
    echo "check-agents-doc: FATAL: AGENTS.md not found at $AGENTS_MD" >&2
    exit 2
fi

# ── Build filesystem set ──────────────────────────────────────────────────────

_fs_file=$(mktemp /tmp/check-agents-doc-fs.XXXXXX)
_doc_file=$(mktemp /tmp/check-agents-doc-doc.XXXXXX)
_file_only=$(mktemp /tmp/check-agents-doc-file-only.XXXXXX)
_doc_only=$(mktemp /tmp/check-agents-doc-doc-only.XXXXXX)

# shellcheck disable=SC2154
trap '_rc=$?; rm -f "$_fs_file" "$_doc_file" "$_file_only" "$_doc_only"; exit $_rc' EXIT

find "$AGENTS_DIR" -maxdepth 1 -name '*.md' -type f \
    -exec basename {} .md \; \
    | sort -u > "$_fs_file"

if [[ ! -s "$_fs_file" ]]; then
    echo "check-agents-doc: FATAL: no agent files found under $AGENTS_DIR — refusing to run with empty filesystem set" >&2
    exit 2
fi

# ── Build documented set ──────────────────────────────────────────────────────
# AGENTS.md references each agent via `dso:<name>` (backticks). Extract <name>.

grep -oE '`dso:[a-z][a-z0-9-]*`' "$AGENTS_MD" \
    | sed -E 's|`dso:||; s|`||' \
    | sort -u > "$_doc_file"

if [[ ! -s "$_doc_file" ]]; then
    echo "check-agents-doc: FATAL: no documented agents found in $AGENTS_MD — refusing to run with empty documented set" >&2
    exit 2
fi

# ── Compute drift ─────────────────────────────────────────────────────────────

comm -23 "$_fs_file" "$_doc_file" > "$_file_only"
comm -13 "$_fs_file" "$_doc_file" > "$_doc_only"

_file_only_count=$(wc -l < "$_file_only" | tr -d ' ')
_doc_only_count=$(wc -l < "$_doc_only" | tr -d ' ')

if [[ "$_file_only_count" -eq 0 && "$_doc_only_count" -eq 0 ]]; then
    exit 0
fi

echo "check-agents-doc: AGENTS.md is out of sync with $AGENTS_DIR" >&2

if [[ "$_file_only_count" -gt 0 ]]; then
    echo "" >&2
    echo "  $_file_only_count agent file(s) exist but are NOT documented in AGENTS.md:" >&2
    while IFS= read -r _name; do
        echo "    - dso:$_name  (file: agents/$_name.md)" >&2
    done < "$_file_only"
    echo "" >&2
    echo "  Fix: add a row to AGENTS.md for each undocumented agent, OR delete the file" >&2
    echo "  if the agent is no longer needed." >&2
fi

if [[ "$_doc_only_count" -gt 0 ]]; then
    echo "" >&2
    echo "  $_doc_only_count agent name(s) are documented in AGENTS.md but have NO file:" >&2
    while IFS= read -r _name; do
        echo "    - dso:$_name  (expected: agents/$_name.md)" >&2
    done < "$_doc_only"
    echo "" >&2
    echo "  Fix: create the agent file, OR remove the row from AGENTS.md if the agent" >&2
    echo "  was deleted." >&2
fi

exit 1
