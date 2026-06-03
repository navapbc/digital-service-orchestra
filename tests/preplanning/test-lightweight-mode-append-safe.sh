#!/usr/bin/env bash
# tests/preplanning/test-lightweight-mode-append-safe.sh
#
# Structural test: lightweight-mode.md must NOT instruct an unqualified
# epic-description rewrite (which would clobber brainstorm-authored content),
# and must carry the PREPLANNING_CONTEXT_LIGHTWEIGHT marker as the sole
# structured output.
#
# RED: before fix — "Update the epic description with:" destructive bullet exists
# GREEN: after fix — bullet removed, PREPLANNING_CONTEXT_LIGHTWEIGHT marker present
#
# Usage: bash tests/preplanning/test-lightweight-mode-append-safe.sh
set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
LIGHTWEIGHT_MD="${REPO_ROOT}/plugins/dso/skills/preplanning/prompts/lightweight-mode.md"

PASS=0
FAIL=0

pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

echo "=== lightweight-mode.md: no destructive epic-description rewrite instruction ==="

# Assert 1: no bare "Update the epic description" instruction
if grep -qF "Update the epic description" "$LIGHTWEIGHT_MD"; then
  fail "Found 'Update the epic description' — destructive rewrite instruction must be removed (Step 5 fix)"
else
  pass "No 'Update the epic description' instruction found"
fi

# Assert 2: no unqualified 'ticket edit --description' instruction
# (a bare --description flag would replace the full description)
if grep -qE 'ticket edit.*--description[^-]' "$LIGHTWEIGHT_MD"; then
  fail "Found 'ticket edit --description' — unqualified description-replace must not be instructed in lightweight mode"
else
  pass "No unqualified 'ticket edit --description' instruction found"
fi

echo ""
echo "=== lightweight-mode.md: PREPLANNING_CONTEXT_LIGHTWEIGHT marker present ==="

# Assert 3: PREPLANNING_CONTEXT_LIGHTWEIGHT comment marker is present
if grep -qF "PREPLANNING_CONTEXT_LIGHTWEIGHT" "$LIGHTWEIGHT_MD"; then
  pass "PREPLANNING_CONTEXT_LIGHTWEIGHT marker present — comment is the sole structured output"
else
  fail "PREPLANNING_CONTEXT_LIGHTWEIGHT marker missing — comment-writing step is required"
fi

# Assert 4: the comment-writing step includes done definitions / scope / considerations
# (content requirements must be carried in the comment, not just the description)
if grep -qiE 'done.?def|doneDefinition' "$LIGHTWEIGHT_MD"; then
  pass "Done definitions are referenced in the file"
else
  fail "Done definitions reference missing from lightweight-mode.md"
fi

echo ""
echo "=== Summary ==="
echo "  PASS: $PASS  FAIL: $FAIL"
if [[ $FAIL -gt 0 ]]; then
  exit 1
fi
exit 0
