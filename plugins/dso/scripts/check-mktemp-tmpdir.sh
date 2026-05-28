#!/usr/bin/env bash
# check-mktemp-tmpdir.sh
# Pre-commit lint: forbid the `mktemp [-d] /tmp/...` anti-pattern in test files.
#
# Rationale: the test suite engine (tests/lib/suite-engine.sh) sets TMPDIR to
# a per-test directory for isolation. Test files that hardcode `/tmp/` in
# mktemp templates bypass that isolation, placing files in shared /tmp and
# producing cross-test contention under parallel test execution (see
# CLAUDE.md `always:mktemp-tmp` and bug a556-dc36-2177-4c38).
#
# Correct patterns for tests:
#   mktemp [-d]                                       # bare — honors $TMPDIR
#   mktemp [-d] "${TMPDIR:-/tmp}/<prefix>.XXXXXX"     # explicit, isolated
#
# Anti-pattern (this script flags):
#   mktemp [-d] "/tmp/<prefix>.XXXXXX"
#   mktemp [-d] /tmp/<prefix>.XXXXXX
#
# Usage:
#   check-mktemp-tmpdir.sh [file ...]
# If no files passed: scans all tests/**/test-*.sh
#
# Exit codes:
#   0 — no violations
#   1 — violations found (printed to stderr)
set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || REPO_ROOT="."
cd "$REPO_ROOT" || { echo "ERROR: cannot cd to $REPO_ROOT" >&2; exit 2; }

if [[ $# -gt 0 ]]; then
    files=("$@")
else
    # Default scope: every test-*.sh under tests/
    mapfile -t files < <(find tests -name 'test-*.sh' -type f 2>/dev/null)
fi

# Filter to only existing test-*.sh files (callers may pass non-test files)
in_scope=()
for f in "${files[@]}"; do
    [[ -f "$f" ]] || continue
    # Only enforce on test files. Production scripts may legitimately use /tmp/.
    case "$f" in
        tests/*/test-*.sh) in_scope+=("$f") ;;
        *)
            # Allow non-test files through silently (the rule only applies to tests).
            continue
            ;;
    esac
done

if [[ ${#in_scope[@]} -eq 0 ]]; then
    exit 0
fi

# Pattern matches: `mktemp` optionally followed by `-d`, then whitespace,
# then optional quote, then literal `/tmp/`. Captures the anti-pattern.
violations=0
for f in "${in_scope[@]}"; do
    matches=$(grep -nE 'mktemp(\s+-d)?\s+["'"'"']?/tmp/' "$f" 2>/dev/null || true)
    if [[ -n "$matches" ]]; then
        if [[ $violations -eq 0 ]]; then
            echo "ERROR: mktemp /tmp/ anti-pattern detected in test files." >&2
            echo "Tests must use \${TMPDIR:-/tmp}/<prefix>.XXXXXX to honor suite-engine isolation." >&2
            echo "See CLAUDE.md always:mktemp-tmp and bug a556-dc36-2177-4c38." >&2
            echo "" >&2
        fi
        while IFS= read -r line; do
            echo "  $f:$line" >&2
        done <<< "$matches"
        violations=$((violations + 1))
    fi
done

if [[ $violations -gt 0 ]]; then
    echo "" >&2
    echo "Fix: replace \`mktemp [-d] \"/tmp/<x>\"\` with \`mktemp [-d] \"\${TMPDIR:-/tmp}/<x>\"\`." >&2
    exit 1
fi

exit 0
