#!/usr/bin/env bash
# check-dangling-references.sh — W6: symbol-level cross-sub-PR conflict check.
#
# THE GAP (P2): the integration review subtracts covered files from scope, so a
# cross-sub-PR semantic conflict is structurally invisible — sub-PR A renames /
# removes `foo`, sub-PR B (or a pre-existing untouched caller) still calls `foo`;
# each sub-PR passes review and tests in isolation, but the COMBINED staged head
# has a dangling reference that no diff-scoped review surfaces (the caller's file
# may have zero diff).
#
# THE CHECK: compute the symbols DEFINED at the base ref inside the union of
# files touched in base..HEAD, find those whose definition is GONE at HEAD
# (removed or renamed) AND not defined anywhere else at HEAD, then grep the WHOLE
# repo at HEAD for surviving references. A surviving reference to an
# now-undefined symbol is a dangling reference (a likely combination conflict).
# This catches cross-module renames and pre-existing untouched callers that no
# diff-scope rule can see.
#
# Scope: shell function defs (`name() {` / `function name`) and Python `def`/
# `class`. Plain `git grep` first cut (sg/ast-grep preferred per CLAUDE.md — a
# follow-up can swap the reference scan for `sg` to drop comment/string matches).
#
# Inputs (env):
#   GITHUB_BASE_REF   base branch (default: main) → base ref origin/<branch>
#   DSO_HEAD_SHA / GITHUB_SHA  head (else HEAD)
#   DSO_DANGLING_MODE enforce (default) | warn
#
# Exit codes:
#   0  no dangling references (or warn mode)
#   1  dangling reference(s) found (enforce) OR fail-closed (bad refs / shallow)
#   78 precondition not met

set -uo pipefail

_precondition_not_met() { echo "PRECONDITION_NOT_MET: $1" >&2; exit 78; }
command -v git >/dev/null 2>&1 || _precondition_not_met "git not in PATH"

MODE="${DSO_DANGLING_MODE:-enforce}"
_BASE_REF="origin/${GITHUB_BASE_REF:-main}"

if ! git rev-parse --verify --quiet "$_BASE_REF" >/dev/null 2>&1; then
    echo "ERROR [dangling]: base ref ${_BASE_REF} not resolvable — fail closed" >&2
    exit 1
fi
if [[ "$(git rev-parse --is-shallow-repository 2>/dev/null)" == "true" ]]; then
    echo "ERROR [dangling]: shallow repository — cannot scan reliably; fail closed" >&2
    exit 1
fi
_HEAD=""
for _cand in "${DSO_HEAD_SHA:-}" "${GITHUB_SHA:-}" "HEAD"; do
    [[ -z "$_cand" ]] && continue
    if git rev-parse --verify --quiet "$_cand" >/dev/null 2>&1; then _HEAD="$_cand"; break; fi
done
[[ -z "$_HEAD" ]] && { echo "ERROR [dangling]: no resolvable head — fail closed" >&2; exit 1; }

# ── Symbol-definition extraction (stdin = file content) ──────────────────────
# Echoes one symbol name per line for the given language.
_defs_for() {
    local lang="$1"
    case "$lang" in
        sh)
            grep -oE '^[[:space:]]*(function[[:space:]]+)?[A-Za-z_][A-Za-z0-9_-]*[[:space:]]*\(\)' \
                | sed -E 's/^[[:space:]]*//; s/^function[[:space:]]+//; s/[[:space:]]*\(\).*$//'
            ;;
        py)
            grep -oE '^[[:space:]]*(def|class)[[:space:]]+[A-Za-z_][A-Za-z0-9_]*' \
                | sed -E 's/^[[:space:]]*(def|class)[[:space:]]+//'
            ;;
    esac
}

_lang_of() {
    case "$1" in
        *.sh) echo sh ;;
        *.py) echo py ;;
        *) echo "" ;;
    esac
}

# Is SYMBOL defined ANYWHERE in the repo at HEAD? (def patterns, both langs)
_defined_at_head() {
    local sym="$1"
    # shell: `sym() {` or `function sym`; python: `def sym`/`class sym`
    git grep -lE "(^|[[:space:]])(function[[:space:]]+)?${sym}[[:space:]]*\(\)|^[[:space:]]*(def|class)[[:space:]]+${sym}([[:space:](:]|\$)" \
        "$_HEAD" -- '*.sh' '*.py' 2>/dev/null | head -1
}

# Surviving references to SYMBOL at HEAD, excluding its own definition lines.
_references_at_head() {
    local sym="$1"
    git grep -nwE "${sym}" "$_HEAD" -- '*.sh' '*.py' 2>/dev/null \
        | grep -vE "(function[[:space:]]+)?${sym}[[:space:]]*\(\)|^[^:]*:[0-9]+:[[:space:]]*(def|class)[[:space:]]+${sym}([[:space:](:]|\$)"
}

# ── Touched files in base..head ──────────────────────────────────────────────
_TOUCHED="$(git diff --name-only "${_BASE_REF}...${_HEAD}" -- '*.sh' '*.py' 2>/dev/null)"
if [[ -z "$_TOUCHED" ]]; then
    echo "check-dangling-references: ok (no .sh/.py files touched in ${_BASE_REF}..${_HEAD})"
    exit 0
fi

_dangling=""
_checked=0
while IFS= read -r _file; do
    [[ -z "$_file" ]] && continue
    _lang="$(_lang_of "$_file")"; [[ -z "$_lang" ]] && continue
    # Symbols defined at base in this file.
    _base_defs="$(git show "${_BASE_REF}:${_file}" 2>/dev/null | _defs_for "$_lang" | LC_ALL=C sort -u)"
    [[ -z "$_base_defs" ]] && continue
    # Symbols still defined at head in this file.
    _head_defs="$(git show "${_HEAD}:${_file}" 2>/dev/null | _defs_for "$_lang" | LC_ALL=C sort -u)"
    # Removed-from-this-file symbols.
    _removed="$(comm -23 <(printf '%s\n' "$_base_defs") <(printf '%s\n' "$_head_defs"))"
    [[ -z "$_removed" ]] && continue
    while IFS= read -r _sym; do
        [[ -z "$_sym" ]] && continue
        _checked=$(( _checked + 1 ))
        # Still defined elsewhere at head? → moved, not dangling.
        [[ -n "$(_defined_at_head "$_sym")" ]] && continue
        # Undefined at head — any surviving references?
        local_refs="$(_references_at_head "$_sym")"
        if [[ -n "$local_refs" ]]; then
            _dangling+="  SYMBOL '${_sym}' (removed/renamed in ${_file}) is undefined at HEAD but still referenced:"$'\n'
            _dangling+="$(printf '%s\n' "$local_refs" | sed 's/^/      /')"$'\n'
        fi
    done <<< "$_removed"
done <<< "$_TOUCHED"

if [[ -z "$_dangling" ]]; then
    echo "check-dangling-references: ok (${_checked} removed/renamed symbol(s) checked; no dangling references at HEAD)"
    exit 0
fi

echo "ERROR [dangling]: cross-sub-PR dangling reference(s) — a symbol removed/renamed in one change is still referenced at the combined HEAD:" >&2
printf '%s' "$_dangling" >&2
if [[ "$MODE" == "warn" ]]; then
    echo "::warning::check-dangling-references found dangling references — MODE=warn (not blocking this run)"
    exit 0
fi
exit 1
