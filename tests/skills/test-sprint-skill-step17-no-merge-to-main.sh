#!/usr/bin/env bash
# plugins/dso/tests/test-sprint-skill-step17-no-merge-to-main.sh
# RED test: assert desired post-change state of plugins/dso/skills/sprint/SKILL.md
#
# Asserts:
#   1. merge-to-main.sh is NOT referenced in Step 17 (### Step 17: Commit & Push)
#   2. git push IS referenced in Step 17
#   3. merge-to-main.sh IS still referenced in Phase I (## Phase I: Session Close)
#
# This test must FAIL before Task 2 (skill edit) and PASS after it.
#
# Usage: bash plugins/dso/tests/test-sprint-skill-step17-no-merge-to-main.sh
# Returns: exit 0 on PASS, non-zero on FAIL

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
SKILL_MD="$REPO_ROOT/plugins/dso/skills/sprint/SKILL.md"

PASS=0
FAIL=0

# ---------------------------------------------------------------------------
# Verify the skill file exists
# ---------------------------------------------------------------------------
if [[ ! -f "$SKILL_MD" ]]; then
    echo "FAIL: SKILL.md not found at $SKILL_MD" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Extract the Step 17 section (from ### Step 10 up to the next ### heading)
# ---------------------------------------------------------------------------
step17_content=$(awk 'flag && /^### /{exit} /^### Step 17:/{flag=1} flag' "$SKILL_MD")

# ---------------------------------------------------------------------------
# Assertion 1: merge-to-main.sh must NOT appear in Step 17
# ---------------------------------------------------------------------------
if echo "$step17_content" | grep -q 'merge-to-main\.sh'; then
    (( ++FAIL ))
    echo "FAIL: step17_no_merge_to_main" >&2
    echo "  merge-to-main.sh was found in Step 17 but should NOT be present" >&2
else
    (( ++PASS ))
    echo "step17_no_merge_to_main ... PASS"
fi

# ---------------------------------------------------------------------------
# Assertion 2: git push MUST appear in Step 17
# ---------------------------------------------------------------------------
if echo "$step17_content" | grep -q 'git push'; then
    (( ++PASS ))
    echo "step17_has_git_push ... PASS"
else
    (( ++FAIL ))
    echo "FAIL: step17_has_git_push" >&2
    echo "  git push was NOT found in Step 17 but should be present" >&2
fi

# ---------------------------------------------------------------------------
# Assertion 3: merge-to-main.sh MUST appear in Phase I (Session Close)
# ---------------------------------------------------------------------------
phase8_content=$(awk '/^## Phase I:/,0' "$SKILL_MD")
if echo "$phase8_content" | grep -q 'merge-to-main\.sh'; then
    (( ++PASS ))
    echo "phase8_has_merge_to_main ... PASS"
else
    (( ++FAIL ))
    echo "FAIL: phase8_has_merge_to_main" >&2
    echo "  merge-to-main.sh was NOT found in Phase I but should be present" >&2
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "PASSED: $PASS  FAILED: $FAIL"

if [[ "$FAIL" -gt 0 ]]; then
    echo "FAIL"
    exit 1
fi

echo "PASS"
exit 0
