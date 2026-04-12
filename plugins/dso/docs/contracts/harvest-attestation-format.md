# Contract: Harvest Attestation Format

- Signal Name: HARVEST_ATTESTATION
- Status: accepted
- Scope: worktree-to-session merge attestation (epic 4ee7-2207)
- Date: 2026-04-12

## Purpose

This document defines the file formats for attested test-gate-status and review-status files written by `harvest-worktree.sh` via the `--attest` flag on `record-test-status.sh` and `record-review.sh`. Attestation transfers trust from a worktree that already passed its gates to the session branch's post-merge diff hash, without re-running tests or re-validating review findings.

This contract must be agreed upon before any emitter or consumer is implemented to prevent implicit format assumptions.

---

## Signal Name

`HARVEST_ATTESTATION`

---

## Emitter

`harvest-worktree.sh` invokes two recording scripts with `--attest <worktree-artifacts-dir>`:

- `record-test-status.sh --attest <dir>` — reads the worktree's `test-gate-status`, verifies it is passing, and writes a new `test-gate-status` in the session artifacts directory with the post-merge diff hash.
- `record-review.sh --attest <dir>` — reads the worktree's `review-status`, verifies it is passing, and writes a new `review-status` in the session artifacts directory with the post-merge diff hash.

---

## Parser

The pre-commit gates consume these files using their existing validation logic:

- `pre-commit-test-gate.sh` — reads `test-gate-status` line 1 (status) and `diff_hash` field.
- `pre-commit-review-gate.sh` — reads `review-status` line 1 (status), `diff_hash`, and `review_hash` fields.

Both gates are unmodified. They accept attested files because the format is identical to directly-recorded files, with the `attest_source` field as an additive extension that existing parsers ignore.

---

## File Formats

### test-gate-status

Line-oriented key=value format. Each field occupies one line.

| Line | Field | Type | Description |
|---|---|---|---|
| 1 | *(status)* | string | Test result: `passed`. Attestation only writes `passed` (refuses if source is not passing). |
| 2 | `diff_hash` | string | SHA-256 hash of the post-merge staged+unstaged diff (computed by `compute-diff-hash.sh` in the session context). |
| 3 | `timestamp` | string | ISO 8601 UTC timestamp of the attestation write (e.g., `2026-04-12T14:30:00Z`). |
| 4 | `tested_files` | string | Comma-separated list of test files. Union of the source worktree's `tested_files` and any locally-required tests for session-side staged files. |
| 5 | `attest_source` | string | Worktree artifacts directory path that provided the source gate status. Identifies the trust chain origin. |

**Example**:

```
passed
diff_hash=a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2
timestamp=2026-04-12T14:30:00Z
tested_files=tests/unit/test_foo.sh,tests/unit/test_bar.sh
attest_source=/tmp/workflow-plugin-abc123/
```

### review-status

Line-oriented key=value format. Each field occupies one line.

| Line | Field | Type | Description |
|---|---|---|---|
| 1 | *(status)* | string | Review result: `passed`. Attestation only writes `passed` (refuses if source is not passing). |
| 2 | `timestamp` | string | ISO 8601 UTC timestamp of the attestation write. |
| 3 | `diff_hash` | string | SHA-256 hash of the post-merge staged+unstaged diff (computed by `compute-diff-hash.sh` in the session context). |
| 4 | `score` | integer | Minimum numeric score from the original worktree review (carried forward from source). |
| 5 | `review_hash` | string | SHA-256 hash of the original `reviewer-findings.json` (carried forward from source). |
| 6 | `attest_source` | string | Worktree artifacts directory path that provided the source gate status. Identifies the trust chain origin. |

**Example**:

```
passed
timestamp=2026-04-12T14:30:05Z
diff_hash=a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2
score=4
review_hash=b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3
attest_source=/tmp/workflow-plugin-abc123/
```

---

## Attestation Preconditions

Before writing an attested status file, the `--attest` mode MUST verify:

1. The source worktree's status file exists at `<worktree-artifacts-dir>/test-gate-status` (or `review-status`).
2. The source status is `passed` (line 1). If the source is `failed`, `timeout`, or `partial`, attestation is refused.
3. The source `diff_hash` is non-empty (proves the worktree recorded a valid gate pass).

If any precondition fails, the script exits non-zero without writing a status file. `harvest-worktree.sh` interprets this as exit code 2 (gate failure).

---

### Canonical parsing prefix

The parser MUST match against:

- `HARVEST_ATTESTATION` — this contract defines a line-oriented key=value file format. Both `test-gate-status` and `review-status` are parsed line-by-line. Line 1 is the bare status value (`passed`); subsequent lines use `key=value` format. The `attest_source` field is an additive extension — parsers that do not recognize it must silently ignore it. Pre-commit gates read only the fields they need (status, diff_hash, review_hash) and skip unknown keys.

---

## Exit Code Semantics (harvest-worktree.sh)

| Exit code | Meaning |
|---|---|
| `0` | Success — merge committed, both gates attested, worktree branch integrated. |
| `1` | Merge conflict — non-`.test-index` conflict detected. Merge aborted, MERGE_HEAD cleaned up. No attestation written. |
| `2` | Gate failure — worktree's `test-gate-status` or `review-status` missing, failed, or stale. No merge attempted. |

---

## Failure Contract

If attestation fails (source status missing, not passing, or `--attest` script error):

- `harvest-worktree.sh` aborts the merge (`git merge --abort` if MERGE_HEAD exists).
- No status files are written to the session artifacts directory.
- The worktree is NOT removed — it is retained for re-investigation.
- The caller (sprint orchestrator) must re-run gates in the worktree context before retrying.

---

## Consumers

| Component | Role | Notes |
|---|---|---|
| `harvest-worktree.sh` | Emitter (orchestrator) | Invokes `--attest` on both recording scripts after merge |
| `record-test-status.sh --attest` | Emitter (test attestation) | Writes attested `test-gate-status` to session artifacts |
| `record-review.sh --attest` | Emitter (review attestation) | Writes attested `review-status` to session artifacts |
| `pre-commit-test-gate.sh` | Consumer | Reads `test-gate-status`; ignores `attest_source` (additive field) |
| `pre-commit-review-gate.sh` | Consumer | Reads `review-status`; ignores `attest_source` (additive field) |
| `per-worktree-review-commit.md` | Reference | Sprint orchestrator workflow documentation |

---

## Versioning

This contract is unversioned. Breaking changes (field removal, type changes, line order changes) require updating all emitters, consumers, and this document atomically in the same commit. Additive changes (new optional fields appended after existing lines) are backward-compatible for parsers that ignore unknown keys and do not require a version bump.

### Change Log

- **2026-04-12**: Initial version — defines `test-gate-status` and `review-status` attestation formats with `attest_source` field, preconditions, exit code semantics, and failure contract.
