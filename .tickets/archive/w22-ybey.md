---
id: w22-ybey
status: closed
deps: []
links: []
created: 2026-03-21T16:59:29Z
type: story
priority: 2
assignee: Joe Oakhart
parent: w22-anm2
---
# As a platform engineer, I can identify and place uncovered suites in my existing CI

## Description

**What**: For projects with existing CI workflows, identify test suites not covered by any CI job and prompt the user to place each one: fast-gate, separate workflow, or skip.
**Why**: Most projects being onboarded already have some CI. They need gap analysis — not a full rewrite — to maximize test coverage.
**Scope**:
- IN: Parse existing .github/workflows/*.yml, match suite commands against step run: values (substring match), prompt for uncovered suites (fast-gate/separate/skip), write placement to dso-config.conf for skip, append job to existing workflow for fast-gate, create new workflow file for separate, non-interactive fallback
- OUT: New project generation (separate story), discovery (Milestone A)

## Done Definitions

- When this story is complete, running /dso:project-setup on a project with existing CI identifies suites not covered by any workflow step
  ← Satisfies: "setup skill identifies test suites not covered by any CI job"
- When this story is complete, selecting "fast-gate" for an uncovered suite adds the job to the existing gating workflow with no further manual steps
  ← Satisfies: "prompts the user to place each one"
- When this story is complete, selecting "skip" records test.suite.<name>.ci_placement=skip in dso-config.conf
  ← Satisfies: "user control over suite placement"
- Unit tests written and passing for all new or modified logic

## Considerations

- [Reliability] Substring matching for coverage detection may miss indirect invocations — document as conservative (reusable uses: treated as uncovered)
- [Testing] Need test matrix for all three placement options plus non-interactive fallback
