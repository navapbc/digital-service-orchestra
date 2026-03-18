---
id: dso-wo1i
status: open
deps: []
links: []
created: 2026-03-18T02:38:16Z
type: story
priority: 1
assignee: Joe Oakhart
parent: dso-8qvu
---
# As a DSO contributor, I can run scripts/check-skill-refs.sh to detect unqualified DSO skill references in workflow files

## What
Create `scripts/check-skill-refs.sh` — a linter that scans in-scope files for unqualified DSO skill references and exits non-zero when any are found.

## Why
When a workflow file references `/review` or `/sprint`, it is impossible to tell by inspection whether it targets a DSO skill or a command from another provider. A CI-enforced linter makes ownership self-documenting and prevents regressions after the bulk qualification in the companion story.

## Scope
IN:
- `scripts/check-skill-refs.sh` — new script
- `tests/scripts/test-check-skill-refs.sh` — new test file (RED/GREEN + 3 negative cases)

OUT:
- Adding `check-skill-refs.sh` to `scripts/validate.sh` — deferred to the qualify story (dso-0isl) so the fatal check is only registered after the codebase is clean
- Bulk-rewriting existing files — handled by dso-0isl

## Definition
An 'unqualified reference' is `/<skill-name>` not prefixed with `dso:` and not inside a URL (not preceded by `://`). Qualified form: `/dso:<skill-name>`.

Canonical skill list: sprint, commit, review, end, tdd-workflow, implementation-plan, preplanning, debug-everything, brainstorm, plan-review, interface-contracts, resolve-conflicts, retro, roadmap, oscillation-check, design-onboarding, design-review, ui-discover, dev-onboarding, validate-work, tickets-health, playwright-debug, dryrun, quick-ref, fix-cascade-recovery.

In-scope file set: all files under `skills/`, `docs/`, `hooks/`, `commands/` (recursively, no symlinks), plus `CLAUDE.md`.

## Done Definitions
- When this story is complete, `scripts/check-skill-refs.sh` exits non-zero when any in-scope file contains an unqualified reference to any skill in the canonical list
  <- Satisfies: "check-skill-refs.sh exits non-zero on unqualified ref"
- When this story is complete, `scripts/check-skill-refs.sh` exits 0 on a clean file set
  <- Satisfies: "exits 0 when clean"
- When this story is complete, `tests/scripts/test-check-skill-refs.sh` verifies: (a) exit non-zero on unqualified ref (RED), (b) exit 0 after qualification (GREEN), (c) URL negative case not flagged, (d) already-qualified `/dso:sprint` not flagged, (e) hyphenated `/review-gate` not flagged
  <- Satisfies: test specification

## Considerations
- [Testing] Test fixtures must be isolated temp files — not real codebase files — to avoid false positives from the test running against itself
- [Maintainability] Canonical skill list is hardcoded in the script — adding a skill requires updating the script
- [Shared State] The canonical skill list and match pattern must be defined in a single shared source (e.g., a variable) that both `check-skill-refs.sh` and `qualify-skill-refs.sh` (dso-0isl) consume, to prevent drift between detection and rewriting

## ACCEPTANCE CRITERIA
- Verify: `test -f scripts/check-skill-refs.sh`
- Verify: `bash scripts/check-skill-refs.sh; [ $? -ne 0 ]` (exits non-zero on current unqualified codebase)
- Verify: `bash tests/scripts/test-check-skill-refs.sh` exits 0 (all 5 test cases pass)
- Verify: `grep -c "PASS\|FAIL\|assert\|check" tests/scripts/test-check-skill-refs.sh` >= 5

## File Impact
### Files to create
- `scripts/check-skill-refs.sh`
- `tests/scripts/test-check-skill-refs.sh`

## Notes

<!-- note-id: mtobdu2t -->
<!-- timestamp: 2026-03-18T02:42:24Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

COMPLEXITY_CLASSIFICATION: COMPLEX
