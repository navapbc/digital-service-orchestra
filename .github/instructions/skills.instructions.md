---
applyTo: "plugins/dso/skills/**/SKILL.md"
---

# Skill File Coverage

Coverage areas for skill files:

- Referenced scripts, agent files, and config keys actually exist.
- Skill invocations use the fully-qualified `/dso:<skill-name>` form
  (unqualified refs are CI-blocking).

These files are token-budgeted; verbosity expansions are out of scope.
