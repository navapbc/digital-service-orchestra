#!/usr/bin/env bash
# tests/scripts/test-story-decomposer-cc-contract.sh
#
# Behavior test pinning the structural CC-awareness contract of
# plugins/dso/agents/story-decomposer.md and the matching dispatch hook in
# plugins/dso/skills/preplanning/SKILL.md.
#
# This is a documentation-shape test, not an agent-dispatch test — it
# verifies the load-bearing tokens any real dispatch must respect:
#   1. story-decomposer documents "### Epic Closure Checks" as a top-level input.
#   2. story-decomposer accepts and emits a "cc_coverage_plan" field.
#   3. story-decomposer documents the ← Validates Closure Check: form.
#   4. preplanning Phase H passes {epic-closure-checks} into the dispatch.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DECOMPOSER="$REPO_ROOT/plugins/dso/agents/story-decomposer.md"
PREPLAN="$REPO_ROOT/plugins/dso/skills/preplanning/SKILL.md"

PASS=0
FAIL=0

_assert_grep() {
    local name="$1" file="$2" pattern="$3"
    if grep -qE "$pattern" "$file"; then
        PASS=$((PASS+1))
    else
        FAIL=$((FAIL+1))
        printf "FAIL: %s\n  file:    %s\n  pattern: %s\n" "$name" "$file" "$pattern" >&2
    fi
}

_assert_grep "decomposer documents Epic Closure Checks section" \
    "$DECOMPOSER" '^### Epic Closure Checks'

_assert_grep "decomposer accepts {epic-closure-checks} placeholder" \
    "$DECOMPOSER" '\{epic-closure-checks\}'

_assert_grep "decomposer documents cc_coverage_plan field" \
    "$DECOMPOSER" 'cc_coverage_plan'

_assert_grep "decomposer documents cc_id stable identifier" \
    "$DECOMPOSER" 'cc-1'

_assert_grep "decomposer documents ← Validates Closure Check: form" \
    "$DECOMPOSER" 'Validates Closure Check'

_assert_grep "preplanning passes {epic-closure-checks} into dispatch" \
    "$PREPLAN" '\{epic-closure-checks\}'

_assert_grep "preplanning documents cc-1 stable identifier convention" \
    "$PREPLAN" 'cc-1'

printf "story-decomposer-cc-contract: PASS=%d FAIL=%d\n" "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]] || exit 1
exit 0
