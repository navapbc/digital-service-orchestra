# Proposed CLAUDE.md Addition

## Target location

In the **Architecture (pointers)** section, find the existing bullet for the UI/UX reference corpus:

> **UI/UX reference corpus** (domain-partitioned YAML files with YAML frontmatter): corpus at `plugins/dso/data/ui-reference/`; retrieval via `plugins/dso/scripts/ref-query.sh` (BM25) and `dso ref-query` shim; `check-corpus-schema.sh` pre-commit hook enforces tag vocabulary; provenance at `docs/ui-reference-sources.yaml`; `plugins/dso/data/**` requires boundary allowlist entry maintenance.

## Proposed replacement (one-line addition)

> **UI/UX reference corpus** (domain-partitioned YAML files with YAML frontmatter): corpus at `plugins/dso/data/ui-reference/`; retrieval via `plugins/dso/scripts/ref-query.sh` (BM25) and `dso ref-query` shim; use `--namespace=canon` for federal-style authority entries (USWDS, GOV.UK, 18F, Federal Plain Language) and `--format=json` for programmatic output (schema: `plugins/dso/docs/contracts/ref-query-json-output.md`); `check-corpus-schema.sh` pre-commit hook enforces tag vocabulary; provenance at `docs/ui-reference-sources.yaml`; `plugins/dso/data/**` requires boundary allowlist entry maintenance.

## Rationale

Task 04d3-b4f6-abea-45c4 (story cce1-bfd8-a134-4f18) adds `--namespace` and
`--format=json` flags to `ref-query.sh`. The CLAUDE.md Architecture pointer for
the UI/UX corpus is the canonical discovery path for agents — adding the two new
flags and the `canon` namespace here ensures agents know to use them when
seeking federal-standard authority (precedence: canon-rule > Copy Needs > Users
archetype > design-notes voice).

Full flag documentation is in `plugins/dso/docs/CONFIGURATION-REFERENCE.md`
under "UI/UX Reference Corpus — `dso ref-query` CLI flags".

## Bloat audit (per invariant:claude-md-purpose)

- Not architectural implementation details: the bullet already exists; this
  extends it by two references.
- Not a duplicate rule: no existing rule covers `--namespace` or `--format=json`.
- Not onboarding-only: agents need this per-session when writing copy.
- No verbose examples: the full example is in CONFIGURATION-REFERENCE.md.

Route via: `dso:doc-writer` with bloat-review pass.
