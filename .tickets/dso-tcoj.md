---
id: dso-tcoj
status: in_progress
deps: [dso-qzn4]
links: []
created: 2026-03-22T15:16:56Z
type: task
priority: 1
assignee: Joe Oakhart
parent: w21-jtkr
---
# Add review-complexity-classifier.sh to CLAUDE.md rule #20 safeguard files list

Add plugins/dso/scripts/review-complexity-classifier.sh to the CLAUDE.md rule #20 safeguard files list (Never edit safeguard files without user approval).

## Context

Per the epic success criteria: 'The classifier script is added to the safeguard files list in CLAUDE.md rule #20.' This prevents agents from rationalizing modifications to the classifier without user approval.

## Implementation Steps

1. Open CLAUDE.md
2. Find rule #20: 'Never edit safeguard files without user approval — protected: ...'
3. Append 'plugins/dso/scripts/review-complexity-classifier.sh' to the protected list
4. The updated list should read (adding the classifier at the end):
   protected: `plugins/dso/skills/**`, `plugins/dso/hooks/**`, `plugins/dso/docs/workflows/**`, `plugins/dso/scripts/**`, `CLAUDE.md`, `plugins/dso/hooks/lib/review-gate-allowlist.conf`, `plugins/dso/scripts/review-complexity-classifier.sh`

Note: plugins/dso/scripts/** already covers the classifier by glob, but adding it explicitly makes the safeguard visible and unambiguous to agents reading the rule.

## TDD Requirement

No RED test required — this task modifies only a static documentation file with no conditional logic or executable behavior. Exemption: Unit exemption criterion 3 (static assets only — CLAUDE.md is a Markdown documentation file, no executable assertions possible). The classifier's safeguard enforcement is tested by the hook test suite which already covers safeguard file protection.

## Acceptance Criteria

- [ ] `bash tests/run-all.sh` passes (exit 0)
  Verify: REPO_ROOT=$(git rev-parse --show-toplevel) && bash "$REPO_ROOT/tests/run-all.sh"
- [ ] `ruff check plugins/dso/scripts/*.py tests/**/*.py` passes (exit 0)
  Verify: REPO_ROOT=$(git rev-parse --show-toplevel) && ruff check plugins/dso/scripts/*.py tests/**/*.py
- [ ] `ruff format --check plugins/dso/scripts/*.py tests/**/*.py` passes (exit 0)
  Verify: REPO_ROOT=$(git rev-parse --show-toplevel) && ruff format --check plugins/dso/scripts/*.py tests/**/*.py
- [ ] CLAUDE.md rule #20 references review-complexity-classifier.sh explicitly
  Verify: grep -q 'review-complexity-classifier.sh' $(git rev-parse --show-toplevel)/CLAUDE.md


## Notes

**2026-03-22T17:07:56Z**

CHECKPOINT 1/6: Task context loaded ✓

**2026-03-22T17:08:02Z**

CHECKPOINT 2/6: Code patterns understood ✓

**2026-03-22T17:08:03Z**

CHECKPOINT 3/6: Tests written (none required) ✓

**2026-03-22T17:08:19Z**

CHECKPOINT 4/6: Implementation complete ✓

**2026-03-22T17:08:28Z**

CHECKPOINT 5/6: Validation passed ✓

**2026-03-22T17:36:45Z**

CHECKPOINT 6/6: Done ✓ — AC: grep confirms review-complexity-classifier.sh in CLAUDE.md rule #20; ruff format+lint pass; test-doc-migration.sh failure pre-existing (fails on stashed branch without my change)
