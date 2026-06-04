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
# `class`.
#
# REFERENCE SCAN (story 29e7 / CF-8 / E7): the reference side is now syntactic
# via `sg` (ast-grep) for .sh/.py — it matches identifier *usages* and ignores
# matches inside comments and string literals, which a plain `git grep` cannot
# distinguish (the #1 false-positive source: a removed symbol that survives only
# in a comment or a doc string). When `sg` is unavailable the script falls back
# to a guarded whole-word `git grep` (per CLAUDE.md ast-grep guidance). The
# reference side ALSO scans doc/config carriers (.md/.yml/.yaml/Makefile/.txt)
# via whole-word `git grep` — a surviving textual mention of a removed symbol in
# docs/config is a real dangling reference worth surfacing. A short-symbol guard
# (DSO_DANGLING_MIN_LEN, default 3) suppresses noise from very short identifiers
# whose bare-identifier match rate is dominated by coincidence.
#
# Inputs (env):
#   GITHUB_BASE_REF   base branch (default: main) → base ref origin/<branch>
#   DSO_HEAD_SHA / GITHUB_SHA  head (else HEAD)
#   DSO_DANGLING_MODE enforce (default) | warn
#   DSO_DANGLING_MIN_LEN  min symbol length to scan references for (default 3)
#   DSO_DANGLING_FORCE_NO_SG  if =1, pretend sg is absent (exercises fallback)
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
_MIN_LEN="${DSO_DANGLING_MIN_LEN:-3}"
# Validate the tuning knob: a non-numeric value would break the arithmetic
# short-symbol guard below (`(( ${#sym} < _MIN_LEN ))`) — bash arithmetic on a
# non-numeric operand errors under set -u-adjacent strictness or silently
# evaluates to 0, disabling the guard. Reject → default 3.
if ! [[ "$_MIN_LEN" =~ ^[0-9]+$ ]]; then
    echo "WARN [dangling]: DSO_DANGLING_MIN_LEN='${_MIN_LEN}' is not a non-negative integer; using default 3" >&2
    _MIN_LEN=3
fi

# ast-grep availability — drives syntactic reference matching for .sh/.py.
# CRITICAL: invoke `ast-grep`, NEVER bare `sg`. On Linux (incl. CI runners) `sg`
# is the shadow-utils setgroups command — a DIFFERENT tool. `command -v sg`
# succeeds there but `sg run ...` is gibberish to it → empty output → SILENT
# FALSE NEGATIVES (the check passes vacuously, never catching a real dangling
# reference). Resolve the real ast-grep binary: prefer `ast-grep`; accept `sg`
# only if it self-identifies as ast-grep (e.g. macOS brew where both names map
# to ast-grep). DSO_DANGLING_FORCE_NO_SG=1 forces the git-grep fallback (tested).
_ASTGREP=""
if [[ "${DSO_DANGLING_FORCE_NO_SG:-0}" != "1" ]]; then
    if command -v ast-grep >/dev/null 2>&1; then
        _ASTGREP="ast-grep"
    elif command -v sg >/dev/null 2>&1 && sg --version 2>/dev/null | grep -qE '^(sg|ast-grep) [0-9]'; then
        _ASTGREP="sg"
    fi
fi
_HAVE_SG=0; [[ -n "$_ASTGREP" ]] && _HAVE_SG=1

# Reference-side doc/config carriers scanned via whole-word git grep.
_REF_DOC_PATHSPEC=( '*.md' '*.yml' '*.yaml' '*.txt' 'Makefile' '*/Makefile' )

# Temp dir for materialized HEAD content fed to sg (sg reads files, not refs).
_SG_WORK=""
_sg_workdir() {
    [[ -n "$_SG_WORK" ]] && { echo "$_SG_WORK"; return; }
    _SG_WORK="$(mktemp -d "/tmp/dso-dangling-sg.XXXXXX")" || return 1
    echo "$_SG_WORK"
}
trap '[[ -n "$_SG_WORK" ]] && rm -rf "$_SG_WORK"' EXIT

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
    # Language-SCOPED definition probes. A combined pattern over both pathspecs
    # let a Python 0-arg CALL `sym()` in a .py file match the SHELL definition
    # pattern `${sym}()`, falsely reporting sym as still-defined and MASKING a
    # real dangling reference (false negative). Shell defs (`sym() {` /
    # `function sym`) exist only in .sh; Python `def`/`class` only in .py.
    { git grep -lE "(^|[[:space:]])(function[[:space:]]+)?${sym}[[:space:]]*\(\)" "$_HEAD" -- '*.sh' 2>/dev/null
      git grep -lE "^[[:space:]]*(def|class)[[:space:]]+${sym}([[:space:](:]|\$)" "$_HEAD" -- '*.py' 2>/dev/null
    } | head -1
}

# sg lang for a path, or empty if not an sg-scanned code file.
_sg_lang_of() {
    case "$1" in
        *.sh) echo bash ;;
        *.py) echo python ;;
        *) echo "" ;;
    esac
}

