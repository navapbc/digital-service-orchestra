---
id: w22-4mgj
status: closed
deps: []
links: []
created: 2026-03-22T20:02:32Z
type: task
priority: 2
assignee: Joe Oakhart
parent: w21-nv42
---
# Create large-diff-splitting-guide.md with commit-splitting guidance

Create `plugins/dso/docs/workflows/prompts/large-diff-splitting-guide.md` with actionable guidance for splitting oversized commits. This file is referenced by the rejection message in `REVIEW-WORKFLOW.md` when a diff exceeds 600 scorable lines.

**Content requirements** (per story done definition):
- Guidance on splitting by concern (each commit has one semantic purpose)
- Guidance on splitting by layer (data model → service → API → UI)
- Guidance on keeping tests with their code (test and impl in same commit)
- Common anti-patterns to avoid (giant "feature complete" commits, splitting test from implementation)
- Practical git commands for interactive staging: `git add -p`, `git reset HEAD~1 --soft`
- What counts as "scorable lines" and what is exempt (test files, generated files, migrations, lock files)
- Brief explanation of why the threshold exists (reviewer context exhaustion)

**File location**: `plugins/dso/docs/workflows/prompts/large-diff-splitting-guide.md`
- Place alongside other prompt files in the same directory
- Follow the style of existing prompt files in that directory (Markdown with ## headers)

**TDD Requirement**: TDD exemption — static documentation asset (unit exemption criterion 3: static assets with no conditional logic and no executable assertion). Verification is file existence check only.

**Files**:
- `plugins/dso/docs/workflows/prompts/large-diff-splitting-guide.md` (Create)

## ACCEPTANCE CRITERIA

- [ ] `bash tests/run-all.sh` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && bash tests/run-all.sh
- [ ] `ruff check plugins/dso/scripts/*.py tests/**/*.py` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff check plugins/dso/scripts/*.py tests/**/*.py
- [ ] `ruff format --check plugins/dso/scripts/*.py tests/**/*.py` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff format --check plugins/dso/scripts/*.py tests/**/*.py
- [ ] File `plugins/dso/docs/workflows/prompts/large-diff-splitting-guide.md` exists
  Verify: test -f $(git rev-parse --show-toplevel)/plugins/dso/docs/workflows/prompts/large-diff-splitting-guide.md
- [ ] Guide contains section on splitting by concern
  Verify: grep -qi "concern\|semantic\|purpose" $(git rev-parse --show-toplevel)/plugins/dso/docs/workflows/prompts/large-diff-splitting-guide.md
- [ ] Guide contains section on splitting by layer
  Verify: grep -qi "layer\|data model\|service\|API" $(git rev-parse --show-toplevel)/plugins/dso/docs/workflows/prompts/large-diff-splitting-guide.md
- [ ] Guide contains guidance on keeping tests with code
  Verify: grep -qi "test.*code\|code.*test\|same commit" $(git rev-parse --show-toplevel)/plugins/dso/docs/workflows/prompts/large-diff-splitting-guide.md
- [ ] Guide explains what is exempt (generated code, test-only, migrations)
  Verify: grep -qi "exempt\|generated\|migration\|test-only\|lock file" $(git rev-parse --show-toplevel)/plugins/dso/docs/workflows/prompts/large-diff-splitting-guide.md

## Notes

**2026-03-22T20:11:13Z**

CHECKPOINT 1/6: Task context loaded ✓

**2026-03-22T20:11:26Z**

CHECKPOINT 2/6: Code patterns understood ✓

**2026-03-22T20:11:30Z**

CHECKPOINT 3/6: Tests written (none required) ✓

**2026-03-22T20:12:10Z**

CHECKPOINT 4/6: Implementation complete ✓

**2026-03-22T20:46:15Z**

CHECKPOINT 5/6: Validation passed ✓

**2026-03-22T20:46:21Z**

CHECKPOINT 6/6: Done ✓

**2026-03-22T21:02:03Z**

CHECKPOINT 6/6: Done ✓ — Files: plugins/dso/docs/workflows/prompts/large-diff-splitting-guide.md (created). Tests: pass.
