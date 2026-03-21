---
id: w22-ond9
status: open
deps: []
links: []
created: 2026-03-21T16:59:29Z
type: story
priority: 2
assignee: Joe Oakhart
parent: w22-anm2
---
# As a platform engineer, I can generate CI workflows for a new project from discovered suites

## Description

**What**: When /dso:project-setup detects no existing CI workflows, generate GitHub Actions YAML from discovered test suites — fast suites in ci.yml (PR trigger), slow suites in ci-slow.yml (push to main trigger). Includes speed_class prompting for unknown suites and YAML validation before writing.
**Why**: Eliminates manual CI template customization for new projects — the generated workflow matches the project's actual test structure.
**Scope**:
- IN: ci.yml generation (fast suites, on: pull_request), ci-slow.yml generation (slow suites, on: push), job template (checkout → setup runtime → run command), job ID derivation from suite name, speed_class prompting for unknown suites (default: slow), non-interactive fallback, YAML validation (actionlint or yaml.safe_load), dogfooding on DSO repo
- OUT: Existing project gap analysis (separate story), config key declaration (Milestone A)

## Done Definitions

- When this story is complete, running /dso:project-setup on a new project with discovered test suites generates ci.yml and ci-slow.yml with correct jobs matching the suites
  ← Satisfies: "setup skill generates a CI workflow with jobs matching the discovered test suites"
- When this story is complete, generated YAML passes actionlint validation before being written to disk
  ← Satisfies: "Generated YAML is validated before writing"
- When this story is complete, running /dso:project-setup on the DSO repo generates CI that passes actionlint
  ← Satisfies: "dogfooding validation"
- Unit tests written and passing for all new or modified logic

## Considerations

- [Security] Suite command strings come from user project — sanitize before embedding in YAML
- [Reliability] Handle edge cases: special characters in suite names, empty suite list, all-unknown speed classes
- [Testing] Interactive vs non-interactive paths need separate test coverage
