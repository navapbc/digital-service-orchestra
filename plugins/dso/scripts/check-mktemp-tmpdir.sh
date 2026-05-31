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
# Scope: every `*.sh` under tests/ at any depth — NOT just `test-*.sh`. The
# earlier `test-*.sh`-only glob silently exempted underscore-named files
# (`test_*.sh`), support scripts (`run.sh`, `setup.sh`), and test libraries
# (`tests/lib/*.sh`), which is exactly where real violations accumulated
# (Finding 6, external review 2026-05-30). Files under any `fixtures/`
# directory are excluded: fixture `.sh` files are test DATA that may
# intentionally contain the anti-pattern (e.g.
# tests/scripts/fixtures/isolation-rules/, and this rule's own bad/good
# fixtures). The runtime SUITE_ISOLATION_CHECK (suite-engine.sh) is the
# defense-in-depth for fixture files.
#
# Per-line suppression: append `# mktemp-tmpdir-ok` to a line to exempt a
# genuine, reviewed exception (mirrors the `# isolation-ok:` convention in
# scripts/test-isolation-rules/no-repo-source-mktemp.sh).
#
# Usage:
#   check-mktemp-tmpdir.sh [file ...]
# If no files passed: scans all tests/**/*.sh (excluding fixtures/).
#
# Exit codes:
#   0 — no violations
#   1 — violations found (printed to stderr)
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || REPO_ROOT="."
cd "$REPO_ROOT" || { echo "ERROR: cannot cd to $REPO_ROOT" >&2; exit 2; }

if [[ $# -gt 0 ]]; then
    files=("$@")
else
    # Default scope: every *.sh under tests/ at any depth, excluding fixtures/.
    mapfile -t files < <(find tests -name '*.sh' -type f -not -path '*/fixtures/*' 2>/dev/null)
fi

# Filter to in-scope files: any existing `*.sh` under tests/ at any depth,
# excluding fixture data (callers — e.g. pre-commit — may pass arbitrary
# staged paths, including non-test and production scripts that legitimately
# use /tmp/).
in_scope=()
for f in "${files[@]}"; do
    [[ -f "$f" ]] || continue
    # Only tests/**/*.sh; non-test paths fall through silently.
    [[ "$f" =~ ^tests/(.*/)?[^/]+\.sh$ ]] || continue
    # Skip deliberate anti-pattern fixtures (test data, not executed tests).
    [[ "$f" == */fixtures/* ]] && continue
    in_scope+=("$f")
done

if [[ ${#in_scope[@]} -eq 0 ]]; then
    exit 0
fi

# Pattern matches: `mktemp` optionally followed by `-d`, then whitespace,
# then optional quote, then literal `/tmp/`. Captures the anti-pattern.
# Use POSIX `[[:space:]]` (portable on macOS BSD grep + GNU grep) instead of
# `\s` which is a GNU extension and silently no-matches on BSD `grep -E`.
# Lines carrying the `# mktemp-tmpdir-ok` suppression marker are exempted.
violations=0
for f in "${in_scope[@]}"; do
    matches=$(grep -nE 'mktemp([[:space:]]+-d)?[[:space:]]+["'"'"']?/tmp/' "$f" 2>/dev/null | grep -v 'mktemp-tmpdir-ok' || true)
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
    echo "Genuine exceptions: append \`# mktemp-tmpdir-ok\` to the line." >&2
    exit 1
fi

exit 0