# Materialize "$_HEAD:$file" into the sg workdir under its original relative path
# so sg can parse it. Echoes the temp path, or empty on failure.
_materialize_head_file() {
    local file="$1" wd dst
    wd="$(_sg_workdir)" || return 1
    dst="$wd/$file"
    mkdir -p "$(dirname "$dst")" 2>/dev/null || return 1
    # git show's exit gates the echo (a write/I/O failure → non-zero → no echo →
    # caller skips). The extra -f guard makes the success path explicit: never
    # echo a path that is not a regular file, so downstream sg can never operate
    # on a missing/partial materialization. On any failure, remove the stub file
    # the `>` redirect may have created and signal failure.
    if git show "${_HEAD}:${file}" >"$dst" 2>/dev/null && [[ -f "$dst" ]]; then
        echo "$dst"
    else
        rm -f "$dst" 2>/dev/null
        return 1
    fi
}

# Syntactic references to SYMBOL in .sh/.py at HEAD via sg (ignores comments /
# strings). Emits "<file>:<line>:<text>" lines (paths relativized to repo).
# Returns reference lines EXCLUDING the symbol's own definition lines.
_sg_code_references() {
    local sym="$1" wd
    # Prefilter: only files that textually contain the symbol at HEAD, to avoid
    # materializing the whole tree. This is a candidate set; sg does the real
    # (comment/string-aware) matching.
    local cand
    cand="$(git grep -lw "$sym" "$_HEAD" -- '*.sh' '*.py' 2>/dev/null | sed -E 's/^[^:]*://')"
    [[ -z "$cand" ]] && return 0
    wd="$(_sg_workdir)" || return 1
    while IFS= read -r file; do
        [[ -z "$file" ]] && continue
        local lang tmp _rc _excl
        lang="$(_sg_lang_of "$file")"; [[ -z "$lang" ]] && continue
        tmp="$(_materialize_head_file "$file")"; [[ -z "$tmp" ]] && continue
        # Language-CORRECT definition-exclusion, applied per file using ONLY the
        # pattern for this file's language. A combined (language-agnostic) filter
        # would let the shell-def pattern drop a Python call `sym()` in a .py file
        # that incidentally contains def-shaped text — a false negative. Mirrors
        # the per-language probes in _defined_at_head.
        if [[ "$lang" == "bash" ]]; then
            _excl="(function[[:space:]]+)?${sym}[[:space:]]*\(\)[[:space:]]*\{"
        else
            _excl=":[[:space:]]*(def|class)[[:space:]]+${sym}([[:space:](:]|\$)"
        fi
        {
            # sg matches the bare identifier syntactically (excludes comments/
            # strings and substring/word-boundary noise). Re-anchor to repo path.
            "$_ASTGREP" run -p "$sym" -l "$lang" "$tmp" --heading=never 2>/dev/null \
                | sed -E "s#^${tmp}:#${file}:#"
            _rc=${PIPESTATUS[0]}
            # ast-grep exit: 0=match, 1=no-match, >=2=HARD error (bad invocation /
            # unparseable file). A hard error must NOT be silently read as "no
            # references" (the false-negative class this check prevents) — fall
            # back to a whole-word git grep for THIS file (over-reports, never
            # under-reports). Candidate files all exist at HEAD (git grep -lw
            # selected them), so rc=1 is a genuine no-match, not a miss.
            if (( _rc >= 2 )); then
                echo "WARN [dangling]: ast-grep rc=${_rc} on ${file}; whole-word grep fallback" >&2
                git grep -nwE "${sym}" "$_HEAD" -- "$file" 2>/dev/null \
                    | sed -E "s#^${_HEAD}:##"
            fi
        } | grep -vE "$_excl"
    done <<< "$cand"
}

# Fallback (sg absent): guarded whole-word git grep, minus def lines. Each
# language is scanned with ONLY its own definition-exclusion pattern so a Python
# call `sym()` is never dropped by the shell-definition filter (and vice versa).
_grep_code_references() {
    local sym="$1"
    git grep -nwE "${sym}" "$_HEAD" -- '*.sh' 2>/dev/null \
        | grep -vE "(function[[:space:]]+)?${sym}[[:space:]]*\(\)[[:space:]]*\{"
    git grep -nwE "${sym}" "$_HEAD" -- '*.py' 2>/dev/null \
        | grep -vE "^[^:]*:[0-9]+:[[:space:]]*(def|class)[[:space:]]+${sym}([[:space:](:]|\$)"
}

# Doc/config-carrier references (.md/.yml/.yaml/.txt/Makefile): a surviving
# whole-word textual mention of a removed symbol is a real dangling reference.
_doc_references() {
    local sym="$1"
    git grep -nwF "$sym" "$_HEAD" -- "${_REF_DOC_PATHSPEC[@]}" 2>/dev/null
}

# Surviving references to SYMBOL at HEAD, excluding its own definition lines.
# Combines the syntactic/code scan (sg or grep fallback) with the doc scan.
_references_at_head() {
    local sym="$1"
    # Short-symbol guard: very short identifiers (e.g. `x`, `id`) generate
    # coincidental matches that dominate the signal — skip them.
    if (( ${#sym} < _MIN_LEN )); then
        return 0
    fi
    if (( _HAVE_SG == 1 )); then
        _sg_code_references "$sym"
    else
        _grep_code_references "$sym"
    fi
    _doc_references "$sym"
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
