---
id: dso-6dp5
status: in_progress
deps: 
  - dso-r2es
links: []
created: 2026-03-19T23:45:00Z
type: story
priority: 2
assignee: Joe Oakhart
parent: dso-2cy8
---
# As a DSO adopter, each optional dependency is prompted individually with functionality explanation

## Description

**What**: Replace the single "show install instructions?" question with individual per-dependency prompts. Each question explains what functionality is unavailable without that dependency. Dependencies already detected as installed are skipped entirely (no prompt shown).
**Why**: Users need to make informed per-dependency decisions. Bundling them hides the tradeoffs, and offering to install something already present is confusing.
**Scope**:
- IN: Individual prompts for acli (Jira CLI integration), PyYAML (legacy YAML config support), pre-commit (git hook management), and any other optional dependencies. Skip prompt for already-installed deps.
- OUT: Required dependencies (handled by dso-setup.sh prerequisite checks)

## Done Definitions

- When this story is complete, each optional dependency is prompted as an individual question with an explanation of what functionality is unavailable without it
  ← Satisfies: "Each optional dependency is prompted individually with an explanation of what functionality is unavailable without it"
- When this story is complete, dependencies already detected as installed are not prompted for installation
  ← Satisfies: "dependencies already installed are not offered for installation"
- When this story is complete, unit tests written and passing for all new or modified logic

## Considerations

- [Maintainability] Depends on detection script output for installed dependency status from dso-r2es
- [UX] acli prompt should be skipped if user declined Jira integration earlier in the wizard — check detection output or wizard state for Jira indicators before prompting

## Escalation Policy

**Escalation policy**: Escalate to the user whenever you do not have high confidence in your understanding of the work, approach, or intent. "High confidence" means clear evidence from the codebase or ticket context — not inference or reasonable assumption. When in doubt, stop and ask rather than guess.

## ACCEPTANCE CRITERIA

- [ ] Each dependency has an individual AskUserQuestion prompt in SKILL.md
  Verify: grep -c "AskUserQuestion.*dependency\|AskUserQuestion.*install\|AskUserQuestion.*acli\|AskUserQuestion.*PyYAML\|AskUserQuestion.*pre-commit" plugins/dso/skills/project-setup/SKILL.md | awk '{exit ($1 < 2)}'
- [ ] Already-installed dependencies are skipped (detection-based)
  Verify: grep -q "already.*installed\|skip.*installed\|detected.*installed" plugins/dso/skills/project-setup/SKILL.md
- [ ] Each prompt explains what functionality is unavailable without the dependency
  Verify: grep -c "without.*functionality\|required for\|enables\|provides" plugins/dso/skills/project-setup/SKILL.md | awk '{exit ($1 < 2)}'
- [ ] Tests verify per-dependency prompt flow
  Verify: test -f tests/skills/test-project-setup-dependencies.sh || test -f tests/skills/test_project_setup_deps.py

## Notes

<!-- note-id: wjha60y0 -->
<!-- timestamp: 2026-03-20T01:19:03Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 1/6: Task context loaded ✓

<!-- note-id: 5g7s86u9 -->
<!-- timestamp: 2026-03-20T01:19:42Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 2/6: Code patterns understood ✓ — SKILL.md optional deps section at lines 204-212, test pattern from test-project-setup-commands-format.sh, assert.sh library available

<!-- note-id: fcgcuhtp -->
<!-- timestamp: 2026-03-20T01:20:36Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 3/6: Tests written ✓ — 10 tests in tests/skills/test-project-setup-dependencies.sh, 7 failing (RED) as expected

<!-- note-id: 3jg9lxq6 -->
<!-- timestamp: 2026-03-20T01:20:45Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 3/6: Tests written ✓

<!-- note-id: m9y7w133 -->
<!-- timestamp: 2026-03-20T01:23:43Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 4/6: Implementation complete ✓ — replaced bundled optional deps question with 3 individual AskUserQuestion prompts (acli, PyYAML, pre-commit) each with functionality explanation and skip-if-installed logic

<!-- note-id: 3rf9610u -->
<!-- timestamp: 2026-03-20T01:23:56Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 5/6: Validation passed ✓ — 11/11 dep tests pass, 13/13 commands-format tests pass, all 4 AC patterns verified

<!-- note-id: 1rynbduk -->
<!-- timestamp: 2026-03-20T01:24:04Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 6/6: Done ✓ — AC1 PASS (3 individual AskUserQuestion prompts), AC2 PASS (skip-if-installed), AC3 PASS (4 functionality explanations), AC4 PASS (test file exists)
