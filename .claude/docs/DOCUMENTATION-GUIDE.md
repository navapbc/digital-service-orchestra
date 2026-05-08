# Documentation Guide — Digital Service Orchestra

> **When to read**: Before creating or updating any documentation in this repo. This guide defines where content belongs and what does NOT belong in `CLAUDE.md`.

This project is the development repo for the dso plugin itself, so it is *both* a plugin source tree and a consuming project of its own conventions. Doc placement decisions therefore distinguish between **plugin-shipped content** (lives under `plugins/dso/`) and **dev-team artifacts** (lives elsewhere).

## Documentation Target Priority

Place new content in the **first applicable** target:

1. **Skill / Agent specs** — `plugins/dso/skills/<skill>/SKILL.md`, `plugins/dso/agents/<name>.md`. Behavior/contract for a specific skill or agent. Plugin-shipped.
2. **Plugin reference docs** — `plugins/dso/docs/*.md`. Cross-cutting plugin reference (HOOKS-REFERENCE, CI-INTEGRATION, AGENTS, CONFIGURATION-REFERENCE, ticket-cli-reference, WORKTREE-GUIDE, etc.). Plugin-shipped.
3. **Plugin contracts** — `plugins/dso/docs/contracts/*.md`. Wire-format / schema contracts between agents and orchestrators. Plugin-shipped.
4. **Project-local design docs** — `docs/designs/`. Detailed design specs, wireframes, interface contracts for in-flight features in this repo.
5. **Project-local findings / archive** — `docs/findings/`, `docs/archive/`. Investigation reports, postmortems, retired artifacts. Dev-team only.
6. **Known Issues** — `.claude/docs/KNOWN-ISSUES.md` (project-local). Bugs, workarounds, infra quirks. Follow the incident template. If 3+ similar incidents accumulate, propose a CLAUDE.md rule.
7. **Inline code comments / docstrings** — only when WHY is non-obvious (hidden constraint, subtle invariant, workaround for a specific bug). See CLAUDE.md "Doing tasks" guidance.
8. **`CLAUDE.md`** — last resort. See scope rules below.

## CLAUDE.md Scope Rules

`CLAUDE.md` is loaded into every agent context. Every line costs tokens on every interaction. It must remain lean.

### Belongs in CLAUDE.md

- Quick-reference command tables (one-liners, not explanations).
- Critical rules that prevent agent mistakes (Never Do These / Always Do These).
- Architectural invariants (one-line rules guarding structural boundaries).
- One-line pointers to other docs (`See plugins/dso/docs/<topic>.md`).
- Concise rule clarifiers (one short sentence per rule).

### Does NOT belong in CLAUDE.md (per CLAUDE.md Architectural Invariants 2(a)–(d))

- **Architectural implementation details** the agent does not need per-session — sub-agent guard mechanics, phase-by-phase skill internals, dispatch plumbing. Move to the relevant `SKILL.md` or a `plugins/dso/docs/` file referenced by one line.
- **Duplicate rules** — strengthen an existing Never Do / Always Do / Architectural Invariants rule instead of adding a new numbered item.
- **Onboarding-only content** that applies once at project setup — dep pre-scan steps, integration setup flows, first-run shim checks. Move to `INSTALL.md`, `plugins/dso/docs/WORKTREE-GUIDE.md`, or the relevant skill.
- **Verbose examples inside rules** — rules state the rule in one sentence plus one short clarifier; long examples move to the referenced doc.
- **Feature descriptions / "fully implemented — do not re-implement" blocks** — move to plugin reference docs or skill specs.
- **Bug workarounds or incident postmortems** — move to `.claude/docs/KNOWN-ISSUES.md`.

When a CLAUDE.md section exceeds ~25 lines, audit for the four bloat criteria above before adding more.

## Dev-Team vs Plugin-Shipped Boundary

Per CLAUDE.md Architectural Invariant 3: **NEVER place dev-team artifacts inside `plugins/dso/`.** Design documents, investigation findings, archive files, and other dev-team work belong in project-local directories: `docs/designs/`, `docs/findings/`, `docs/archive/`, `tests/`. The `plugins/dso/` tree is a distributed artifact — only plugin-shipped content (agents, skills, hooks, scripts, config, reference docs) belongs there.

## Decision Test

Before adding content to `CLAUDE.md`, ask:

1. Does an agent need this on **every single interaction**? If no, it does not belong in `CLAUDE.md`.
2. Is this a **command, rule, or one-line pointer**? If no, find a better target above.
3. Could it live in a plugin reference doc / skill spec / project-local doc and be accessed on demand? If yes, put it there.

## Examples

| Content | Correct Target | Wrong Target |
|---|---|---|
| "What `/dso:sprint` does, phase by phase" | `plugins/dso/skills/sprint/SKILL.md` | `CLAUDE.md` |
| "Never bypass the review gate" | `CLAUDE.md` (Never Do These) | Skill spec |
| "Recurring CI flake on `test-bridge-round-trip`" | `.claude/docs/KNOWN-ISSUES.md` | `CLAUDE.md` |
| "BRIDGE_ENV_ID semantics — outbound stamps, inbound echo-prevents" | `plugins/dso/scripts/bridge/README.md` | `CLAUDE.md` |
| "Use `/dso:fix-bug` for bug-class tasks" | `CLAUDE.md` (Always Do These) | Skill spec |
| "Why we chose event-sourced tickets over a SQLite store" | `docs/designs/` or `docs/findings/` | `CLAUDE.md` |
| "Run `.claude/scripts/dso ticket list --type=bug --status=open` to enumerate bugs" | `CLAUDE.md` Quick Reference | Skill spec |
| "ADF-to-text inbound conversion edge cases" | `plugins/dso/scripts/bridge/README.md` | `CLAUDE.md` |

## Maintenance

- After every epic, `/dso:update-docs` (which dispatches `dso:doc-writer`) audits doc placement against this guide.
- When the four-tier schema in `dso:doc-writer` changes, update this guide so the agent and humans agree on placement rules.
- `plugins/dso/templates/DOCUMENTATION-GUIDE.example.md` is the generic template shipped to consuming projects. This file is the **project-specific** adaptation for the dso development repo and is intentionally not shipped by the plugin.
