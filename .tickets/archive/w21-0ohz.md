---
id: w21-0ohz
status: closed
deps: []
links: []
created: 2026-03-19T04:53:45Z
type: epic
priority: 2
assignee: Joe Oakhart
---
# Strengthen sprint batch-end guidance with positive directives and a continuation echo


## Notes

**2026-03-19T04:54:14Z**


## Context
After the final batch of an epic, orchestrators sometimes close the epic directly from Phase 6 without entering Phase 7 (validation) or Phase 9 (completion). The root cause: high context load causes the agent to pattern-match "all tasks closed = done" rather than following Step 13's routing. Two lightweight text changes in SKILL.md address this at the decision point itself: (1) a visible callout block at the end of Step 10 that re-surfaces the continuation instruction immediately after commit+push — the moment the agent is most likely to shortcut — and (2) strengthening Step 13's routing bullet to use positive directive language ("Phase 7 is MANDATORY") instead of a passive conditional. A third change moves task closing to a new Step 10a (after merge succeeds), fixing a latent correctness bug where tasks could be marked done against uncommitted code.

## Success Criteria
- Step 10 of SKILL.md ends with a `> **CONTINUE:** ...` blockquote callout — placed after the `merge-to-main.sh` block and before the Step 11 heading — containing: "After `merge-to-main.sh` completes, proceed to Step 11 then Step 13. Do NOT close the epic or invoke `/dso:end-session` here."
- Step 13 of SKILL.md opens its routing list with: "If all tasks are closed → **Phase 7 is MANDATORY** — proceed immediately to Phase 7 (validation)" — affirmative directive, not a conditional.
- A new Step 10a in SKILL.md, inserted between Step 10 and Step 11, specifies that tasks are closed only after `merge-to-main.sh` succeeds; Step 8 is updated to limit it to checkpoint notes only (no task closing).
- The `(project-specific-bug-id)` placeholder in Step 10's CONTROL FLOW WARNING is replaced with a real incident reference or removed.
- A new test file `tests/test-sprint-continuation-guidance.sh` (included in `run-all.sh`) verifies: (a) the `> **CONTINUE:**` callout exists in Step 10 content, after `merge-to-main.sh` and before the Step 11 heading; (b) the word `MANDATORY` appears in Step 13's Phase 7 routing bullet; (c) Step 10a exists as a heading between Steps 10 and 11. `bash tests/run-all.sh` exits 0.
- The next real sprint execution after this epic is merged produces session output showing the orchestrator entering Phase 7 after the final batch rather than jumping directly to `tk close <epic-id>` — verifiable by the user reviewing that session's output.

## Dependencies
dso-l2ct (sprint skill optimization epic) modifies the same Step 10-13 region of SKILL.md. These two epics must not be worked concurrently — complete one before starting the other to prevent merge conflicts.

## Approach
Two targeted text edits to `plugins/dso/skills/sprint/SKILL.md`: add a `> **CONTINUE:**` blockquote at the end of Step 10, and rewrite Step 13's Phase 7 routing bullet with positive directive language. A new Step 10a closes tasks post-merge. A new test script validates all structural properties. No new mechanisms, no new config, no hook changes.

