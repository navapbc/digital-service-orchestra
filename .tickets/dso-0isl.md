---
id: dso-0isl
status: open
deps: [dso-wo1i]
links: []
created: 2026-03-18T02:38:20Z
type: story
priority: 1
assignee: Joe Oakhart
parent: dso-8qvu
---
# As a DSO contributor, I can run scripts/qualify-skill-refs.sh to bulk-rewrite unqualified DSO skill references across the codebase

## What
Create `scripts/qualify-skill-refs.sh` — a one-shot idempotent bulk rewriter that transforms unqualified `/skill-name` references to `/dso:skill-name` in all in-scope files. Run the script on the codebase to qualify all existing references. Then register `check-skill-refs.sh` in `scripts/validate.sh` as a fatal check (now that the codebase is clean).

## Why
With ~270 unqualified references across 60+ files, namespace ambiguity is the default state. This story makes self-documentation the default by mechanically qualifying every existing reference and establishing a CI gate to prevent regressions.

## Scope
IN:
- `scripts/qualify-skill-refs.sh` — new script
- Running `qualify-skill-refs.sh` on all in-scope files (skills/, docs/, hooks/, commands/ recursively + CLAUDE.md)
- Adding `check-skill-refs.sh` to `scripts/validate.sh` as a fatal check (done after codebase is clean)

OUT:
- Modifying files under `scripts/` with the qualifier — not in the in-scope file set
- Renaming skills or restructuring directories — out of scope per epic definition

## Definition
An 'unqualified reference' is `/<skill-name>` not prefixed with `dso:` and not inside a URL (not preceded by `://`). Canonical skill list: sprint, commit, review, end, tdd-workflow, implementation-plan, preplanning, debug-everything, brainstorm, plan-review, interface-contracts, resolve-conflicts, retro, roadmap, oscillation-check, design-onboarding, design-review, ui-discover, dev-onboarding, validate-work, tickets-health, playwright-debug, dryrun, quick-ref, fix-cascade-recovery.

## Done Definitions
- When this story is complete, `scripts/qualify-skill-refs.sh` rewrites `/sprint` to `/dso:sprint` etc. in all in-scope files
  <- Satisfies: "one-shot bulk rewriter"
- When this story is complete, `qualify-skill-refs.sh` is idempotent (running it twice produces no further changes)
  <- Satisfies: "idempotent (double-run produces no changes)"
- When this story is complete, `/review-gate` and other hyphenated names are not modified (whole-word match only)
  <- Satisfies: "whole-word-match only (e.g. /review-gate not touched)"
- When this story is complete, `check-skill-refs.sh` exits 0 on all in-scope files including CLAUDE.md
  <- Satisfies: "After running qualify-skill-refs.sh, check-skill-refs.sh exits 0 on all in-scope files"
- When this story is complete, `scripts/validate.sh` includes `check-skill-refs.sh` as a fatal check
  <- Satisfies: "check-skill-refs.sh is added to scripts/validate.sh as a fatal check"
- When this story is complete, all skill references in CLAUDE.md use qualified `/dso:` form and `check-skill-refs.sh` exits 0 on it
  <- Satisfies: linter + shared-CLAUDE.md finding from adversarial review

## Considerations
- [Reliability] Must not match skill names in URL context — references preceded by `://` must be skipped
- [Testing] Bulk transformation modifies ~60+ files — verify by running `check-skill-refs.sh` exits 0 after
- [Ordering] The `validate.sh` fatal check integration must happen after `qualify-skill-refs.sh` is run on the codebase — not before, as that would break validate.sh until the codebase is cleaned

## ACCEPTANCE CRITERIA
- Verify: `test -f scripts/qualify-skill-refs.sh`
- Verify: `bash scripts/qualify-skill-refs.sh && bash scripts/check-skill-refs.sh` exits 0
- Verify: `bash scripts/qualify-skill-refs.sh && bash scripts/qualify-skill-refs.sh && bash scripts/check-skill-refs.sh` exits 0 (idempotent double-run)
- Verify: `grep -r '/review-gate' skills/ docs/ hooks/ commands/ CLAUDE.md 2>/dev/null | grep -v 'dso:review'` — `/review-gate` unchanged (no false rewrite)
- Verify: `grep 'check-skill-refs' scripts/validate.sh` — linter registered in validate.sh

## File Impact
### Files to create
- `scripts/qualify-skill-refs.sh`
### Files to modify
- `scripts/validate.sh` — add check-skill-refs.sh fatal check
- All in-scope files with unqualified references (~60+ files across skills/, docs/, hooks/, commands/, CLAUDE.md)
