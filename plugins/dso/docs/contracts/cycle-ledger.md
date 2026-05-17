# Contract: cycle-ledger.json Schema

- Status: accepted
- Scope: review-cycle tracking (arbiter agent + write-cycle-ledger.sh)
- Date: 2026-05-16
- schema_version: 1.0.0

## Purpose

This document defines the versioned JSON schema for `cycle-ledger.json` — the per-epic record of review cycles. The file is written by `write-cycle-ledger.sh` and read by the arbiter agent at cycle-number resolution time. It is the single source of truth for which review cycles have occurred for a given epic, their timestamps, and their findings hashes.

All implementors (writers and readers) must read this contract before emitting or parsing a cycle ledger. Changes to the schema require updating this document atomically in the same commit.

---

## File Location

```
$ARTIFACTS_DIR/cycle-ledger.json
```

`ARTIFACTS_DIR` is resolved by the `get_artifacts_dir()` function in `${CLAUDE_PLUGIN_ROOT}/hooks/lib/deps.sh`:

- Default: `/tmp/workflow-plugin-<16-char-hash-of-REPO_ROOT>/`
- Override: set `WORKFLOW_PLUGIN_ARTIFACTS_DIR` environment variable (used in tests for isolation)
- Legacy path (backward-compat migration): `/tmp/lockpick-test-artifacts-<worktree-name>/` — if present and the new path is empty, contents are migrated once on first access.

The lock file used during writes is co-located:

```
$ARTIFACTS_DIR/cycle-ledger.lock
```

---

## Schema — Top-Level Fields

