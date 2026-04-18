# Large Diff Splitting Guide

Your diff exceeds 600 scorable lines. The review system has emitted a SIZE_WARNING and is proceeding with the review — a reviewer working through hundreds of changed lines across unrelated concerns produces lower-quality findings and misses subtle bugs. Smaller, focused commits produce better reviews.

This guide explains how to split your work into reviewable units.

---

## Why the threshold exists

A reviewer has a finite context budget. When a diff mixes unrelated concerns — a new data model, a service layer change, an API endpoint, and a UI component all in one commit — the reviewer must hold all of it in mind simultaneously. Beyond roughly 300–600 lines, the cognitive load causes reviewers (human or automated) to miss interactions between changes. The 600-line threshold is where diminishing returns become severe enough to warrant a SIZE_WARNING rather than guarantee review quality; the review proceeds but results may be partial.

---

## What counts as scorable lines

The classifier counts lines in source files that require semantic review. Lines in the following categories are **exempt** from the threshold:

- **Generated files**: migration files, lock files (`poetry.lock`, `package-lock.json`, `yarn.lock`), compiled assets, auto-generated client stubs
- **Test-only diffs**: commits where every changed file is a test file (no production source changes)
- **Merge commits**: merge commits bypass size limits entirely; review scope is limited to conflicted files plus session-modified files

If your diff is large primarily because of generated or migration files, verify those are being excluded. If the exempt files still push you over 600 scorable lines, split the non-exempt work.

---

## Splitting by concern

Each commit should have one semantic purpose — a single reason to exist that can be summarized in a one-line commit message without "and".

**Signs you need to split by concern:**
- Your commit message uses "and" or a semicolon: `feat: add user auth and update dashboard`
- The files changed span unrelated areas (e.g., auth module + billing module)
- A reviewer would need to understand two unrelated systems to review the change

**How to split:**
1. Identify the independent concerns in your working tree
2. Stage and commit each concern separately using `git add -p` (interactive patch staging)
3. Each resulting commit should be reviewable without knowledge of the others

**Anti-pattern to avoid:** Giant "feature complete" commits that bundle all work done over several hours into a single diff. Commit as you complete each logical unit, not at the end of a session.

---

## Splitting by layer

When building a vertical slice of a feature, split commits by architectural layer. Each layer is independently reviewable because the interface between layers is well-defined.

**Recommended order:**

1. **Data model** — schema changes, migrations, model classes
2. **Service layer** — business logic, domain objects, use cases
3. **API layer** — routes, controllers, serializers, request/response contracts
4. **UI layer** — components, views, client-side logic

Reviewers familiar with each layer can review that layer's commit in isolation. A reviewer who understands your data model can review the service layer commit without needing to also parse UI changes.

**Anti-pattern to avoid:** Mixing layers within a single commit because "they're all part of the same feature." Layers have distinct concerns and different reviewers may have expertise in different layers.

---

## Keeping tests with their code

Tests and the implementation they cover must live in the same commit. Do not split a test from its implementation.

**Correct:** One commit containing both `src/auth/token_validator.py` and `tests/unit/auth/test_token_validator.py`

**Incorrect:** Separate commits — one for the implementation, one for the tests. This leaves the implementation commit unverifiable by the reviewer and breaks the TDD contract.

**Why this matters:** A reviewer assessing a code change needs to see the tests to evaluate whether the implementation is correctly tested. Separating them degrades review quality as much as an oversized diff.

**Anti-pattern to avoid:** A "test cleanup" commit that adds tests for production code already committed. Write the test in the same commit as the code.

---

## Practical git commands

### Stage specific hunks interactively

```bash
git add -p
```

Walks through each changed hunk and asks whether to stage it. Press `y` to stage, `n` to skip, `s` to split a hunk further. Use this to build a commit containing exactly one concern from a working tree with multiple in-progress changes.

### Undo the last commit while keeping changes staged

```bash
git reset HEAD~1 --soft
```

Moves the branch pointer back one commit but leaves all changes staged. Use this if you committed too much and want to re-split. Your changes are preserved; only the commit is undone.

### Unstage specific files

```bash
git restore --staged <file>
```

Moves a file from staged back to unstaged without discarding changes. Use after `git add -p` if you accidentally staged the wrong file.

### Check what is staged before committing

```bash
git diff --cached --stat
```

Shows a summary of staged changes. Review this before committing to confirm the diff is focused on a single concern.

---

## Common anti-patterns

| Anti-pattern | Problem | Fix |
|---|---|---|
| "Feature complete" mega-commit | Bundles weeks of work; impossible to review | Commit each logical unit as it is completed |
| Splitting test from implementation | Reviewer cannot verify correctness; breaks TDD | Always commit test and impl together |
| Mixing unrelated bug fixes | Reviewer must context-switch mid-review | One bug fix per commit |
| Separating generated files then manually editing them | Review cannot distinguish generated from manual changes | Keep generated and manual changes in separate commits |
| "Cleanup" commit that touches 20 files | No clear semantic purpose; high noise | One cleanup concern per commit (e.g., rename-only, format-only) |
