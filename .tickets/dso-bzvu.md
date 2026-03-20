---
id: dso-bzvu
status: open
deps: 
  - dso-r2es
links: []
created: 2026-03-19T23:45:00Z
type: story
priority: 2
assignee: Joe Oakhart
parent: dso-2cy8
---
# As a DSO adopter, infrastructure and metadata keys are prompted when project context indicates relevance

## Description

**What**: Using detection script results, prompt for database, infrastructure, and staging keys when the project has indicators (docker-compose with DB service, Dockerfile, staging config). Auto-detect Python version. Infer port numbers from project config (docker-compose port mappings, .env files) and confirm with the user. Provide guidance for infrastructure.required_tools explaining what it controls.
**Why**: These keys are only relevant to projects with certain characteristics — prompting unconditionally wastes time, but omitting them leaves gaps.
**Scope**:
- IN: database.ensure_cmd, database.status_cmd, infrastructure.db_container, infrastructure.required_tools (with guidance), infrastructure.app_port, infrastructure.db_port, staging.url, worktree.python_version — all prompted conditionally based on detection
- OUT: Command configuration (separate story), CI config (separate story)

## Done Definitions

- When this story is complete, database/infrastructure/staging keys are prompted only when project context indicates relevance (e.g., docker-compose with DB service detected)
  ← Satisfies: "database/infrastructure/staging keys ... are prompted when project context indicates they are relevant"
- When this story is complete, Python version is auto-detected and pre-filled
  ← Satisfies: "Python version is auto-detected"
- When this story is complete, port numbers are inferred from project config (docker-compose, .env) and presented to the user for confirmation
  ← Satisfies: "Port numbers are inferred from project config when available and confirmed by the user"
- When this story is complete, the infrastructure.required_tools prompt includes guidance explaining that these are CLI tools DSO checks for at session start, and their absence produces warnings or errors
  ← Satisfies: "infrastructure.required_tools prompt includes guidance on what the setting controls"
- When this story is complete, unit tests written and passing for all new or modified logic

## Considerations

- [Reliability] Port inference from docker-compose may encounter variable substitution (${DB_PORT:-5432}) — should extract the default value
- [Maintainability] Depends on detection script output schema from dso-r2es

## Escalation Policy

**Escalation policy**: Escalate to the user whenever you do not have high confidence in your understanding of the work, approach, or intent. "High confidence" means clear evidence from the codebase or ticket context — not inference or reasonable assumption. When in doubt, stop and ask rather than guess.

## Notes

**2026-03-20T00:37:02Z**

COMPLEXITY_CLASSIFICATION: COMPLEX
