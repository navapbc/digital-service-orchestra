#!/usr/bin/env bash
# tests/docs/test-reviewer-base-repo-root-context.sh
#
# Structural boundary test: reviewer-base.md must instruct reviewers to use the
# REPO_ROOT value passed via the dispatch prompt — NOT derive it from
# `git rev-parse --show-toplevel` — when running Grep/Read/Glob for context lookups.
#
# This prevents false-positive findings when a reviewer sub-agent is dispatched
# inside a worktree whose CWD differs from the session's REPO_ROOT. Without this
# instruction, grep runs against the worktree path and finds no matches, producing
# spurious "missing reference" and "fragile" findings.
#
# Observable behavior tested:
#   1. reviewer-base.md contains an instruction to use the passed-in REPO_ROOT
#      (not re-derived via git) when running any grep or file-read commands.
#   2. The instruction appears in Step 2 (the review step) or in a prominent
#      preamble — it must be present where grep usage is instructed.
#   3. The instruction warns that `git rev-parse --show-toplevel` can return a
#      worktree path that differs from the actual repo root, OR instructs to use
#      the provided REPO_ROOT value directly.
#
# RED phase: tests FAIL because reviewer-base.md currently instructs Step 1 to
# run `REPO_ROOT=$(git rev-parse --show-toplevel)` but does not instruct
# reviewers to use the passed REPO_ROOT for grep/read context lookups in Step 2.

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
ASSERT_LIB="$REPO_ROOT/tests/lib/assert.sh"
# shellcheck source=../lib/assert.sh
source "$ASSERT_LIB"

REVIEWER_BASE="$REPO_ROOT/plugins/dso/docs/workflows/prompts/reviewer-base.md"

# ---------------------------------------------------------------------------
# test_repo_root_passed_context_instruction
#
# Verifies that reviewer-base.md instructs reviewers to use the REPO_ROOT
# provided in the dispatch prompt when running grep/read/glob for context.
#
# The key behavioral change: reviewers must NOT rely on `git rev-parse` to
# discover the repo root — they must use the REPO_ROOT passed to them.
# ---------------------------------------------------------------------------
echo "=== test_repo_root_passed_context_instruction ==="

base_content="$(< "$REVIEWER_BASE")"

# The instruction must tell the reviewer to use the *passed* REPO_ROOT
# (not a newly-derived one) for grep/context lookups. We look for language
# that explicitly says the REPO_ROOT value comes from the dispatch prompt
# OR that file/grep operations should be rooted at REPO_ROOT.
#
# Acceptable forms include:
#   "use the REPO_ROOT provided in your prompt"
#   "the REPO_ROOT passed to you"
#   "cd to REPO_ROOT before running grep"
#   "use REPO_ROOT for all grep and file lookups"
#   "REPO_ROOT is provided in the prompt — use it"
# We also accept language that warns about worktree CWD divergence.

passed_repo_root_instruction="$(python3 - "$REVIEWER_BASE" <<'PYEOF'
import sys, re
content = open(sys.argv[1]).read()

# Patterns indicating the reviewer should use the *provided* REPO_ROOT
# (rather than re-deriving via git) for context file operations.
patterns = [
    r'use.*REPO_ROOT.*provided',
    r'REPO_ROOT.*provided.*prompt',
    r'REPO_ROOT.*passed',
    r'passed.*REPO_ROOT',
    r'provided.*REPO_ROOT.*grep',
    r'REPO_ROOT.*grep',
    r'grep.*REPO_ROOT',
    r'cd.*REPO_ROOT.*grep',
    r'cd.*\$REPO_ROOT',
    r'worktree.*REPO_ROOT',
    r'REPO_ROOT.*worktree',
    r'use the REPO_ROOT',
    r'REPO_ROOT for all',
]
for pat in patterns:
    if re.search(pat, content, re.IGNORECASE):
        print(f"FOUND: {pat}")
        break
PYEOF
)"

if [[ -n "$passed_repo_root_instruction" ]]; then
    assert_eq \
        "reviewer-base.md instructs use of provided REPO_ROOT for context lookups" \
        "present" \
        "present"
else
    assert_eq \
        "reviewer-base.md instructs use of provided REPO_ROOT for context lookups" \
        "instruction to use provided REPO_ROOT for grep/file context lookups" \
        "no such instruction found — reviewers derive REPO_ROOT independently via git"
fi

# ---------------------------------------------------------------------------
# test_repo_root_instruction_placement
#
# Verifies the REPO_ROOT instruction appears in Step 2 (the grep-using step)
# or in a prominent early section (e.g., Procedure preamble). It must not
# only appear in Step 1/Step 3 which are about scripts, not grep context.
# ---------------------------------------------------------------------------
echo ""
echo "=== test_repo_root_instruction_placement ==="

# Check that the instruction appears in the Step 2 section or in an explicit
# "working directory" / "context lookup" section before Step 3.
step2_section="$(python3 - "$REVIEWER_BASE" <<'PYEOF'
import sys, re
content = open(sys.argv[1]).read()
# Extract from "Step 2" through "Step 3"
m = re.search(r'Step 2[^\n]*\n(.*?)(?=Step 3[^\n]*\n)', content, re.DOTALL | re.IGNORECASE)
if m:
    print(m.group(1))
PYEOF
)"

repo_root_in_step2="$(python3 - <<PYEOF
import re
content = """$step2_section"""
patterns = [
    r'use.*REPO_ROOT.*provided',
    r'REPO_ROOT.*provided.*prompt',
    r'REPO_ROOT.*passed',
    r'passed.*REPO_ROOT',
    r'cd.*\\\$REPO_ROOT',
    r'use the REPO_ROOT',
    r'REPO_ROOT for all',
    r'provided REPO_ROOT',
]
for pat in patterns:
    if re.search(pat, content, re.IGNORECASE):
        print(f"FOUND_IN_STEP2: {pat}")
        break
PYEOF
)"

# Also check if a dedicated "Working Directory" section exists anywhere in the file
working_dir_section="$(python3 - "$REVIEWER_BASE" <<'PYEOF'
import sys, re
content = open(sys.argv[1]).read()
# Look for a section explicitly addressing working directory or CWD for context lookups
patterns = [
    r'working directory',
    r'cd.*REPO_ROOT',
    r'REPO_ROOT.*context.*lookup',
]
for pat in patterns:
    if re.search(pat, content, re.IGNORECASE):
        print(f"FOUND: {pat}")
        break
PYEOF
)"

if [[ -n "$repo_root_in_step2" || -n "$working_dir_section" ]]; then
    assert_eq \
        "REPO_ROOT instruction is placed in Step 2 or a working-directory section" \
        "present" \
        "present"
else
    assert_eq \
        "REPO_ROOT instruction is placed in Step 2 or a working-directory section" \
        "REPO_ROOT instruction in Step 2 (grep/context-lookup step) or dedicated section" \
        "instruction not found in Step 2 or a working-directory guidance section"
fi

print_summary
