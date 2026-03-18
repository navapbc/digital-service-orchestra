---
id: dso-bvna
status: open
deps: [dso-1e6j]
links: []
created: 2026-03-17T23:38:36Z
type: story
priority: 2
assignee: Joe Oakhart
parent: dso-4g8u
---
# As a plugin developer, patch version increments automatically on code commits outside of sprint


## Notes

**2026-03-17T23:39:02Z**


**What:** Integrate `scripts/bump-version.sh --patch` into `docs/workflows/COMMIT-WORKFLOW.md` so patch version increments automatically on every code commit made outside of the sprint skill.

**Why:** Automates the most frequent version bump trigger (individual bug fixes and code changes) without adding extra commits or requiring manual intervention.

**Scope:**
- IN: Add a version bump step to COMMIT-WORKFLOW.md that calls `scripts/bump-version.sh --patch` and stages the result before the git commit. Add explicit guidance that this step is skipped when the commit is running within the `/sprint` skill.
- OUT: Changes to commit hooks or shell scripts. Changes to the sprint skill (Story dso-hsuo). Major version bump logic.

**Done Definitions:**
- When complete, `docs/workflows/COMMIT-WORKFLOW.md` includes a step that calls `scripts/bump-version.sh --patch` and stages the modified version file before the git commit is created
  ← Satisfies: "Patch version increments automatically when committing code changes outside of /sprint"
- When complete, the commit workflow includes explicit guidance that the version bump step is skipped when the workflow is executing within the `/sprint` skill context
  ← Satisfies: "The commit workflow includes explicit guidance to skip version bumping when running within /sprint"

**Considerations:**
- [Maintainability] `docs/workflows/COMMIT-WORKFLOW.md` is a protected file (CLAUDE.md rule 20) — user approval required at implementation time before editing


**2026-03-18T00:40:01Z**

CHECKPOINT 1/6: Task context loaded ✓

**2026-03-18T00:40:09Z**

CHECKPOINT 2/6: Code patterns understood ✓

**2026-03-18T00:40:11Z**

CHECKPOINT 3/6: Tests written (none required — docs-only change) ✓

**2026-03-18T00:40:29Z**

CHECKPOINT 4/6: Implementation complete ✓

**2026-03-18T00:40:38Z**

CHECKPOINT 5/6: Validation passed ✓

**2026-03-18T00:40:45Z**

CHECKPOINT 6/6: Done ✓
