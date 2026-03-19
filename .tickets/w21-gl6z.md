---
id: w21-gl6z
status: closed
deps: [w21-jndb]
links: []
created: 2026-03-19T01:53:50Z
type: task
priority: 2
assignee: Joe Oakhart
parent: w21-t1xp
---
# Update /dso:project-setup Skill to Prompt for monitoring.tool_errors

MODIFY the EXISTING file plugins/dso/skills/project-setup/SKILL.md (this file already exists on the filesystem — this task MODIFIES it, does not create it).

Add a yes/no prompt in the interactive configuration step (Step 3) for monitoring.tool_errors. Example prompt text to add:

  "Enable tool error monitoring and auto-ticket creation? (y/N, default: N): "
  If yes: write monitoring.tool_errors=true to the project's workflow-config.conf
  If no (default): omit the key entirely (safe-off default)

This is a Markdown skill description file — it documents wizard behavior for the LLM agent. It is not executable code.

TDD EXEMPTION: Criterion 1 (no conditional logic — Markdown skill file is static reference text) AND Criterion 3 (static Markdown asset where no executable assertion is possible).

## Acceptance Criteria

- [ ] File exists (confirming it was modified, not created fresh)
  Verify: test -f plugins/dso/skills/project-setup/SKILL.md
- [ ] File contains reference to monitoring.tool_errors
  Verify: grep -iq 'monitoring\.tool_errors' plugins/dso/skills/project-setup/SKILL.md
- [ ] File contains yes/no prompt language for tool error monitoring
  Verify: grep -iE 'monitoring\.tool_errors' plugins/dso/skills/project-setup/SKILL.md | grep -iE 'y/N|yes.no|enable|prompt'
- [ ] File documents the default-omit behavior
  Verify: grep -iE 'default.*omit|omit.*default|default.*false|leave.*out|default.*N' plugins/dso/skills/project-setup/SKILL.md

