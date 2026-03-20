---
id: dso-2cy8
status: in_progress
deps: []
links: []
created: 2026-03-19T23:40:03Z
type: epic
priority: 1
assignee: Joe Oakhart
---
# Improve project-setup wizard: sequential prompts, smart detection, consolidated config


## Notes

<!-- note-id: xo4u8e0k -->
<!-- timestamp: 2026-03-19T23:40:18Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->


## Context
Users running /dso:project-setup for the first time encounter a wizard that asks multiple questions simultaneously, doesn't explain what its suggestions are based on, and offers to install dependencies that may already be present. The wizard also blindly copies template files that could overwrite existing work, doesn't prompt for several useful config keys, and presents a dryrun preview that leaks internal implementation details (script vs skill). These issues make setup confusing and error-prone, especially for projects with existing CI, databases, or pre-commit configuration.

## Success Criteria
- Setup wizard asks one question at a time, using AskUserQuestion where appropriate
- Command suggestions indicate whether each target exists in the project or is a standard convention for the detected stack
- Format settings describe which file extensions and directories are covered by the proposed configuration
- Each optional dependency is prompted individually with an explanation of what functionality is unavailable without it, and dependencies already installed are not offered for installation
- CLAUDE.md and KNOWN-ISSUES.md overwrites produce a warning with an option to supplement instead, without duplicating scaffolding
- version.file_path, tickets.prefix, database/infrastructure/staging keys, and ci.* keys (consolidated from merge.ci_workflow_name) are prompted when project context indicates they are relevant
- CI job names and workflow name are auto-detected from .github/workflows/ and confirmed by the user
- Python version is auto-detected
- Port numbers are inferred from project config when available and confirmed by the user
- Pre-commit config merges hooks into an existing .pre-commit-config.yaml rather than overwriting
- Existing CI workflows are analyzed for lint/format/test guards before offering to add them
- infrastructure.required_tools prompt includes guidance on what the setting controls
- Dryrun preview presents a flat list of outcomes without distinguishing script vs skill operations
- Setup conclusion displays a list of manual commands and environment exports the user still needs to perform

## Approach
Incremental wizard overhaul (Option A): Rewrite the skill Step 3 as a sequential one-question-at-a-time wizard with smart detection layered in. Each question adapts based on what the wizard already knows (stack detection, file scanning, dependency checks). The skill remains a single skill file with the script handling shim installation and the skill handling all user-facing interaction. Consolidate merge.ci_workflow_name into ci.workflow_name. Auto-detect CI jobs, database presence, ports, Python version, and existing dependencies before asking. Pre-commit config and CI workflow analysis happen during detection, not as blind file copies. design.* keys are deferred to /dso:design-onboarding. merge.*, session.*, and checks.* keys are silently defaulted (not prompted during setup).

