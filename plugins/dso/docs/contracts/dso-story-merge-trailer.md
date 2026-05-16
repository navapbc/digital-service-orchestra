# Contract: DSO-Story-Merge trailer

- Signal Name: DSO-Story-Merge
- Status: accepted
- Scope: merge-story-branch.sh (local mode) → session branch merge commit → S5 provenance verifier
- Date: 2026-05-15

## Purpose

This document defines the `DSO-Story-Merge:` git trailer emitted when a story branch is merged into the session branch. The trailer records which story ticket a merge commit corresponds to, enabling the S5 provenance verifier to cross-check that every story/* merge commit on the session branch maps to a provenanced sub-branch PR.

---

## Trailer Name

`DSO-Story-Merge`

---

## Value Format

```
DSO-Story-Merge: <story-id>
```

- `<story-id>`: the raw ticket ID of the story being merged (e.g., `2abb-11b6-37ca-49dc`)
- No whitespace prefix or suffix
- No `story/` prefix — the raw ticket ID only

---

## Line Position

The trailer appears as the last line of the git commit message body, after a blank line separator following the subject line, per git-trailer convention.

Example commit message:

```
Merge story/d076-d35e-55db-4843/2abb-11b6-37ca-49dc

DSO-Story-Merge: 2abb-11b6-37ca-49dc
```

---

## Emitter

**`${CLAUDE_PLUGIN_ROOT}/scripts/merge-story-branch.sh`** (local mode)

This script performs a `--no-ff` merge of the story branch into the session branch and writes the `DSO-Story-Merge:` trailer into the merge commit message.

In **ci-pr mode**, story branches are merged via GitHub Pull Requests. The trailer is NOT written to merge commits in ci-pr mode; the S5 provenance verifier uses GitHub PR provenance signals instead.

---

## Consumer

**S5 provenance verifier** (story `a020-f33c-389c-449d`)

Reads the `DSO-Story-Merge:` trailer from merge commits on the session branch to cross-check that each merged story branch maps to a provenanced sub-branch PR. The verifier extracts the story-id value from the trailer and validates it against the set of expected story tickets for the sprint.

---

## Distinguished From

- **`DSO-Story:`** trailer: written by `apply-attribution-trailers.sh` on individual task commits (not merge commits). Records which story a task commit belongs to. The two trailers are orthogonal — `DSO-Story:` appears on task commits; `DSO-Story-Merge:` appears on story branch merge commits.

---

## Contract Test Reference

`tests/scripts/test-sprint-phase-f-ci-pr-story-pr.sh` — tests 3 and 4 verify:
1. The contract file exists at `${CLAUDE_PLUGIN_ROOT}/docs/contracts/dso-story-merge-trailer.md`
2. The contract documents the trailer name, value format (story-id), line position (last line of commit message body), and consumer reference (S5 provenance verifier)

`tests/scripts/test-merge-story-branch.sh` — tests 1 and 2 verify the emitter behavior: merge commits contain the `DSO-Story-Merge:` trailer and are created with `--no-ff`.
