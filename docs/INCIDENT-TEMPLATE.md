# Incident Logging Template

> Use this template when adding new incidents to KNOWN-ISSUES.md

## Quick Add Format

When you encounter a new issue, add it to KNOWN-ISSUES.md using this format:

```markdown
### INC-XXX: <Short Description>
- **Date**: YYYY-MM
- **Keywords**: keyword1, keyword2, keyword3
- **Symptom**: What did you observe?
- **Root cause**: Why did it happen?
- **Fix**: How do you resolve it?
- **Rule added**: What rule prevents recurrence? (if any)
```

## Keyword Guidelines

Use consistent keywords for searchability:

| Category | Keywords |
|----------|----------|
| CI/Build | CI, build, GitHub Actions, workflow, deploy, pipeline |
| Paths | path, directory, working directory, app/, src/, pwd |
| Dependencies | poetry, lock, pip, dependency, package, version |
| Testing | test, pytest, fixture, mock, coverage, assertion |
| Git | commit, push, hook, pre-commit, verify, merge |
| Database | db, migration, alembic, postgres, session, model |
| API | route, blueprint, endpoint, request, response, HTTP |
| Types | mypy, type, hint, annotation, typing, generic |

## Getting the Next Incident ID

1. Check the last incident ID in KNOWN-ISSUES.md
2. Increment by 1 (e.g., INC-013 → INC-014)

## Update the Index

After adding a new incident, update the index tables at the top of KNOWN-ISSUES.md:

1. **Index by Category** - Increment the count for the relevant category
2. **Quick Reference by Incident ID** - Add the new incident to the table

## Example

**Scenario**: Agent discovers that `make test` fails silently when pytest is not installed.

**Entry to add:**

```markdown
### INC-014: pytest Not Installed Causes Silent Failure
- **Date**: 2026-02
- **Keywords**: test, pytest, make, silent, failure, install
- **Symptom**: `make test` exits with code 0 but no tests run
- **Root cause**: pytest not in PATH; Makefile doesn't check for pytest
- **Fix**: Run `poetry install` to install dev dependencies
- **Rule added**: Pre-Development Checklist now includes verifying pytest installation
```

## When to Log an Incident

Log an incident when:
- [ ] A failure cost significant debugging time (>15 min)
- [ ] The root cause was non-obvious
- [ ] A rule should be added to prevent recurrence
- [ ] Multiple agents might encounter the same issue

Do NOT log:
- Simple typos or one-off mistakes
- Issues specific to a single user's environment
- Temporary infrastructure outages
