---
id: dso-4j40
status: in_progress
deps: [dso-ofdr, dso-qzn4, dso-4mdr]
links: []
created: 2026-03-22T15:17:53Z
type: task
priority: 1
assignee: Joe Oakhart
parent: w21-jtkr
---
# Replace REVIEW-WORKFLOW.md Step 3 model selection and Step 4 dispatch with classifier-driven named agent routing

Update REVIEW-WORKFLOW.md to replace the current grep-based model selection (Step 3) with classifier invocation, and replace the general-purpose sub-agent dispatch (Step 4) with named agent dispatch based on the selected tier.

## Context

Currently Step 3 runs:
  CHANGED_FILES=$({ git diff HEAD --name-only; git ls-files --others --exclude-standard; } | sort -u)
  MODEL="sonnet"
  if echo "$CHANGED_FILES" | grep -qE ...; then MODEL="opus"; fi

This must be replaced with classifier invocation per the contract in dso-ofdr.

Per the story note (dso-9ltc integration): Step 4 must change from dispatching code-review-dispatch.md into a general-purpose agent to dispatching the classifier-selected named agent with per-review context only (diff path, working directory, diff stat, issue context).

## Step 3 Replacement

Replace the grep-based model block with:

```bash
# Run complexity classifier to determine review tier
CLASSIFIER="${CLAUDE_PLUGIN_ROOT}/scripts/review-complexity-classifier.sh"
CLASSIFIER_OUTPUT=$(bash "$CLASSIFIER" 2>/dev/null) || CLASSIFIER_EXIT=$?
if [[ "${CLASSIFIER_EXIT:-0}" -ne 0 ]] || ! echo "$CLASSIFIER_OUTPUT" | python3 -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null; then
    # Classifier failed — default to standard tier per contract dso-ofdr
    REVIEW_TIER="standard"
    REVIEW_AGENT="dso:code-reviewer-standard"
else
    REVIEW_TIER=$(echo "$CLASSIFIER_OUTPUT" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["selected_tier"])')
    case "$REVIEW_TIER" in
        light)    REVIEW_AGENT="dso:code-reviewer-light" ;;
        standard) REVIEW_AGENT="dso:code-reviewer-standard" ;;
        deep)     REVIEW_AGENT="dso:code-reviewer-deep-correctness" ;;  # Deep multi-reviewer (w21-txt8)
        *)        REVIEW_TIER="standard"; REVIEW_AGENT="dso:code-reviewer-standard" ;;
    esac
fi
echo "REVIEW_TIER=$REVIEW_TIER REVIEW_AGENT=$REVIEW_AGENT"
```

## Step 4 Replacement

Replace the general-purpose agent dispatch with named agent dispatch:

```
Task tool:
  subagent_type: "{REVIEW_AGENT from Step 3}"
  description: "Review code changes"
  prompt: <per-review context only: diff_path, working_directory, diff_stat, issue_context>
```

Remove the code-review-dispatch.md template loading (the stable review procedure is in each agent's system prompt per dso-9ltc). Pass only: DIFF_FILE path, STAT_FILE content, REPO_ROOT, issue context. Preserve the NO-FIX RULE and NEVER set isolation: worktree guidance.

## Deep Tier Note

Deep tier dispatch (w21-txt8 scope) is handled by dispatching dso:code-reviewer-deep-correctness for now with a comment noting full parallel dispatch is in w21-txt8.

## TDD Requirement

Integration test is written in dso-4mdr (test-review-workflow-classifier-dispatch.sh). Run those tests first to confirm RED, then apply this change, then confirm GREEN.

## Implementation Steps

1. Confirm RED: bash tests/hooks/test-review-workflow-classifier-dispatch.sh shows FAIL
2. Open plugins/dso/docs/workflows/REVIEW-WORKFLOW.md
3. Replace Step 3 grep block with classifier invocation (per above)
4. Replace Step 4 dispatch with named agent dispatch (per above)
5. Remove the code-review-dispatch.md template loading section from Step 4 instruction text
6. Run integration tests to confirm GREEN

## Acceptance Criteria

- [ ] `bash tests/run-all.sh` passes (exit 0)
  Verify: REPO_ROOT=$(git rev-parse --show-toplevel) && bash "$REPO_ROOT/tests/run-all.sh"
- [ ] `ruff check plugins/dso/scripts/*.py tests/**/*.py` passes (exit 0)
  Verify: REPO_ROOT=$(git rev-parse --show-toplevel) && ruff check plugins/dso/scripts/*.py tests/**/*.py
- [ ] `ruff format --check plugins/dso/scripts/*.py tests/**/*.py` passes (exit 0)
  Verify: REPO_ROOT=$(git rev-parse --show-toplevel) && ruff format --check plugins/dso/scripts/*.py tests/**/*.py
- [ ] Integration tests from dso-4mdr pass (GREEN)
  Verify: REPO_ROOT=$(git rev-parse --show-toplevel) && bash "$REPO_ROOT/tests/hooks/test-review-workflow-classifier-dispatch.sh" 2>&1 | grep -q 'FAILED: 0'
- [ ] REVIEW-WORKFLOW.md Step 3 no longer contains grep-based model selection
  Verify: grep -v 'removed\|old\|#' $(git rev-parse --show-toplevel)/plugins/dso/docs/workflows/REVIEW-WORKFLOW.md | grep -qv 'MODEL="sonnet"'
- [ ] REVIEW-WORKFLOW.md Step 3 references classifier script
  Verify: grep -q 'review-complexity-classifier.sh' $(git rev-parse --show-toplevel)/plugins/dso/docs/workflows/REVIEW-WORKFLOW.md
- [ ] REVIEW-WORKFLOW.md Step 4 references named agent dispatch (subagent_type uses REVIEW_AGENT variable)
  Verify: grep -q 'REVIEW_AGENT' $(git rev-parse --show-toplevel)/plugins/dso/docs/workflows/REVIEW-WORKFLOW.md
- [ ] Classifier failure fallback to standard tier is present in Step 3 code block
  Verify: grep -q 'CLASSIFIER_EXIT' $(git rev-parse --show-toplevel)/plugins/dso/docs/workflows/REVIEW-WORKFLOW.md && grep -q 'standard' $(git rev-parse --show-toplevel)/plugins/dso/docs/workflows/REVIEW-WORKFLOW.md


## Notes

**2026-03-22T16:56:22Z**

CHECKPOINT 1/6: Task context loaded ✓

**2026-03-22T16:56:36Z**

CHECKPOINT 2/6: Code patterns understood ✓

**2026-03-22T16:56:54Z**

CHECKPOINT 3/6: Tests written ✓

**2026-03-22T16:58:46Z**

CHECKPOINT 4/6: Implementation complete ✓

**2026-03-22T16:58:56Z**

CHECKPOINT 5/6: Validation passed ✓

**2026-03-22T17:01:45Z**

CHECKPOINT 6/6: Done ✓
