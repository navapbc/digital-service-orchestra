#!/usr/bin/env bash
# tests/scripts/test-debug-everything-fix-bug-delegation.sh
# Asserts that debug-everything SKILL.md fully delegates to /dso:fix-bug rather than
# fixing bugs directly via deprecated prompt templates.
#
# Bug dso-yfle: debug-everything orchestrator fixes bugs directly instead of
# delegating to /dso:fix-bug — SKILL.md lacked a complete assembled Task invocation
# example showing /dso:fix-bug combined with the triage and file-ownership context.
#
# Usage: bash tests/scripts/test-debug-everything-fix-bug-delegation.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SKILL_FILE="$REPO_ROOT/plugins/dso/skills/debug-everything/SKILL.md"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-debug-everything-fix-bug-delegation.sh ==="
echo ""

# ── test_no_fix_task_template_reference ──────────────────────────────────────
# SKILL.md must NOT refer to "fix-task prompt template" — this phrase implies
# the deprecated fix-task-tdd.md / fix-task-mechanical.md files are still used.
echo "--- test_no_fix_task_template_reference ---"
_snapshot_fail

_has_old_ref=0
grep -q 'fix-task prompt template' "$SKILL_FILE" && _has_old_ref=1 || true
assert_eq "test_no_fix_task_template_reference: SKILL.md must not reference 'fix-task prompt template'" \
    "0" "$_has_old_ref"
assert_pass_if_clean "test_no_fix_task_template_reference"

# ── test_complete_task_invocation_example ─────────────────────────────────────
# SKILL.md must contain a fenced code block that shows /dso:fix-bug together with
# the Triage Classification Context — proving the complete assembled prompt is documented.
echo ""
echo "--- test_complete_task_invocation_example ---"
_snapshot_fail

_has_combined_example=0
python3 - "$SKILL_FILE" <<'PYEOF' && _has_combined_example=1 || true
import re, sys
with open(sys.argv[1]) as f:
    content = f.read()
blocks = re.findall(r'```[^\n]*\n(.*?)```', content, re.DOTALL)
combined = [b for b in blocks if '/dso:fix-bug' in b and 'Triage Classification Context' in b]
sys.exit(0 if combined else 1)
PYEOF
assert_eq "test_complete_task_invocation_example: SKILL.md must have a fenced block combining /dso:fix-bug with Triage Classification Context" \
    "1" "$_has_combined_example"
assert_pass_if_clean "test_complete_task_invocation_example"

# ── test_assembled_prompt_includes_file_ownership ─────────────────────────────
# The complete assembled example must also show the file_ownership_context
# so orchestrators know to include all three pieces in the Task prompt.
echo ""
echo "--- test_assembled_prompt_includes_file_ownership ---"
_snapshot_fail

_has_ownership_in_example=0
python3 - "$SKILL_FILE" <<'PYEOF' && _has_ownership_in_example=1 || true
import re, sys
with open(sys.argv[1]) as f:
    content = f.read()
blocks = re.findall(r'```[^\n]*\n(.*?)```', content, re.DOTALL)
combined = [b for b in blocks
            if '/dso:fix-bug' in b
            and 'Triage Classification Context' in b
            and ('file_ownership_context' in b or 'File Ownership' in b or 'You own:' in b)]
sys.exit(0 if combined else 1)
PYEOF
assert_eq "test_assembled_prompt_includes_file_ownership: assembled example must include file ownership context" \
    "1" "$_has_ownership_in_example"
assert_pass_if_clean "test_assembled_prompt_includes_file_ownership"

# ── Summary ───────────────────────────────────────────────────────────────────
print_summary
