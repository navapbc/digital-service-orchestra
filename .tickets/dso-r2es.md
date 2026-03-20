---
id: dso-r2es
status: open
deps: []
links: []
created: 2026-03-19T23:45:00Z
type: story
priority: 1
assignee: Joe Oakhart
parent: dso-2cy8
---
# As a DSO adopter, project detection produces structured context for all wizard questions

## Description

**What**: Create a detection script (e.g., `project-detect.sh`) that scans the target project and outputs structured key=value results covering: stack type, Makefile/package.json/Cargo.toml targets, .github/workflows analysis (workflow names, job display names, existing lint/format/test guards), database presence (docker-compose services, Dockerfile, config files), Python version, installed CLI dependencies (acli, PyYAML, pre-commit, shasum), existing file presence (CLAUDE.md, KNOWN-ISSUES.md, .pre-commit-config.yaml, workflow-config.conf), port numbers from project config, and version file candidates.
**Why**: All subsequent wizard questions need detection context to show "exists in project" vs "convention for stack" and to skip prompts for already-installed dependencies.
**Scope**:
- IN: Detection script with structured output, tests for each detection category
- OUT: Wizard question flow (later stories), config file writing, template file operations

## Done Definitions

- When this story is complete, running the detection script against a project produces structured output covering stack, targets, CI workflows, database presence, Python version, installed dependencies, existing files, port numbers, and version file candidates
  ← Satisfies: "Command suggestions indicate whether each target exists in the project or is a standard convention for the detected stack"
- When this story is complete, CI workflow analysis identifies existing lint/format/test guard steps in workflow YAML files
  ← Satisfies: "Existing CI workflows are analyzed for lint/format/test guards before offering to add them"
- When this story is complete, the script detects whether optional dependencies (acli, PyYAML, pre-commit) are already installed
  ← Satisfies: "dependencies already installed are not offered for installation"
- When this story is complete, Python version is auto-detected from pyproject.toml, .python-version, or the python3 binary
  ← Satisfies: "Python version is auto-detected"
- When this story is complete, detection script output schema is documented (field names, types, format) in a header comment or companion doc that downstream stories can reference
  ← Satisfies: cross-story integration contract (adversarial review finding)
- When this story is complete, unit tests written and passing for all new or modified logic

## Considerations

- [Reliability] Detection heuristics (grepping Makefile targets, parsing CI YAML) may produce false positives — output should include confidence indicators and degrade gracefully when detection is uncertain
- [Maintainability] Output schema should be documented and stable — all downstream wizard stories depend on it

## Escalation Policy

**Escalation policy**: Escalate to the user whenever you do not have high confidence in your understanding of the work, approach, or intent. "High confidence" means clear evidence from the codebase or ticket context — not inference or reasonable assumption. When in doubt, stop and ask rather than guess.
