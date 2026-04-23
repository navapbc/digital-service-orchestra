# Documentation Guide

> **When to read this file**: Before creating or updating any project documentation. This guide defines where documentation belongs and what does NOT belong in your project configuration file.

## Documentation Target Priority

When documenting a feature, pattern, fix, or architectural decision, place the content in the **first applicable** target from this list:

1. **Codebase Overview** — Feature descriptions, directory structure, tech stack details, naming conventions, environment variables, and testing guidance. This is the primary home for "what exists and how it works" documentation.

2. **Architecture Decision Records** (e.g., `docs/decisions/`) — Design rationale, tradeoff analysis, and "why we chose X over Y" records. Create a new ADR file for each significant architectural decision.

3. **Design Documents** (e.g., `docs/designs/`) — Detailed design specs, wireframes, and interface contracts for features under development or recently shipped.

4. **Known Issues** (e.g., `KNOWN-ISSUES.md`) — Bugs, workarounds, flaky tests, infrastructure quirks, and incident postmortems. Follow the incident template format. If 3+ similar incidents accumulate, propose a rule in your project configuration.

5. **Specialized Guides** (e.g., `docs/<TOPIC>.md`) — Deep-dive references for specific subsystems. Create a new file when a topic needs more than a paragraph of guidance.

6. **Inline Code Comments** — Implementation details that are tightly coupled to specific code. Prefer docstrings for public APIs and brief comments for non-obvious logic.

7. **Project Configuration File** (e.g., `CLAUDE.md`, `.cursorrules`) — **Last resort only.** See scope rules below.

## Project Configuration Scope Rules

Your project configuration file is loaded into every agent context window. Every line added there costs tokens on every interaction. It must remain lean.

### What BELONGS in the Project Configuration

- Quick-reference command tables (one-liners, not explanations)
- Critical rules that prevent common agent mistakes (Never Do / Always Do)
- Architectural invariants (one-line rules that prevent structural violations)
- Pointers to other docs (e.g., "See `docs/TOPIC.md`")
- High-level architecture summary (not implementation details)

### What Does NOT Belong in the Project Configuration

- **Feature descriptions** — move to codebase overview
- **"Fully implemented — do not re-implement" blocks** — move to codebase overview
- **Implementation details** — move to codebase overview or specialized guides
- **Design rationale or tradeoff analysis** — move to ADRs
- **Bug workarounds or incident details** — move to Known Issues
- **Multi-paragraph explanations** — move to a specialized guide
- **Environment variable documentation beyond a name mention** — move to codebase overview

## Decision Test

Before adding content to your project configuration file, ask:

1. Does an agent need this on **every single interaction**? If no, it does not belong in the configuration file.
2. Is this a **command, rule, or one-line pointer**? If no, find a better target above.
3. Could this live in a codebase overview and be accessed on demand? If yes, put it there.

## Examples

| Content | Correct Target | Wrong Target |
|---------|---------------|--------------|
| "The auth service validates JWT tokens and issues refresh tokens" | Codebase Overview | Project Config |
| "Never bypass the authentication middleware" | Project Config (architectural invariant) | Codebase Overview |
| "We chose PostgreSQL over MongoDB because..." | ADR in `docs/decisions/` | Project Config |
| "Flaky test in CI: test_upload_large_file times out" | Known Issues | Project Config |
| "Set `DATABASE_URL` to connect to the staging database" | Codebase Overview | Project Config |
| "Run `make test` before pushing" | Project Config (command reference) | Codebase Overview |

## Adaptation Guidance

To adapt this template for your project:

1. **Replace generic paths** with your actual directory structure. For example, if your ADRs live in `architecture/decisions/` instead of `docs/decisions/`, update the paths accordingly.
2. **Customize the priority list** to match your project's documentation locations. Add or remove targets as needed — not every project has a codebase overview skill or ADR directory.
3. **Update the examples table** with real examples from your project to make the guidance concrete for contributors.
4. **Name your project configuration file** — replace the generic "Project Configuration File" references with your actual file name (e.g., `CLAUDE.md`, `.cursorrules`, `AGENTS.md`).
5. **Add project-specific scope rules** if your project has unique documentation constraints (e.g., "API documentation must live in OpenAPI specs, not markdown").
6. **Set your documentation review process** — consider adding a section about who reviews documentation changes and how.
