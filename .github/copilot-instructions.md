# Copilot Code Review Instructions

Copilot runs alongside the project's internal `/dso:review` pipeline and
CodeRabbit so all three LLM reviewers can be compared on the same PRs.

Design principle: this file tunes **coverage** (what is reviewed and across
which dimensions) to match the dso standard tier. It does not prescribe how
Copilot reasons, scores, or downgrades — that is the behavior under
comparison.

**Sync note**: Coverage dimensions and path exclusions in this file are
intentionally parallel to `.coderabbit.yaml`. Each tool requires its own
config format — consolidation is not possible. When updating review scope,
update both files together.

## Review Dimensions

Review along these dimensions:

- **correctness** — logic, edge cases, error handling, security, concurrency,
  efficiency, deletion impact.
- **verification** — test presence, test quality, edge-case coverage.
- **hygiene** — dead code, naming, unnecessary complexity, missing guards.
- **design** — responsibility boundaries, encapsulation, interface clarity,
  coupling.
- **maintainability** — readability, comments, organization, file size.

## Overlays

Additionally evaluate two overlays and state in the review summary whether
each is warranted by the diff:

- **security overlay** — auth, authz, crypto, sessions, trust boundaries,
  sensitive data.
- **performance overlay** — DB queries, caching, connection pools,
  async/concurrent patterns, batch processing.

## Out of Scope

The following are exhaustively reviewed elsewhere — skip from review:

- Lockfiles (`*.lock`, `package-lock.json`, `poetry.lock`).
- Generated indexes (`.test-index`).
- Changelogs (`CHANGELOG.md`).
- Snapshot files (`*.snap`, `__snapshots__/`).
- Archived docs (`docs/archive/`).
- Test fixtures (`tests/fixtures/`).
