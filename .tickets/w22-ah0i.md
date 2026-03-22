---
id: w22-ah0i
status: in_progress
deps: []
links: []
created: 2026-03-22T19:58:56Z
type: task
priority: 2
assignee: Joe Oakhart
parent: w21-nv42
---
# Contract: classifier-size-output signal emit/parse interface

Create contract document at `plugins/dso/docs/contracts/classifier-size-output.md` defining the interface between `review-complexity-classifier.sh` (emitter) and `REVIEW-WORKFLOW.md` (parser) for diff size threshold fields.

Contract fields to document:
- `diff_size_lines` (integer): count of added lines in non-test, non-generated source files
- `size_action` (string: `none` | `upgrade` | `reject`): threshold determination result
  - `none`: < 300 scorable lines; proceed normally
  - `upgrade`: 300–599 scorable lines; caller must upgrade model to opus at current tier's scope
  - `reject`: ≥ 600 scorable lines; caller must output rejection message referencing `large-diff-splitting-guide.md`
- `is_merge_commit` (boolean): true when MERGE_HEAD is present and valid; size limits do not apply when true

The contract document must include: Signal Name, Emitter, Parser, Fields table (with types and required/optional), Example JSON payload, and the re-review exemption rule (size limits apply only to initial review dispatch, not re-review passes).

**TDD Requirement**: TDD exemption — static document asset only (unit exemption criterion 3: static assets with no executable assertion). This task creates a Markdown contract document with no branching logic.

**File**: `plugins/dso/docs/contracts/classifier-size-output.md` (Create)

## ACCEPTANCE CRITERIA

- [ ] `bash tests/run-all.sh` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && bash tests/run-all.sh
- [ ] `ruff check plugins/dso/scripts/*.py tests/**/*.py` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff check plugins/dso/scripts/*.py tests/**/*.py
- [ ] `ruff format --check plugins/dso/scripts/*.py tests/**/*.py` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff format --check plugins/dso/scripts/*.py tests/**/*.py
- [ ] Contract document `plugins/dso/docs/contracts/classifier-size-output.md` exists
  Verify: test -f $(git rev-parse --show-toplevel)/plugins/dso/docs/contracts/classifier-size-output.md
- [ ] Contract document includes `diff_size_lines`, `size_action`, and `is_merge_commit` fields
  Verify: grep -q "diff_size_lines" $(git rev-parse --show-toplevel)/plugins/dso/docs/contracts/classifier-size-output.md && grep -q "size_action" $(git rev-parse --show-toplevel)/plugins/dso/docs/contracts/classifier-size-output.md && grep -q "is_merge_commit" $(git rev-parse --show-toplevel)/plugins/dso/docs/contracts/classifier-size-output.md
- [ ] Contract document includes re-review exemption rule (size limits only apply to initial dispatch)
  Verify: grep -q "re-review\|initial\|resolution" $(git rev-parse --show-toplevel)/plugins/dso/docs/contracts/classifier-size-output.md
- [ ] Contract document includes example JSON payload
  Verify: grep -q "diff_size_lines" $(git rev-parse --show-toplevel)/plugins/dso/docs/contracts/classifier-size-output.md && grep -q "{" $(git rev-parse --show-toplevel)/plugins/dso/docs/contracts/classifier-size-output.md

## Notes

**2026-03-22T20:11:07Z**

CHECKPOINT 1/6: Task context loaded ✓

**2026-03-22T20:11:22Z**

CHECKPOINT 2/6: Code patterns understood ✓

**2026-03-22T20:11:26Z**

CHECKPOINT 3/6: Tests written (none required) ✓

**2026-03-22T20:11:58Z**

CHECKPOINT 4/6: Implementation complete ✓

**2026-03-22T20:28:09Z**

CHECKPOINT 5/6: Validation passed ✓

**2026-03-22T20:28:09Z**

CHECKPOINT 6/6: Done ✓

**2026-03-22T21:02:03Z**

CHECKPOINT 6/6: Done ✓ — Files: plugins/dso/docs/contracts/classifier-size-output.md (created). Tests: pass.
