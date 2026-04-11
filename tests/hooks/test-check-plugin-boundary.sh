#!/usr/bin/env bash
# tests/hooks/test-check-plugin-boundary.sh
# Behavioral tests for .claude/hooks/pre-commit/check-plugin-boundary.sh
#
# Tests:
#   1. Permitted path (matching allowlist pattern) → hook exits 0
#   2. Prohibited path (not in allowlist) → hook exits non-zero with named allowlist in error
#   3. Missing allowlist → hook exits 0 (fail-open)
#   4. Error message names the offending file

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
HOOK="$REPO_ROOT/.claude/hooks/pre-commit/check-plugin-boundary.sh"
ALLOWLIST="$REPO_ROOT/.claude/hooks/pre-commit/plugin-boundary-allowlist.conf"

pass=0
fail=0

_pass() { echo "  PASS: $1"; ((pass++)); }
_fail() { echo "  FAIL: $1"; ((fail++)); }

echo "=== test-check-plugin-boundary ==="

# ── Verify hook and allowlist exist ─────────────────────────────────────────

if [[ ! -f "$HOOK" ]]; then
    echo "FATAL: hook not found at $HOOK"
    exit 1
fi

if [[ ! -x "$HOOK" ]]; then
    echo "FATAL: hook not executable at $HOOK"
    exit 1
fi

if [[ ! -f "$ALLOWLIST" ]]; then
    echo "FATAL: allowlist not found at $ALLOWLIST"
    exit 1
fi

# ── Set up temp git repo for isolated staging ────────────────────────────────

TMPDIR_BASE="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_BASE"' EXIT

TESTREPO="$TMPDIR_BASE/testrepo"
mkdir -p "$TESTREPO"
git -C "$TESTREPO" init -q
git -C "$TESTREPO" config user.email "test@test.com"
git -C "$TESTREPO" config user.name "Test"

# Create required directory structure
mkdir -p "$TESTREPO/plugins/dso/skills"
mkdir -p "$TESTREPO/plugins/dso/docs/designs"
mkdir -p "$TESTREPO/plugins/dso/docs/findings"
mkdir -p "$TESTREPO/plugins/dso/scripts"
mkdir -p "$TESTREPO/plugins/dso/hooks"
mkdir -p "$TESTREPO/plugins/dso/agents"

# ── Test 1: Permitted path (skills/**/*.md) → exits 0 ───────────────────────

echo ""
echo "Test 1: Permitted path exits 0"
ALLOWED_FILE="$TESTREPO/plugins/dso/skills/my-skill.md"
echo "# my skill" > "$ALLOWED_FILE"
git -C "$TESTREPO" add "$ALLOWED_FILE"

OUTPUT=$(ALLOWLIST_FILE="$ALLOWLIST" "$HOOK" "$TESTREPO" 2>&1) && EXITCODE=0 || EXITCODE=$?

if [[ $EXITCODE -eq 0 ]]; then
    _pass "Permitted path exits 0"
else
    _fail "Permitted path should exit 0, got $EXITCODE. Output: $OUTPUT"
fi
git -C "$TESTREPO" reset HEAD -- "$ALLOWED_FILE" 2>/dev/null || true

# ── Test 2: Prohibited path → exits non-zero ────────────────────────────────

echo ""
echo "Test 2: Prohibited path exits non-zero"
PROHIBITED_FILE="$TESTREPO/plugins/dso/docs/findings/test.md"
echo "# test" > "$PROHIBITED_FILE"
git -C "$TESTREPO" add "$PROHIBITED_FILE"

OUTPUT=$(ALLOWLIST_FILE="$ALLOWLIST" "$HOOK" "$TESTREPO" 2>&1) && EXITCODE=0 || EXITCODE=$?

if [[ $EXITCODE -ne 0 ]]; then
    _pass "Prohibited path exits non-zero"
else
    _fail "Prohibited path should exit non-zero, got 0. Output: $OUTPUT"
fi

# ── Test 3: Error message names the offending file and allowlist ─────────────

echo ""
echo "Test 3: Error message is parseable (names file and allowlist)"
if echo "$OUTPUT" | grep -q "plugins/dso/docs/findings/test.md"; then
    _pass "Error message names the offending file"
else
    _fail "Error message should name the offending file. Output: $OUTPUT"
fi

if echo "$OUTPUT" | grep -qi "allowlist\|allow.list\|plugin-boundary-allowlist"; then
    _pass "Error message references allowlist"
else
    _fail "Error message should reference allowlist. Output: $OUTPUT"
fi
git -C "$TESTREPO" reset HEAD -- "$PROHIBITED_FILE" 2>/dev/null || true

# ── Test 4: Missing allowlist → exits 0 (fail-open) ─────────────────────────

echo ""
echo "Test 4: Missing allowlist exits 0 (fail-open)"
MISSING_ALLOWLIST="$TMPDIR_BASE/nonexistent-allowlist.conf"
PROHIBITED_FILE2="$TESTREPO/plugins/dso/docs/findings/another.md"
echo "# test" > "$PROHIBITED_FILE2"
git -C "$TESTREPO" add "$PROHIBITED_FILE2"

MISSING_OUTPUT=$(ALLOWLIST_FILE="$MISSING_ALLOWLIST" "$HOOK" "$TESTREPO" 2>&1) && MISSING_EXIT=0 || MISSING_EXIT=$?

if [[ $MISSING_EXIT -eq 0 ]]; then
    _pass "Missing allowlist exits 0 (fail-open)"
else
    _fail "Missing allowlist should exit 0, got $MISSING_EXIT. Output: $MISSING_OUTPUT"
fi
git -C "$TESTREPO" reset HEAD -- "$PROHIBITED_FILE2" 2>/dev/null || true

# ── Test 5: No staged files in plugins/dso/ → exits 0 ───────────────────────

echo ""
echo "Test 5: No staged files under plugins/dso/ exits 0"
OUTSIDE_FILE="$TESTREPO/README.md"
echo "# readme" > "$OUTSIDE_FILE"
git -C "$TESTREPO" add "$OUTSIDE_FILE"

NO_DSO_OUTPUT=$(ALLOWLIST_FILE="$ALLOWLIST" "$HOOK" "$TESTREPO" 2>&1) && NO_DSO_EXIT=0 || NO_DSO_EXIT=$?

if [[ $NO_DSO_EXIT -eq 0 ]]; then
    _pass "No staged DSO files exits 0"
else
    _fail "No staged DSO files should exit 0, got $NO_DSO_EXIT. Output: $NO_DSO_OUTPUT"
fi

# ── Summary ──────────────────────────────────────────────────────────────────

echo ""
echo "=== Results: $pass passed, $fail failed ==="

if [[ $fail -eq 0 ]]; then
    exit 0
else
    exit 1
fi
