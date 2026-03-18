---
id: dso-gul1
status: closed
deps: []
links: []
created: 2026-03-18T16:39:54Z
type: bug
priority: 3
assignee: Joe Oakhart
parent: dso-ojbb
---
# Fix: exclude .worktree-blackboard.json timestamp churn from review diffs

The `.worktree-blackboard.json` file contains a `batch_id` and `created_at` timestamp that changes every sprint batch. This produces noise in review diffs — the file appears in every batch's review even though the content is purely infrastructure state. Exclude it from review diff capture.

Fix by adding `.worktree-blackboard.json` to the review diff exclusion list in `hooks/lib/review-gate-allowlist.conf` and/or to the pathspec exclusion in `scripts/capture-review-diff.sh`.

## ACCEPTANCE CRITERIA

- [ ] .worktree-blackboard.json is excluded from review diff output
  Verify: echo '{}' > /tmp/test-blackboard-review.json && git -C $(git rev-parse --show-toplevel) diff HEAD -- .worktree-blackboard.json | wc -c | grep -q "^0$" || grep -q "worktree-blackboard" $(git rev-parse --show-toplevel)/hooks/lib/review-gate-allowlist.conf
- [ ] check-skill-refs passes (no unqualified refs introduced)
  Verify: bash $(git rev-parse --show-toplevel)/scripts/check-skill-refs.sh 2>&1 | grep -qv 'FAIL'
- [ ] ruff check passes
  Verify: cd $(git rev-parse --show-toplevel) && ruff check scripts/*.py tests/**/*.py

## Notes

**2026-03-18T16:46:22Z**

CHECKPOINT 1/6: Task context loaded ✓

**2026-03-18T16:46:27Z**

CHECKPOINT 2/6: Code patterns understood ✓

**2026-03-18T16:46:30Z**

CHECKPOINT 3/6: Tests written (none required) ✓

**2026-03-18T16:46:40Z**

CHECKPOINT 4/6: Implementation complete ✓

**2026-03-18T16:51:28Z**

CHECKPOINT 5/6: Validation passed ✓

**2026-03-18T16:51:45Z**

CHECKPOINT 6/6: Done ✓

**2026-03-18T16:59:33Z**

CHECKPOINT 6/6: Done ✓ — Batch 3 complete, review passed.
