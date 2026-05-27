# ADR 0018: DESIGN.md Linter for Deterministic Token/Spacing-Scale Governance

**Status**: Accepted
**Date**: 2026-05-27
**Epic**: 115c-3e30-ab7d-4b12 (Plan A: DESIGN.md linter for deterministic token/spacing-scale governance)

## Context

Before this decision, design-system constraints (color tokens, spacing scale, typography scale) existed only as human-readable notes in `.claude/design-notes.md`. These notes were consulted informally by agents during preplanning but were never machine-enforced. The result was design drift: UI code could introduce hardcoded hex values, off-scale font sizes, or broken token references without any automated gate catching the violation.

The team evaluated `@google/design.md` — Google Labs' machine-readable design-system specification format — as a candidate for deterministic enforcement. The spec defines a structured `DESIGN.md` at the repo root that describes token names, color values, spacing scale, and typography scale in a format the CLI can parse and lint against. A validation spike (`plugins/dso/docs/spikes/design-md-cli-validation.md`) confirmed that version `0.2.0` of the CLI runs successfully under Node.js v20 (with non-fatal engine warnings) and Node.js ≥22 (clean).

## Decision

Adopt `@google/design.md` (`@google/design.md@0.2.0` pinned) as the canonical machine-readable design-system artifact format for this project, enforced via two complementary scripts:

1. **`design-md-lint.sh`** (pre-commit, diff-scoped): blocks commits that introduce design violations in diff-touched lines. Three-state config gate: `design.lint_enabled = auto | always | never` (default: `auto` — enabled when a UI stack is detected). Fail-open: exits 0 when `npx` is absent, DESIGN.md is missing, or no eligible files are staged.

2. **`design-lint.sh`** (audit, full-file): operator-facing command (`dso design-lint [--report]`) for full-file audit outside the commit path. Surfaces per-violation-class counts (`errors: N / warnings: N / infos: N`).

Both scripts are driven by a pre-commit hook (`pre-commit-design-md-lint.sh`) registered in `.pre-commit-config.yaml`.

The existing `.claude/design-notes.md` content was migrated to repo-root `DESIGN.md` via `migrate-design-notes-to-design-md.sh`. All plugin references that previously pointed to `design-notes.md` were retargeted to `DESIGN.md`.

Sprint Phase F was extended to run `design-md-lint.sh` on each batch's touched files before commit. FP-recovery (`/dso:fp-recovery`) was extended to treat DESIGN.md lint findings as eligible false-positive candidates. The `dso:ui-designer` agent was extended to emit a `design_md_additions` payload to preplanning when design token or spacing additions are needed.

## Consequences

**Positive:**
- Hardcoded hex values, off-scale spacing, and broken token references in UI code are caught at commit time, before they reach the review gate.
- The `dso design-lint --report` command gives operators a quick audit of the full file at any time, independent of the commit path.
- Design-system state is now machine-readable by any agent that reads `DESIGN.md`, enabling downstream tooling (preplanning, ui-designer, visual-evaluator) to consume token/scale definitions programmatically.
- Fail-open design ensures non-UI projects and projects without Node.js are never blocked.

**Negative:**
- Adds a Node.js/npx runtime dependency for the enforcement path. Projects without Node.js must set `design.lint_enabled=never` or rely on the automatic fail-open.
- Cold-start latency (~3s) on first npx invocation per machine/CI runner. Mitigated by pre-installing `@google/design.md@0.2.0` in CI setup steps.
- `@google/design.md@0.2.0` has known CLI limitations: `spec` subcommand non-functional, `lint -` (stdin) not supported. See `plugins/dso/docs/DESIGN-MD-REFERENCE.md`.

**Neutral:**
- The pinned version (`0.2.0`) must be updated manually when the upstream CLI changes behavior. The pin is centralized in `design-lint.sh` and `design-md-lint.sh` as `DESIGN_MD_VERSION` with an env-var override path for testing.

## References

- Spike: `plugins/dso/docs/spikes/design-md-cli-validation.md`
- Reference doc: `plugins/dso/docs/DESIGN-MD-REFERENCE.md`
- Config key: `design.lint_enabled` in `plugins/dso/docs/CONFIGURATION-REFERENCE.md`
- Pre-commit hook: `plugins/dso/hooks/pre-commit-design-md-lint.sh`
- Scripts: `plugins/dso/scripts/design-md-lint.sh`, `plugins/dso/scripts/design-lint.sh`
- Migration: `plugins/dso/scripts/migrate-design-notes-to-design-md.sh`