| Field | Type | Required | Description |
|---|---|---|---|
| `schema_version` | string | required | Semver string. Current value: `"1.0.0"`. Consumers must check this field and handle unknown versions gracefully. |
| `epic_id` | string | required | The ticket ID of the epic this ledger tracks. Empty string if no epic context is available at write time. |
| `cycles` | array | required | Ordered array of cycle objects (see [Cycle Object Schema](#cycle-object-schema)). Entries are appended in cycle order; the last entry is the most recent cycle. |
| `reconstruction_gaps` | boolean | optional | Present and `true` when CI reconstruction via `--reconstruct-from-pr` was incomplete (one or more cycles could not be reconstructed from PR/ticket comment trailers). Absent or `false` when the ledger is complete. Consumers must treat an absent field as `false`. |

---

## Cycle Object Schema

Each element of the `cycles` array is an object with the following fields:

| Field | Type | Required | Description |
|---|---|---|---|
| `cycle_num` | integer | required | 1-based, monotonically increasing cycle number. The first cycle is `1`. |
| `timestamp_utc` | string | required | ISO 8601 UTC timestamp of when the cycle was closed (e.g., `"2026-05-16T14:30:00Z"`). |
| `findings_hash` | string | required | Hash of the findings file (`reviewer-findings.json`) at the time the cycle was closed. Used for integrity verification by the review gate. |

---

## CI Reconstruction

When the cycle ledger is unavailable in a CI environment (e.g., ephemeral runner), `write-cycle-ledger.sh --reconstruct-from-pr` rebuilds it by parsing `DSO-Review-Cycle:` trailers from PR or ticket comments.

### Trailer Format

```
DSO-Review-Cycle: <cycle_num> findings-hash=<hash>
```

**Example:**

```
DSO-Review-Cycle: 2 findings-hash=a1b2c3d4e5f6
```

### Where It Appears

- PR comment body (GitHub pull request comments)
- Ticket comment body (DSO ticket system comments)

### Parsing Rules

1. Each line in a comment body is scanned for the prefix `DSO-Review-Cycle:`.
2. The token immediately following the colon and whitespace is the `cycle_num` (integer).
3. The `findings-hash=<hash>` key-value pair follows on the same line.
4. If any cycles cannot be reconstructed (trailer missing or unparseable), the resulting ledger sets `reconstruction_gaps: true`.
5. The reconstructed `timestamp_utc` for a recovered cycle is set to the PR/ticket comment timestamp, not the original write timestamp; consumers must treat reconstructed timestamps as approximate.

---

## Evolution Rules

### Additive Changes (minor / patch version bump)

New optional fields may be added to the top-level object or to cycle objects without a breaking-change version bump. Consumers **must ignore unknown fields** — parsers that encounter a field not listed in this contract must silently skip it.

Examples of additive changes:
- Adding an optional field to a cycle object (e.g., `reviewer_agent`)
- Adding a new optional top-level field

### Breaking Changes (major version bump)

The following changes require incrementing the major version component of `schema_version` (e.g., `"1.0.0"` → `"2.0.0"`):

- Removing a field that is currently required
- Changing the type of an existing field
- Changing the semantic meaning of an existing field
- Removing a value from an existing enum field

When `schema_version` changes, this contract must be updated atomically with all conforming emitters and parsers.

### Version Discovery

Consumers must read `schema_version` before processing. If the major version is higher than the consumer understands, the consumer should log a warning and parse best-effort using the highest version it understands, ignoring unknown fields.

---

## Locking

`write-cycle-ledger.sh` uses the `_flock_write_json` primitive from `${CLAUDE_PLUGIN_ROOT}/scripts/ticket-lib.sh` to ensure atomic, concurrent-safe writes.

### Mechanism

`_flock_write_json` implements a 3-tier locking strategy (in priority order):

1. **util-linux `flock(1)`** — used when the util-linux `flock` binary is available in PATH or via Homebrew (`/opt/homebrew/Cellar/util-linux/`).
2. **Homebrew util-linux on macOS** — searched in `/opt/homebrew/Cellar/util-linux/` when not in PATH.
3. **Python `fcntl.flock`** — pure POSIX fallback; no external binary required; safe on macOS without Homebrew.

### Lock Parameters

| Parameter | Value |
|---|---|
| Lock file | `$ARTIFACTS_DIR/cycle-ledger.lock` |
| Lock type | Exclusive (`LOCK_EX`) |
| Timeout per attempt | 30 seconds (env override: `FLOCK_STAGE_COMMIT_TIMEOUT`) |
| Max retries | 2 |
| Worst-case total wait | 60 seconds |

### Write Protocol

While holding the lock, `_flock_write_json` performs a single atomic rename of a same-filesystem staging temp file to the final `cycle-ledger.json` path. Unlike the ticket system's `_flock_stage_commit`, this function does **not** perform git operations — the cycle ledger lives in `ARTIFACTS_DIR` (a `/tmp/` path), not in a tracked git worktree.

On lock exhaustion after all retries, the staging temp file is removed and the call exits 1. No partial state is left on disk.

---

## Example

A complete `cycle-ledger.json` after two review cycles:

```json
{
  "schema_version": "1.0.0",
  "epic_id": "b575-ac1c-f720-4839",
  "cycles": [
    {
      "cycle_num": 1,
      "timestamp_utc": "2026-05-16T10:15:00Z",
      "findings_hash": "a1b2c3d4e5f6789012345678901234567890abcd"
    },
    {
      "cycle_num": 2,
      "timestamp_utc": "2026-05-16T14:30:00Z",
      "findings_hash": "b9e8f7c6d5a4321098765432109876543210dcba"
    }
  ]
}
```

A ledger produced by incomplete CI reconstruction (one cycle's trailer was missing):

```json
{
  "schema_version": "1.0.0",
  "epic_id": "b575-ac1c-f720-4839",
  "cycles": [
    {
      "cycle_num": 2,
      "timestamp_utc": "2026-05-16T14:30:00Z",
      "findings_hash": "b9e8f7c6d5a4321098765432109876543210dcba"
    }
  ],
  "reconstruction_gaps": true
}
```

---

## Consumers

| Component | Role | Notes |
|---|---|---|
| `write-cycle-ledger.sh` | Writer | Appends cycle objects; seeds ledger on first write |
| Arbiter agent | Reader | Reads `cycles` array to determine the current cycle number |
| `write-cycle-ledger.sh --reconstruct-from-pr` | Writer (reconstruction) | Rebuilds ledger from `DSO-Review-Cycle:` trailers; sets `reconstruction_gaps: true` on partial recovery |

---

## Versioning

This contract is versioned via the `schema_version` field in the JSON document. The current version is **1.0.0**.

### Change Log

- **2026-05-16**: Initial version (`schema_version: "1.0.0"`) — defines top-level fields (`schema_version`, `epic_id`, `cycles`, `reconstruction_gaps`), cycle object fields (`cycle_num`, `timestamp_utc`, `findings_hash`), CI reconstruction trailer format, evolution rules (additive-only for minor versions), locking primitive (`_flock_write_json`), and example documents.
