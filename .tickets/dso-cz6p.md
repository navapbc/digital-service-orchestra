---
id: dso-cz6p
status: open
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
