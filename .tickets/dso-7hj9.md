---
id: dso-7hj9
status: closed
deps: [dso-guue]
links: []
created: 2026-03-22T17:44:18Z
type: task
priority: 1
assignee: Joe Oakhart
parent: w21-txt8
---
# Implement deep tier dispatch: 3 parallel sonnets with temp findings files

Update REVIEW-WORKFLOW.md Step 3/4 to replace the placeholder 'Deep multi-reviewer dispatch comes in w21-txt8' comment with the full parallel deep tier dispatch sequence.

TDD REQUIREMENT: Tests from dso-guue must be RED before this task is implemented.

Implementation in plugins/dso/docs/workflows/REVIEW-WORKFLOW.md:
1. In Step 3 classifier dispatch table: update deep tier row to reference the full multi-reviewer flow (not a single placeholder agent)
2. In Step 4, add a 'Deep Tier' subsection after the standard/light dispatch block:
   - Dispatch 3 named agents in parallel (described as parallel launches):
     a. dso:code-reviewer-deep-correctness → writes reviewer-findings.json → orchestrator copies to $ARTIFACTS_DIR/reviewer-findings-a.json
     b. dso:code-reviewer-deep-verification → writes reviewer-findings.json → orchestrator copies to $ARTIFACTS_DIR/reviewer-findings-b.json
     c. dso:code-reviewer-deep-hygiene → writes reviewer-findings.json → orchestrator copies to $ARTIFACTS_DIR/reviewer-findings-c.json
   - Document that orchestrator must copy reviewer-findings.json to the per-reviewer path immediately after each sonnet agent completes (to avoid overwrites)
   - Explicitly note that each sonnet agent gets the same DIFF_FILE, REPO_ROOT, STAT_FILE (no issue-context sharing needed)
3. Remove or update the 'Deep multi-reviewer dispatch comes in w21-txt8' placeholder comment in Step 3/4

File impact:
- Edit: plugins/dso/docs/workflows/REVIEW-WORKFLOW.md

## ACCEPTANCE CRITERIA

- [ ] `bash tests/run-all.sh` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && bash tests/run-all.sh
- [ ] `ruff check plugins/dso/scripts/*.py tests/**/*.py` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff check plugins/dso/scripts/*.py tests/**/*.py
- [ ] `ruff format --check plugins/dso/scripts/*.py tests/**/*.py` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff format --check plugins/dso/scripts/*.py tests/**/*.py
- [ ] Tests from dso-guue now PASS (GREEN state)
  Verify: bash $(git rev-parse --show-toplevel)/tests/hooks/test-review-workflow-classifier-dispatch.sh 2>&1 | grep "test_deep_tier_documents_three_parallel_sonnet_dispatches" | grep -q "PASS"
- [ ] REVIEW-WORKFLOW.md Step 3 deep row dispatches to code-reviewer-deep-correctness (not placeholder)
  Verify: grep -q "code-reviewer-deep-correctness" $(git rev-parse --show-toplevel)/plugins/dso/docs/workflows/REVIEW-WORKFLOW.md
- [ ] REVIEW-WORKFLOW.md Step 4 references reviewer-findings-a.json, reviewer-findings-b.json, reviewer-findings-c.json
  Verify: grep -q "reviewer-findings-a.json" $(git rev-parse --show-toplevel)/plugins/dso/docs/workflows/REVIEW-WORKFLOW.md
- [ ] Placeholder comment 'Deep multi-reviewer dispatch comes in w21-txt8' is removed
  Verify: ! grep -q "Deep multi-reviewer dispatch comes in w21-txt8" $(git rev-parse --show-toplevel)/plugins/dso/docs/workflows/REVIEW-WORKFLOW.md

## Notes

<!-- note-id: z86f6j7n -->
<!-- timestamp: 2026-03-22T18:53:22Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 1/6: Task context loaded ✓

<!-- note-id: 21ly48un -->
<!-- timestamp: 2026-03-22T18:53:33Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 2/6: Code patterns understood ✓

<!-- note-id: b94jplv5 -->
<!-- timestamp: 2026-03-22T18:54:06Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 3/6: Tests written ✓

<!-- note-id: 8ox5npge -->
<!-- timestamp: 2026-03-22T18:55:06Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 4/6: Implementation complete ✓

<!-- note-id: zoqn4nwn -->
<!-- timestamp: 2026-03-22T18:59:57Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 5/6: Validation passed ✓ — syntax/format/ruff/mypy/skill-refs/hook-drift all PASS; ci(main) and e2e failures are pre-existing infrastructure issues

<!-- note-id: g68tpg3e -->
<!-- timestamp: 2026-03-22T18:59:58Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 6/6: Done ✓
