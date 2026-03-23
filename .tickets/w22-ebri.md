---
id: w22-ebri
status: closed
deps: []
links: []
created: 2026-03-22T17:46:05Z
type: task
parent: w21-nv42  # As a DSO practitioner, oversized diffs are rejected with actionable guidance
priority: 2
assignee: Joe Oakhart
---
# Create plugins/dso/docs/prompts/large-diff-splitting-guide.md

Create the new file plugins/dso/docs/prompts/large-diff-splitting-guide.md with guidance on splitting large commits into reviewable units.

Unit Test Exemption Justification:
(1) The file has no conditional logic — it is static documentation content.
(2) Any test would only detect file existence (change-detector test), not behavioral correctness.
(3) The file is infrastructure-boundary-only — it is a static reference document with no business logic.

Content outline for large-diff-splitting-guide.md:

# Large Diff Splitting Guide

## Why Split?

Explain: reviewer context limits, review quality degrades above 600 lines, smaller commits are easier to review and revert.

## Splitting Strategies

### 1. Split by Concern
- Each commit should have exactly one reason to change
- If you're fixing a bug AND refactoring, split into two commits
- Test: can you describe the commit in one sentence without 'and'?

### 2. Split by Layer
- Data model changes → one commit
- Service/business logic → next commit
- API/route layer → next commit
- UI/frontend → final commit
- Each layer commit must be independently green

### 3. Keep Tests with Code
- Test code must travel with the source code it tests
- Never split a feature from its unit tests across commits
- RED test commit followed immediately by GREEN implementation commit is fine

### 4. Generated Code Handling
- Never mix generated code (migrations, lock files, protobuf) with hand-written code in same commit
- Regenerate lockfiles in a dedicated 'chore: update dependencies' commit

## Quick Checklist

- [ ] Each commit passes tests independently
- [ ] Commit message is one sentence without 'and'/'also'/'plus'
- [ ] Generated files are in separate commits
- [ ] Tests travel with the source they test

## Examples

Include concrete examples of before/after splitting for a common scenario (e.g., feature + tests + migration → 3 separate commits).

## Files Modified Note

The file must exist at: plugins/dso/docs/prompts/large-diff-splitting-guide.md
(The existing plugins/dso/docs/workflows/prompts/ is for workflow dispatch prompts; this is a user-facing reference guide, hence plugins/dso/docs/prompts/)


## ACCEPTANCE CRITERIA

- [ ] bash tests/run-all.sh passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && bash tests/run-all.sh
- [ ] ruff check passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff check plugins/dso/scripts/*.py tests/**/*.py
- [ ] ruff format --check passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff format --check plugins/dso/scripts/*.py tests/**/*.py
- [ ] File plugins/dso/docs/prompts/large-diff-splitting-guide.md exists
  Verify: test -f $(git rev-parse --show-toplevel)/plugins/dso/docs/prompts/large-diff-splitting-guide.md
- [ ] Guide contains section on splitting by concern
  Verify: grep -qi 'concern\|single reason\|one commit' $(git rev-parse --show-toplevel)/plugins/dso/docs/prompts/large-diff-splitting-guide.md
- [ ] Guide contains section on splitting by layer
  Verify: grep -qi 'layer\|data model\|service\|API\|route' $(git rev-parse --show-toplevel)/plugins/dso/docs/prompts/large-diff-splitting-guide.md
- [ ] Guide contains guidance on keeping tests with code
  Verify: grep -qi 'test.*code\|unit test.*commit' $(git rev-parse --show-toplevel)/plugins/dso/docs/prompts/large-diff-splitting-guide.md
- [ ] Guide contains section on generated code handling
  Verify: grep -qi 'generated\|migration\|lock file' $(git rev-parse --show-toplevel)/plugins/dso/docs/prompts/large-diff-splitting-guide.md
- [ ] plugins/dso/docs/prompts/ directory exists (create it for this file)
  Verify: test -d $(git rev-parse --show-toplevel)/plugins/dso/docs/prompts/
