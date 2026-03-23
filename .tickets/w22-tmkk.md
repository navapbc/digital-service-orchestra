---
id: w22-tmkk
status: open
deps: [w22-hwmo, w22-1d6q, w22-ebri]
links: []
created: 2026-03-22T17:45:48Z
type: task
parent: w21-nv42  # As a DSO practitioner, oversized diffs are rejected with actionable guidance
priority: 2
assignee: Joe Oakhart
---
# Update REVIEW-WORKFLOW.md Step 3 to handle size rejection and model override

Update plugins/dso/docs/workflows/REVIEW-WORKFLOW.md Step 3 (Classify Review Tier) to read and act on the new size_rejection and model_override fields from the classifier output.

TDD Requirement: RED tests in tests/hooks/test-review-workflow-classifier-dispatch.sh (created in T3/w22-hwmo) must fail before this task and pass after.

Changes to REVIEW-WORKFLOW.md Step 3:

1. After running classifier and extracting selected_tier, extract new fields:
   SIZE_REJECTION=$(echo "$CLASSIFIER_OUTPUT" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("size_rejection", False))')
   MODEL_OVERRIDE=$(echo "$CLASSIFIER_OUTPUT" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("model_override") or "")')

2. Add size rejection gate (INITIAL REVIEW ONLY — document clearly):
   If SIZE_REJECTION == 'True':
     - Print structured rejection message:
       'DIFF TOO LARGE FOR REVIEW: {line_count} non-test non-generated lines (limit: 600)'
       'Split your commit before requesting review. See: plugins/dso/docs/prompts/large-diff-splitting-guide.md'
     - EXIT the review workflow with a non-success status
     - Caller (/dso:commit, /dso:review) must surface this message to the user
   Document: size rejection applies to initial dispatch only. Re-review passes (Autonomous Resolution Loop) skip this gate.

3. Add model override logic:
   If MODEL_OVERRIDE == 'opus' AND REVIEW_TIER != 'deep':
     - Keep REVIEW_TIER as classifier selected it
     - Override the model to opus for the named agent dispatch in Step 4
     - Add note: 'Diff size exceeds 300 lines — upgrading to opus model for review depth'
     - REVIEW_AGENT remains the same tier-selected agent, but dispatch uses model=opus

4. Update Step 4 dispatch block to use MODEL_OVERRIDE when set:
   Task tool dispatch should include model: 'opus' when MODEL_OVERRIDE is set

5. In the Autonomous Resolution Loop section, add a callout:
   'Size rejection and model override checks in Step 3 are skipped during re-review passes — re-dispatch always uses the original tier's named agent and model.'

Files modified:
- plugins/dso/docs/workflows/REVIEW-WORKFLOW.md

No changes to pre-commit-review-gate.sh (gate does not enforce size limits; enforcement is at review-dispatch time only).


## ACCEPTANCE CRITERIA

- [ ] bash tests/run-all.sh passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && bash tests/run-all.sh
- [ ] ruff check passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff check plugins/dso/scripts/*.py tests/**/*.py
- [ ] ruff format --check passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff format --check plugins/dso/scripts/*.py tests/**/*.py
- [ ] REVIEW-WORKFLOW.md Step 3 references size_rejection field
  Verify: grep -q 'size_rejection' $(git rev-parse --show-toplevel)/plugins/dso/docs/workflows/REVIEW-WORKFLOW.md
- [ ] REVIEW-WORKFLOW.md Step 3 references model_override field
  Verify: grep -q 'model_override' $(git rev-parse --show-toplevel)/plugins/dso/docs/workflows/REVIEW-WORKFLOW.md
- [ ] REVIEW-WORKFLOW.md references large-diff-splitting-guide in rejection message
  Verify: grep -q 'large-diff-splitting-guide' $(git rev-parse --show-toplevel)/plugins/dso/docs/workflows/REVIEW-WORKFLOW.md
- [ ] REVIEW-WORKFLOW.md documents that size rejection is skipped during re-review (Autonomous Resolution Loop)
  Verify: grep -q 'initial.*review\|re-review.*skip\|resolution loop.*size' $(git rev-parse --show-toplevel)/plugins/dso/docs/workflows/REVIEW-WORKFLOW.md
- [ ] Workflow tests GREEN after implementation: bash tests/hooks/test-review-workflow-classifier-dispatch.sh passes
  Verify: bash $(git rev-parse --show-toplevel)/tests/hooks/test-review-workflow-classifier-dispatch.sh
- [ ] RED marker removed from .test-index REVIEW-WORKFLOW.md entry after tests pass
  Verify: grep 'REVIEW-WORKFLOW.md' $(git rev-parse --show-toplevel)/.test-index | grep -qv '\[test_workflow'
- [ ] Size rejection produces a detectable non-zero exit or status variable so callers (COMMIT-WORKFLOW.md) can programmatically detect rejection (not just parse printed text)
  Verify: grep -qE 'exit 1|SIZE_REJECTED|REVIEW_RESULT.*rejected|size_rejection.*exit' $(git rev-parse --show-toplevel)/plugins/dso/docs/workflows/REVIEW-WORKFLOW.md
- [ ] plugins/dso/docs/prompts/large-diff-splitting-guide.md exists (required before being referenced in rejection message — T5/w22-ebri must complete first)
  Verify: test -f $(git rev-parse --show-toplevel)/plugins/dso/docs/prompts/large-diff-splitting-guide.md
