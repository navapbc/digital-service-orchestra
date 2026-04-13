# Dependency Selection Guidance

> **When to read this file**: Before adding any new dependency to `pyproject.toml`. Referenced from CLAUDE.md — not auto-loaded.

## Quick Decision Flowchart

```
Need new functionality?
  ├─ Can Python stdlib solve it? → Use stdlib. Stop.
  ├─ Can an existing project dependency solve it? → Use existing dep. Stop.
  ├─ Is the functionality < 50 lines to implement? → Implement it yourself. Stop.
  └─ Need an external package → Evaluate candidate below.
```

## Evaluation Categories

### Hard Blocks — Require User Approval

Never add a dependency that meets ANY of these criteria without explicit user confirmation. Present the specific concern to the user.

| Criterion | How to Check |
|-----------|-------------|
| **Unmaintained**: No commits in 12+ months or repo is archived | Check GitHub repo: last commit date, archive status |
| **Alpha status**: Package declares itself alpha or version is 0.x with "alpha" label | Check PyPI classifiers, README, changelog |
| **Frequent security vulnerabilities**: 3+ CVEs in the past 6 months | Search `https://pypi.org/project/<name>/` advisories, check GitHub Security tab |
| **No license or restrictive license**: Missing license, or license incompatible with project (GPL in MIT project) | Check PyPI license field, `LICENSE` file in repo |

### Soft Blocks — Flag to User

Flag these to the user with context. They may still approve, but should be aware of the risk.

| Criterion | How to Check |
|-----------|-------------|
| **Beta status**: Package declares itself beta | Check PyPI classifiers, version scheme |
| **Low adoption**: <1,000 GitHub stars AND <100K monthly PyPI downloads | Check GitHub stars, PyPI download stats via `pypistats` |
| **Single maintainer, no org**: One person maintains it with no organizational backing | Check PyPI maintainers, GitHub contributors |
| **Heavy transitive dependencies**: Pulls in 10+ transitive deps | Run `pip install --dry-run <package>` or check dependency tree |
| **Python version constraints**: Doesn't support Python 3.13+ | Check PyPI classifiers, `python_requires` in metadata |

### Auto-Approved — No Special Approval Needed

Dependencies that meet ALL of these can be added without special approval:

- Stable release (1.0+, not alpha/beta)
- Actively maintained (commits within last 6 months)
- Widely adopted (>5,000 GitHub stars OR >500K monthly downloads)
- Maintained by a known organization or multiple maintainers
- Compatible license (MIT, Apache 2.0, BSD)
- Supports Python 3.13+

## Build vs Buy

**Implement yourself when:**
- The functionality is straightforward (<50 lines)
- You only need a small fraction of the library's features
- The library would add significant transitive dependencies
- The domain logic is core to the project (policy extraction, Rego generation)

**Use a dependency when:**
- The problem is well-defined and non-trivial (parsing, HTTP, ORM, crypto)
- Correctness matters and the library has extensive test coverage
- The library handles edge cases you'd miss (Unicode, timezones, security)
- Maintenance burden of DIY would exceed the dependency risk

## Evaluation Checklist

Before proposing a new dependency, verify:

1. **Necessity**: Can stdlib or an existing dependency handle this?
2. **Maintenance**: When was the last commit? Last release?
3. **Stability**: What's the version? Is it alpha/beta/stable?
4. **Adoption**: GitHub stars? PyPI downloads?
5. **Security**: Any recent CVEs or advisories?
6. **License**: Compatible with this project?
7. **Dependencies**: How many transitive dependencies does it pull in?
8. **Python support**: Does it support Python 3.13+?
9. **Alternatives**: Are there better-maintained alternatives?

## When Proposing a Dependency to the User

Present your evaluation concisely:

```
Proposing: <package-name> v<version>
Purpose: <what it does for us>
Category: [Auto-Approved | Soft Block | Hard Block]
Maintenance: Last commit <date>, last release <date>
Adoption: <stars> stars, <downloads> monthly downloads
License: <license>
Concerns: <any flags, or "None">
```

## Security Audit Commands

Run the appropriate command for your language stack to scan dependencies for known security vulnerabilities before adding or updating packages.

| Language | Tool | Invocation |
|----------|------|-----------|
| Python | pip-audit | `pip-audit --strict` |
| JavaScript/TypeScript | npm audit | `npm audit --audit-level=moderate` |
| Ruby | bundle-audit | `bundle-audit check --update` |

- **pip-audit**: Scans Python dependencies for known security vulnerabilities using the Python Advisory Database (PyPI) and OSV.
- **npm audit**: Scans Node.js dependencies against the npm advisory registry; `--audit-level=moderate` reports moderate and higher severity findings.
- **bundle-audit**: Scans Ruby gem dependencies against the Ruby Advisory Database; `--update` refreshes the advisory database before scanning.
