---
id: dso-hsuo
status: closed
deps: [dso-1e6j]
links: []
created: 2026-03-17T23:38:36Z
type: story
priority: 2
assignee: Joe Oakhart
parent: dso-4g8u
---
# As a plugin developer, minor version increments automatically when a sprint epic completes


## Notes

**2026-03-17T23:39:11Z**


**What:** Add a step to the sprint skill's epic completion sequence that calls `scripts/bump-version.sh --minor` to increment the minor version when an epic finishes.

**Why:** Signals to consumers that a meaningful new capability has been delivered, distinguishing feature-level changes (minor bump) from incremental fixes (patch bump).

**Scope:**
- IN: Add a call to `scripts/bump-version.sh --minor` at the epic completion step of `skills/sprint/SKILL.md`. The bumped version file is staged and included in the epic completion commit.
- OUT: Changes to the commit workflow (Story dso-bvna). Changes to bump-version.sh (Story dso-1e6j). Major version logic.

**Done Definitions:**
- When complete, the sprint skill's epic completion step calls `scripts/bump-version.sh --minor`, incrementing the minor version and resetting patch to 0
  ← Satisfies: "Minor version increments automatically at epic completion during /sprint, resetting patch to 0"

**Considerations:**
- [Maintainability] `skills/sprint/SKILL.md` is a protected file (CLAUDE.md rule 20) — user approval required at implementation time before editing
- [Reliability] The epic completion sequence must stage the bumped version file before the epic completion commit. If the commit step invokes the commit workflow (Story dso-bvna), the sprint-skip guidance must suppress a redundant patch bump in the same commit.


**2026-03-18T00:40:08Z**

CHECKPOINT 1/6: Task context loaded ✓

**2026-03-18T00:40:39Z**

CHECKPOINT 2/6: Code patterns understood ✓ — bump-version.sh --minor increments minor + resets patch to 0; COMMIT-WORKFLOW.md step 3b already has sprint-skip guidance; Phase 9 On Success in SKILL.md is at line 1283-1293

**2026-03-18T00:40:43Z**

CHECKPOINT 3/6: Tests written (none required — docs-only change) ✓

**2026-03-18T00:41:11Z**

CHECKPOINT 4/6: Implementation complete ✓ — Added step 2 in Phase 9 On Success: calls scripts/bump-version.sh --minor, stages with git add -u, explains minor bump precedence over patch, references existing sprint-skip guidance in COMMIT-WORKFLOW.md Step 3b

**2026-03-18T00:41:18Z**

CHECKPOINT 5/6: Validation passed ✓ — Read updated Phase 9 On Success section; guidance matches done definition: bump-version.sh --minor called, increments minor+resets patch, version file staged, sprint-skip note references COMMIT-WORKFLOW.md Step 3b to suppress redundant patch bump

**2026-03-18T00:41:21Z**

CHECKPOINT 6/6: Done ✓ — Sprint skill epic completion step now calls scripts/bump-version.sh --minor (Phase 9 On Success, step 2), incrementing the minor version and resetting patch to 0
