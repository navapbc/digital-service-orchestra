---
id: dso-cz6p
status: closed
deps: 
  - dso-gfl9
  - dso-6576
  - dso-bzvu
  - dso-6dp5
  - dso-jvjw
  - dso-48fu
links: []
created: 2026-03-19T23:45:00Z
type: story
priority: 3
assignee: Joe Oakhart
parent: dso-2cy8
---
# Update project docs to reflect improved project-setup wizard

## Description

**What**: Update CLAUDE.md, CONFIGURATION-REFERENCE.md, and INSTALL.md to reflect the new wizard flow, consolidated ci.* config, detection-aware prompts, and smart template handling.
**Why**: Existing docs reference the old wizard behavior (batch questions, blind file copies, separate merge.ci_workflow_name). Future agents and users need accurate documentation.
**Scope**:
- IN: Update CLAUDE.md (quick reference, architecture section for ci.* consolidation), CONFIGURATION-REFERENCE.md (ci.workflow_name, deprecate merge.ci_workflow_name), INSTALL.md (revised setup instructions)
- OUT: New documentation files (not creating new docs)

## Done Definitions

- When this story is complete, CLAUDE.md reflects the consolidated ci.* namespace and updated project-setup references
  ← Satisfies: epic success criteria (accurate documentation)
- When this story is complete, CONFIGURATION-REFERENCE.md documents ci.workflow_name and marks merge.ci_workflow_name as deprecated with fallback behavior
  ← Satisfies: epic success criteria (accurate documentation)

## Escalation Policy

**Escalation policy**: Escalate to the user whenever you do not have high confidence in your understanding of the work, approach, or intent. "High confidence" means clear evidence from the codebase or ticket context — not inference or reasonable assumption. When in doubt, stop and ask rather than guess.

## Notes

**2026-03-20T00:55:23Z**

COMPLEXITY_CLASSIFICATION: COMPLEX

## ACCEPTANCE CRITERIA

- [ ] CLAUDE.md references consolidated ci.* namespace
  Verify: grep -q "ci.workflow_name\|ci\.\*" CLAUDE.md
- [ ] CONFIGURATION-REFERENCE.md documents ci.workflow_name and deprecates merge.ci_workflow_name
  Verify: grep -q "ci.workflow_name" plugins/dso/docs/CONFIGURATION-REFERENCE.md && grep -qi "deprecat.*merge.ci_workflow_name" plugins/dso/docs/CONFIGURATION-REFERENCE.md
- [ ] INSTALL.md reflects updated setup instructions
  Verify: grep -q "project-setup\|dso:project-setup" plugins/dso/docs/INSTALL.md

<!-- note-id: gcc0h03a -->
<!-- timestamp: 2026-03-20T01:38:04Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 1/6: Task context loaded ✓

<!-- note-id: s69r8zt2 -->
<!-- timestamp: 2026-03-20T01:39:12Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 2/6: Code patterns understood ✓ — ci.workflow_name is the new consolidated key (preferred); merge.ci_workflow_name is deprecated with fallback in merge-to-main.sh; project-setup wizard now exists as /dso:project-setup skill

<!-- note-id: tnx8x0ea -->
<!-- timestamp: 2026-03-20T01:39:20Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 3/6: Tests written (none required — docs only) ✓

<!-- note-id: d09cmxuf -->
<!-- timestamp: 2026-03-20T01:41:08Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 4/6: Implementation complete ✓ — updated CLAUDE.md (ci.workflow_name ci.* section + project-setup quick ref), CONFIGURATION-REFERENCE.md (ci.workflow_name new entry + merge.ci_workflow_name deprecated), INSTALL.md (project-setup wizard step + ci.workflow_name in key summary)

<!-- note-id: 5q9jj832 -->
<!-- timestamp: 2026-03-20T01:41:20Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 5/6: Validation passed ✓ — check-skill-refs.sh: no unqualified skill refs found

<!-- note-id: 4zh5ybh0 -->
<!-- timestamp: 2026-03-20T01:41:41Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 6/6: Done ✓ — all 3 AC verified: (1) CLAUDE.md ci.workflow_name PASS, (2) CONFIGURATION-REFERENCE.md ci.workflow_name + deprecation PASS, (3) INSTALL.md project-setup PASS
