# Contract: Reviewer Findings

- Status: accepted
- Scope: record-review.sh, review-defense-store.sh, mirror-defenses-to-pr.sh, dso_ci_review/verifier.py
- Date: 2026-05-14

## Purpose

This document describes the shape of reviewer findings entries as written by code-reviewer agents and potentially mutated by the verifier pipeline before `record-review.sh` processes them.

## Base Finding Fields

See `review-findings-schema.md` for the full base schema (severity, category, description, file, cited_lines, cited_excerpt, verification_evidence, etc.).

## Verifier-Injected Fields

When the `code-reviewer-verifier` agent processes a finding (Step 4.5 / Step 7c), it may inject the following fields:

| Field | Type | Description |
|-------|------|-------------|
| `verifier_status` | `"ok" \| "failed"` | Whether the verifier ran successfully. `"failed"` means fail-open: finding passed through unchanged. |
| `evidence_invalidated` | `bool` | Set to `true` when the verifier's re-executed command output differs from the reviewer-supplied `verification_evidence.output`. |
| `fingerprint` | `string` | File region for the ruling: `<path>:<line-start>-<line-end>`. Use `<path>:0-0` sentinel when no specific line range applies. |

### Ruling Transformations (applied before record-review.sh)

| Ruling | Effect |
|--------|--------|
| `confirm` | Finding unchanged; `verifier_status` set to the verifier run status. |
| `downgrade-to-minor` | `severity` set to `"minor"`. Reviewer's original severity overridden. |
| `drop` | Finding removed entirely before `record-review.sh`. Never written to findings JSON. |

## Forward Compatibility

All consumers of reviewer findings (`record-review.sh`, `review-defense-store.sh`, `review-github-defense-store.sh`, `mirror-defenses-to-pr.sh`) MUST tolerate unknown fields at the finding level. Additional fields introduced by the verifier or future pipeline stages must pass through without causing validation errors.
