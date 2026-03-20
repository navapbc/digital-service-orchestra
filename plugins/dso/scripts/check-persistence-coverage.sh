#!/usr/bin/env bash
set -euo pipefail
# scripts/check-persistence-coverage.sh
#
# Verifies that changes to persistence-critical source files are accompanied
# by changes to persistence test files. Exits non-zero if coverage is missing.
#
# Patterns are read from .claude/dso-config.conf via read-config.sh:
#   persistence.source_patterns — literal substrings (grep -F)
#   persistence.test_patterns   — extended regex patterns (grep -E)
#
# Usage:
#   scripts/check-persistence-coverage.sh          # diff against main
#   scripts/check-persistence-coverage.sh --base=develop  # custom base
#
# Runs in:
#   - CI: lightweight job after fast-gate (<10s)
#   - /dso:sprint Phase 6: after lint/test, before commit

set -euo pipefail

# REVIEW-DEFENSE: The backward-compat wrapper at scripts/check-persistence-coverage.sh
# still retains the full original hardcoded-array implementation. Converting that wrapper
# to a thin exec-delegation (like merge-to-main.sh, check-local-env.sh, etc.) is
# explicitly the job of downstream task lockpick-doc-to-logic-rs81 and is out of scope
# for the current task (lockpick-doc-to-logic-y46g).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git rev-parse --show-toplevel)"

# --- Load patterns from config ---
# source_patterns: literal substrings (grep -F)
# test_patterns: extended regex patterns (grep -E)

# CONFIG_FILE may be overridden via environment variable for test isolation.
# In production, defaults to the repo-level .claude/dso-config.conf.
CONFIG_FILE="${CONFIG_FILE:-$REPO_ROOT/.claude/dso-config.conf}"

# If the config file does not exist at all, treat as no-op with a warning.
if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "INFO: .claude/dso-config.conf not configured (file not found: $CONFIG_FILE) — skipping persistence coverage check." >&2
    exit 0
fi

# Read source patterns; exit 0 (no-op) if key is absent (read-config.sh --list exits 1 on absent key)
SOURCE_PATTERNS=()
_source_raw=""
if _source_raw=$(bash "$SCRIPT_DIR/read-config.sh" --list persistence.source_patterns "$CONFIG_FILE" 2>/dev/null); then
    while IFS= read -r _p; do
        [ -n "$_p" ] && SOURCE_PATTERNS+=("$_p")
    done <<< "$_source_raw"
else
    # Key absent — treat as no-op
    echo "INFO: persistence.source_patterns not configured in .claude/dso-config.conf — skipping persistence coverage check." >&2
    exit 0
fi

# Read test patterns; exit 0 (no-op) if key is absent
TEST_PATTERNS=()
_test_raw=""
if _test_raw=$(bash "$SCRIPT_DIR/read-config.sh" --list persistence.test_patterns "$CONFIG_FILE" 2>/dev/null); then
    while IFS= read -r _p; do
        [ -n "$_p" ] && TEST_PATTERNS+=("$_p")
    done <<< "$_test_raw"
else
    echo "INFO: persistence.test_patterns not configured in .claude/dso-config.conf — skipping persistence coverage check." >&2
    exit 0
fi

if [ ${#SOURCE_PATTERNS[@]} -eq 0 ]; then
    echo "✓ No persistence source patterns configured — nothing to check."
    exit 0
fi

# --- Parse arguments ---
DIFF_BASE="main"
for arg in "$@"; do
  case "$arg" in
    --base=*) DIFF_BASE="${arg#--base=}" ;;
    --help|-h)
      echo "Usage: $0 [--base=<branch>]"
      echo "Checks that persistence source changes have matching test changes."
      exit 0
      ;;
  esac
done

# --- Get changed files ---
# When running as a pre-commit hook (staged files exist), check only staged files.
# Otherwise (CI / manual invocation), check the full branch diff.
STAGED_FILES=$(git diff --cached --name-only 2>/dev/null)
if [ -n "$STAGED_FILES" ]; then
  CHANGED_FILES="$STAGED_FILES"
else
  CHANGED_FILES=$(git diff "${DIFF_BASE}...HEAD" --name-only 2>/dev/null || git diff HEAD --name-only)
fi

if [ -z "$CHANGED_FILES" ]; then
  echo "✓ No changed files — nothing to check."
  exit 0
fi

# --- Check for persistence source changes ---
SOURCES_CHANGED=()
for pattern in "${SOURCE_PATTERNS[@]}"; do
  while IFS= read -r file; do
    if [ -n "$file" ]; then
      SOURCES_CHANGED+=("$file")
    fi
  done < <(echo "$CHANGED_FILES" | grep -F "$pattern" || true)
done

# Deduplicate (a file could match multiple patterns)
if [ ${#SOURCES_CHANGED[@]} -gt 0 ]; then
  # shellcheck disable=SC2207
  SOURCES_CHANGED=($(printf '%s\n' "${SOURCES_CHANGED[@]}" | sort -u))
fi

if [ ${#SOURCES_CHANGED[@]} -eq 0 ]; then
  echo "✓ No persistence-critical files changed — nothing to check."
  exit 0
fi

# --- Check for persistence test changes ---
TESTS_CHANGED=()
for pattern in "${TEST_PATTERNS[@]}"; do
  while IFS= read -r file; do
    if [ -n "$file" ]; then
      TESTS_CHANGED+=("$file")
    fi
  done < <(echo "$CHANGED_FILES" | grep -E "$pattern" || true)
done

# Deduplicate
if [ ${#TESTS_CHANGED[@]} -gt 0 ]; then
  # shellcheck disable=SC2207
  TESTS_CHANGED=($(printf '%s\n' "${TESTS_CHANGED[@]}" | sort -u))
fi

if [ ${#TESTS_CHANGED[@]} -gt 0 ]; then
  echo "✓ Persistence coverage check passed."
  echo "  Sources changed:"
  for f in "${SOURCES_CHANGED[@]}"; do echo "    - $f"; done
  echo "  Tests changed:"
  for f in "${TESTS_CHANGED[@]}"; do echo "    - $f"; done
  exit 0
fi

# --- Failure ---
echo "✗ Persistence coverage check FAILED."
echo ""
echo "  The following persistence-critical files were changed:"
for f in "${SOURCES_CHANGED[@]}"; do echo "    - $f"; done
echo ""
echo "  But NO persistence test files were changed. Expected at least one of:"
for pattern in "${TEST_PATTERNS[@]}"; do
  echo "    - files matching: $pattern"
done
echo ""
echo "  To fix: add or update a persistence test that verifies cross-worker"
echo "  or DB round-trip behavior for the changed code."
exit 1
