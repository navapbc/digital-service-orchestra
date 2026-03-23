---
id: dso-0cjl
status: closed
deps: []
links: []
created: 2026-03-18T04:37:01Z
type: story
priority: 2
assignee: Joe Oakhart
parent: dso-igoj
---
# Create dso:project-setup skill: call dso-setup.sh, interactive wizard, workflow-config.conf generation

As a new engineer, I want to run `/dso:project-setup` and be guided through a complete DSO configuration so I can onboard any project without tribal knowledge.

## Done Definition

- `skills/project-setup/SKILL.md` created and invokable as `/dso:project-setup`
- Skill calls `dso-setup.sh` first for mechanical setup, then proceeds to interactive wizard
- Skill handles `dso-setup.sh` exit codes explicitly:
  - Exit 1 (fatal): abort with a clear error message; do not proceed to wizard
  - Exit 2 (warnings-only): surface warnings to the user, then continue to wizard
  - Exit 0 (success): proceed normally
- Interactive wizard copies and customizes DSO templates, generates `workflow-config.conf` with stack-detected defaults
- **Wizard derives its key list and defaults from an authoritative source** (e.g., annotated template or schema file) — keys must not be hardcoded inline in the skill
- Skill is invokable before any project config exists (requires only `$CLAUDE_PLUGIN_ROOT`)
- Optional dep installation (acli, PyYAML) offered but never blocks setup
- `scripts/check-skill-refs.sh` exits 0 on the new skill file

## Escalation Policy

**If at any point you lack high confidence in your understanding of the existing project setup — e.g., you are unsure how the skill should interact with dso-setup.sh exit codes, what the wizard flow should look like for a given stack, or which config keys are authoritative — stop and ask the user before implementing. Err on the side of guidance over assumption. An incorrect setup skill will propagate misconfiguration to every project that uses it.**

