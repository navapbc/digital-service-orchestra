# Known Issues and Incident Log

> **Search Tips**: Use Ctrl+F with keywords like "CI", "path", "timeout", "hook", "config", "deploy", "test", "flaky"

> **When to read this file**: Reference when debugging unexpected behavior or understanding why certain rules exist in your project configuration.

> **Workflow**: ALWAYS search this file before debugging (`grep -i "keyword" .claude/docs/KNOWN-ISSUES.md`). After solving a new issue, add it here using the incident format below. If 3+ similar incidents accumulate, propose a rule in your project configuration.

> **Archive**: Resolved/historical incidents can be moved to a `KNOWN-ISSUES-ARCHIVE.md` file. Search there if a pattern recurs.

## Index by Category

<!-- Update this table as you add new incidents. Keep counts and dates current. -->

| Category | Issue Count | Most Recent |
|----------|-------------|-------------|
| [CI/Deployment](#ci-and-deployment) | 1 | YYYY-MM |
| [Paths/Directories](#paths-and-directories) | 1 | YYYY-MM |
| [Testing/Flakiness](#testing-and-flakiness) | 1 | YYYY-MM |

## Quick Reference by Incident ID

<!-- Add a row for each incident. This index enables fast lookup by ID or keyword search. -->

| ID | Title | Category | Keywords |
|----|-------|----------|----------|
| INC-001 | Example: CI Lock File Out of Sync | CI/Deployment | CI, lock, sync, dependency |
| INC-002 | Example: Relative Path Breaks in Subprocesses | Paths/Directories | path, relative, absolute, subprocess |
| INC-003 | Example: Flaky Integration Test | Testing/Flakiness | flaky, timeout, retry, test |

---

## CI and Deployment

### INC-001: Example: CI Lock File Out of Sync
- **Date**: YYYY-MM
- **Keywords**: CI, lock, sync, dependency, manifest
- **Symptom**: CI fails with dependency mismatch while local builds succeed
- **Root cause**: Dependency manifest was updated without regenerating the lock file. Local tooling auto-resolves, but CI uses strict validation.
- **Detection**: Run your dependency check command (e.g., `npm ci`, `poetry check --lock`, `bundle check`)
- **Fix**: Regenerate the lock file after modifying the dependency manifest
- **Rule added**: Always regenerate the lock file after modifying dependencies

---

## Paths and Directories

### INC-002: Example: Relative Path Breaks in Subprocesses
- **Date**: YYYY-MM
- **Keywords**: path, relative, absolute, subprocess, working directory
- **Symptom**: Script fails with "file not found" when invoked from a different directory
- **Root cause**: Script used a relative path that only worked from the project root
- **Detection**: Run the script from a subdirectory and observe if paths resolve correctly
- **Fix**: Convert to absolute paths using the project root (e.g., `$(git rev-parse --show-toplevel)/path/to/file`)
- **Rule added**: Always use absolute paths in scripts and subprocess calls

---

## Testing and Flakiness

### INC-003: Example: Flaky Integration Test
- **Date**: YYYY-MM
- **Keywords**: flaky, timeout, retry, test, integration, intermittent
- **Symptom**: Test passes locally but fails intermittently in CI
- **Root cause**: Test relied on timing assumptions that do not hold under CI load
- **Detection**: Run the test in a loop: `for i in $(seq 1 10); do your-test-command; done`
- **Fix**: Replace sleep-based waits with polling/retry logic; add explicit timeouts
- **Rule added**: Never rely on fixed sleep durations in integration tests

---

## Adaptation Guidance

<!-- Customize this file for your project by following these steps: -->

To adapt this template for your project:

1. **Replace placeholder categories** with categories relevant to your codebase (e.g., "Database/Migrations", "API/Authentication", "Build System").
2. **Replace example incidents** (INC-001 through INC-003) with real incidents from your project. Keep the format consistent.
3. **Update the Index by Category** table whenever you add or remove a category section.
4. **Update the Quick Reference** table whenever you add a new incident.
5. **Set a threshold for rule promotion** — the default is 3 similar incidents before proposing a project-wide rule.
6. **Create an archive file** (`KNOWN-ISSUES-ARCHIVE.md`) for resolved incidents that are no longer actively relevant but may contain useful historical context.
7. **Customize search tips** in the header to reflect keywords common in your project (e.g., hook, config, deploy, flaky).

### Incident Entry Format

Use this format for each new incident:

```markdown
### INC-NNN: Short Descriptive Title
- **Date**: YYYY-MM
- **Keywords**: keyword1, keyword2, keyword3
- **Symptom**: What the user or CI observes
- **Root cause**: Why it happens
- **Detection**: How to check if this issue is occurring
- **Fix**: What to do about it
- **Rule added**: (optional) Rule added to prevent recurrence
```
