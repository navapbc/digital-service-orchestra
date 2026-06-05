#!/usr/bin/env bash
# check-allowlist-correctness.sh — W5: independent allowlist-correctness gate.
#
# THE RISK: the `changes` CI job and assert-review-liveness's Path B cross-check
# BOTH classify files via skip-review-check.sh + review-gate-allowlist.conf. A
# single bad allowlist pattern (a catch-all like `*`, or a code glob like `*.py`)
# is a SHARED blind spot — both consumers would agree "no reviewable files" and
# CI reports green with ZERO review.
#
# THE GUARD: validate the allowlist DATA independently of the consumer's
# classification path. Feed a fixed set of known-reviewable probe paths (code in
# every common language) plus critical-must-review files through the SAME glob
# matching the consumer uses; if any is matched by the allowlist (i.e. would be
# treated as non-reviewable / skippable), the allowlist is unsafe. Also reject
# catch-all patterns outright.
#
# Inputs (env):
#   ALLOWLIST_OVERRIDE  path to the allowlist conf (default: the shipped one)
#
# Exit codes:
#   0  allowlist is safe
#   1  allowlist would let reviewable/critical files skip review (unsafe)

set -uo pipefail

_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$_DIR/../.." 2>/dev/null && pwd)}"
_ALLOWLIST="${ALLOWLIST_OVERRIDE:-$_PLUGIN_ROOT/hooks/lib/review-gate-allowlist.conf}"

if [[ ! -f "$_ALLOWLIST" ]]; then
    echo "ERROR [allowlist]: allowlist conf not found: $_ALLOWLIST" >&2
    exit 1
fi
# Fail closed if the conf is not a readable regular file — a directory or an
# unreadable file would make the read-loop below silently produce a partial (or
# empty) pattern set, weakening the safety check it is meant to enforce.
if [[ ! -r "$_ALLOWLIST" ]]; then
    echo "ERROR [allowlist]: allowlist conf not readable: $_ALLOWLIST" >&2
    exit 1
fi

# Load patterns exactly as the consumer does: skip comments + blanks.
_PATTERNS=()
while IFS= read -r _line; do
    [[ "$_line" =~ ^[[:space:]]*# ]] && continue
    [[ -z "${_line// }" ]] && continue
    _PATTERNS+=("$_line")
done < "$_ALLOWLIST"

if [[ ${#_PATTERNS[@]} -eq 0 ]]; then
    echo "ERROR [allowlist]: no patterns loaded from $_ALLOWLIST" >&2
    exit 1
fi

_fail=0

# 1) Reject catch-all patterns outright (would skip review of everything).
for _p in "${_PATTERNS[@]}"; do
    case "$_p" in
        '*'|'**'|'*.*'|'?*'|'**/*'|'*/**')
            echo "ERROR [allowlist]: catch-all pattern '$_p' would mark ALL files non-reviewable" >&2
            _fail=1
            ;;
    esac
done

# 2) Known-reviewable probes (code in every common language) — must NOT match.
_CODE_PROBES=(
    app/main.py src/lib.sh web/app.js web/app.ts web/comp.tsx web/comp.jsx
    cmd/main.go lib/x.rb com/A.java src/m.c src/n.cpp src/o.rs lib/p.kt
    src/q.php src/r.swift internal/s.scala
)
# 3) Critical-must-review files (the conf itself documents these as NOT exempt).
_CRITICAL_PROBES=(
    CLAUDE.md .github/workflows/ci.yml .claude/dso-config.conf .claude/settings.json
)
# 3b) Behavior-bearing INSTRUCTION SURFACES that story 3783 made reviewable — must
# NOT match the allowlist. In an agentic codebase a documentation/lint-config/hook/
# host-shim surface shapes agent or enforcement behavior, so an un-reviewed edit is
# an attack vector. (LLM-instruction dirs skills/, hooks/, agents/ were never
# allowlisted; they are covered by the _CODE-style review path already.)
_INSTRUCTION_PROBES=(
    docs/architecture.md docs/nested/guide.md
    .claude/docs/runbook.md
    .semgrep.yml .pre-commit-config.yaml
    .claude/scripts/dso .claude/scripts/helper.sh
)

_matches_any() {  # _matches_any <path> ; echoes the matching pattern, returns 0 if matched
    local f="$1" pat
    for pat in "${_PATTERNS[@]}"; do
        # shellcheck disable=SC2254  # intentional glob match, mirrors the consumer
        case "$f" in $pat) echo "$pat"; return 0 ;; esac
    done
    return 1
}

for _probe in "${_CODE_PROBES[@]}"; do
    if _m="$(_matches_any "$_probe")"; then
        echo "ERROR [allowlist]: reviewable code file '$_probe' is matched by allowlist pattern '$_m' — would skip review" >&2
        _fail=1
    fi
done
for _probe in "${_CRITICAL_PROBES[@]}"; do
    if _m="$(_matches_any "$_probe")"; then
        echo "ERROR [allowlist]: critical-must-review file '$_probe' is matched by allowlist pattern '$_m' — would skip review" >&2
        _fail=1
    fi
done
for _probe in "${_INSTRUCTION_PROBES[@]}"; do
    if _m="$(_matches_any "$_probe")"; then
        echo "ERROR [allowlist]: behavior-bearing instruction surface '$_probe' is matched by allowlist pattern '$_m' — would skip review (story 3783 requires it be reviewable)" >&2
        _fail=1
    fi
done

if [[ "$_fail" -ne 0 ]]; then
    echo "check-allowlist-correctness: FAIL — the review-skip allowlist is unsafe (see above)" >&2
    exit 1
fi
echo "check-allowlist-correctness: ok (${#_PATTERNS[@]} pattern(s); no catch-alls; no code/critical file matched)"
exit 0
