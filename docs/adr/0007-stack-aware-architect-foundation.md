# ADR 0007: Stack-Aware Architect Foundation with prefill-config.sh and hashFiles() CI Skeletons

**Status**: Accepted
**Date**: 2026-04-12
**Epic**: 2275-9845 — Polyglot Architect Foundation

---

## Context

`/dso:architect-foundation` generates enforcement scaffolding for projects that have already run `/dso:onboarding`. Before this change, the skill required the agent to hand-craft the four `commands.*` keys in `dso-config.conf` (test runner, lint, format, format-check) by examining the project stack manually. This produced inconsistent results across sessions: agents sometimes left keys empty, used wrong command syntax for the detected stack, or re-asked questions already answered by `detect-stack.sh`.

Additionally, when architect-foundation generated CI configuration (GitHub Actions workflows), it had no canonical per-stack template to follow. Agents would write `if:` conditionals ad-hoc, sometimes interleaving `hashFiles()` arguments across language ecosystems (e.g., combining Python and Node checks in one expression), which produces incorrect cache-invalidation behavior in GitHub Actions.

The project also needed to support Ruby (`ruby-rails` and `ruby-jekyll`) as first-class stacks alongside Python and Node, because `detect-stack.sh` already emits those stack IDs but architect-foundation had no documented defaults for them.

---

## Decision

### prefill-config.sh

Introduce `plugins/dso/scripts/prefill-config.sh`, a standalone script that:
1. Calls `detect-stack.sh` to determine the project stack.
2. Writes the four `commands.*` keys (`commands.test_runner`, `commands.lint`, `commands.format`, `commands.format_check`) into the active `dso-config.conf` using per-stack defaults.
3. Skips any key that already has a non-empty value (safe to re-run).
4. Writes empty values with an inline comment for stacks without defined defaults (`rust-cargo`, `golang`, `convention-based`, `unknown`), prompting the user to fill them manually.

Wire `prefill-config.sh` into `/dso:architect-foundation` at Step 0.75 — after the plugin inventory (Step 0) and `.test-index` bootstrap (Step 0.5) but before enforcement layer generation (Step 1). After the script runs, the agent confirms the written values with the user and prompts for any missing values on unsupported stacks.

The script resolves `_PLUGIN_ROOT` via `BASH_SOURCE` (no hardcoded `plugins/dso/` path) and resolves the config file via the standard priority chain (`$WORKFLOW_CONFIG_FILE` → git repo root fallback).

### hashFiles() CI Skeleton Templates

Add a "CI Skeleton Templates" section to `plugins/dso/skills/architect-foundation/SKILL.md` providing per-stack GitHub Actions step blocks. Each block:
- Uses `hashFiles()` for its `if:` conditional, scoped to the dependency files for that ecosystem only.
- Is structurally isolated — one block per language, with its own `if:` expression.
- Does not interleave `hashFiles()` arguments across ecosystems.
- Uses root-relative paths (no leading `./` or `/`).

Three blocks are provided: Python (`requirements.txt` / `pyproject.toml` → `actions/setup-python@v5`), Node (`package-lock.json` / `yarn.lock` → `actions/setup-node@v4`), Ruby (`Gemfile.lock` / `Gemfile` → `ruby/setup-ruby@v1`).

### INSTALL.md Restructure

Restructure `INSTALL.md` (at repo root) into Required (universal) and Optional-by-Stack sections so that engineers only read the stack sections relevant to their project. This separates prerequisite noise for Python-only teams from Ruby or Rust teams and vice versa.

---

## Consequences

**Positive**:
- Agents running architect-foundation no longer hand-craft command values — prefill-config.sh writes correct, tested defaults based on the detected stack.
- Re-runs are idempotent: existing non-empty values are never overwritten.
- CI generation is consistent: the canonical hashFiles() blocks prevent cross-ecosystem interleaving.
- Ruby projects (rails and jekyll) now have documented first-class defaults alongside Python and Node.
- INSTALL.md is easier to navigate for polyglot teams — readers skip sections irrelevant to their stack.

**Negative**:
- Stacks without defaults (`rust-cargo`, `golang`, `convention-based`, `unknown`) still require manual configuration. The script writes a comment placeholder, but the user must supply values before enforcement scaffolding can fully run.
- The Java stack is not yet represented in the hashFiles() CI skeleton templates. A comment placeholder (`<!-- Epic F: append Java block here -->`) marks the insertion point for a future ADR.

**Neutral**:
- `commands.test_runner` is a net-new config key (distinct from `commands.test`). It is used by `suite-engine.sh` for per-file test invocation, while `commands.test` runs the full suite. Teams already relying on the full suite via `commands.test` are unaffected — `commands.test_runner` is only consumed by the test-batching infrastructure.

## Revision — 2026-04-23

Two updates to the architecture described above:

1. **Script relocation**: `plugins/dso/scripts/prefill-config.sh` moved to `plugins/dso/scripts/onboarding/prefill-config.sh`. Invocation is now `.claude/scripts/dso onboarding/prefill-config.sh`. All skill references, test paths, and internal `_PLUGIN_ROOT` resolution updated. Behavior unchanged.

2. **Skill phase renaming**: `/dso:architect-foundation` was restructured. The prefill-config invocation that was described as "Step 0.75" now lives at **Phase 3 Step 1** in the rewritten SKILL.md. The scaffolding flow is now: P0 (read understanding + artifact detect) → P1 (Socratic gap-fill) → P2 (per-recommendation synthesis) → P3 (write scaffolding — includes prefill-config at Step 1, test-index bootstrap at Step 2, fitness functions at Step 3, batched write gate at Step 4) → P4 (wire + ADRs + review).

The CI skeleton content referenced in this ADR has been extracted from `SKILL.md` to `plugins/dso/skills/shared/prompts/ci-skeleton-templates.md` and is loaded on demand. Anti-pattern codes AP-1..AP-5 are now defined in `plugins/dso/skills/shared/prompts/anti-patterns.md`.

The decision recorded above — stack-aware config pre-fill plus per-stack CI skeleton blocks — remains valid; only the implementation structure was refactored.
