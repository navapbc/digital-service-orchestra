# Contract: cycle-ledger.json Schema

- Status: accepted
- Scope: review-cycle tracking (arbiter agent + write-cycle-ledger.sh)
- Date: 2026-05-16
- schema_version: 1.2.0

## Purpose

This document defines the versioned JSON schema for `cycle-ledger.json` — the per-epic record of review cycles. The file is written by `write-cycle-ledger.sh` and read by the arbiter agent at cycle-number resolution time. It is the single source of truth for which review cycles have occurred for a given epic, their timestamps, and their findings hashes.

All implementors (writers and readers) must read this contract before emitting or parsing a cycle ledger. Changes to the schema require updating this document atomically in the same commit.

Cross-reference: the `cycle_ledger.py` Python reader/writer module docstring (`${CLAUDE_PLUGIN_ROOT}/scripts/dso_ci_review/cycle_ledger.py`) and the DefenseStore contract (`${CLAUDE_PLUGIN_ROOT}/docs/contracts/review-defenses.md`) are co-maintained with this document.

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
| `schema_version` | string | required | Semver string. Current value: `"1.2.0"`. Consumers must check this field and handle unknown versions gracefully. |
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
| `pr_number` | integer | required (v1.2.0) | The GitHub PR number for this cycle. Writers MUST populate with the real PR number (> 0). A `pr_number` of `0` is the sentinel value (`_SENTINEL_PR_NUMBER`) reserved for backward-compatible reads of legacy v1.1.0 entries — it is NEVER written by v1.2.0 writers. See [Sentinel-pr_number Migration Rule](#sentinel-pr_number-migration-rule). |
| `commit_sha` | string | optional (v1.1.0) | 40-char HEAD commit SHA at the time the cycle was closed. Used to anchor the cycle to a specific code state for retrospective audits and Jaccard stability across cycles. Writers SHOULD populate; readers MUST tolerate absence (legacy v1.0.0 ledgers). |
| `findings` | array | optional (v1.1.0) | Array of `[file, line_range, category]` 3-element tuples (each element is a string). Used by the Jaccard stability computation across cycles to detect convergence. Writers SHOULD populate; readers MUST tolerate absence. |
| `halt_reason` | string or null | optional | Reason the review loop halted at or after this cycle. Allowed values include `"STABLE_HALT"` (Jaccard stability threshold met), `"MAX_CYCLES"` (cycle cap reached), or `null` (cycle did not halt the loop). |

### Backward-Compatibility

- **Reader contract**: Readers MUST tolerate v1.0.0 records in which `commit_sha`, `findings`, and `halt_reason` are absent. When absent, treat `commit_sha` as the empty string, `findings` as the empty array, and `halt_reason` as `null`.
- **v1.2.0 reader contract**: Readers MUST tolerate v1.1.0 records that lack `pr_number`. When `pr_number` is absent, treat it as `_SENTINEL_PR_NUMBER` (0). Sentinel entries match any `pr_number` filter until a v1.2.0 entry for the same `commit_sha` is written for that specific PR; the v1.2.0 entry then supersedes the sentinel for that `(pr_number, sha)` pair (see [Sentinel-pr_number Migration Rule](#sentinel-pr_number-migration-rule)).
- **Writer contract**: Writers MUST emit v1.2.0 schema with `pr_number` populated with a real PR number (> 0). When the underlying data is unavailable (e.g., reconstruction from a legacy marker), emit the empty string for `commit_sha` and the empty array for `findings`; emit `null` for `halt_reason` when the cycle did not halt the loop. Writers MUST NEVER emit `pr_number=0` (`_SENTINEL_PR_NUMBER`).
- **Forward-compat**: Readers MUST tolerate v1.3.0+ records — unknown fields are silently ignored, not rejected. The Evolution Rules (additive-only for minor versions) continue to apply.

### Sentinel-pr_number Migration Rule

`_SENTINEL_PR_NUMBER = 0` is the module constant in `cycle_ledger.py` reserved for backward-compatible in-memory representation of legacy v1.1.0 ledger entries.

**Semantics**:

1. **v1.1.0 entries read as sentinel**: When a reader loads a cycle entry that lacks `pr_number` (v1.1.0 format), it materializes the entry with `pr_number=0` in memory. This sentinel value signals "unknown PR" rather than "no PR".
2. **Sentinel never written**: Writers MUST NEVER emit `pr_number=0` for new cycles. `append_cycle()` raises `ValueError` if called with `pr_number=_SENTINEL_PR_NUMBER` (defensive guard). This is enforced in `${CLAUDE_PLUGIN_ROOT}/scripts/dso_ci_review/cycle_ledger.py`.
3. **Sentinel matches any PR filter**: A sentinel entry matches any `pr_number` query until superseded.
4. **Supersession rule**: When both a sentinel entry (v1.1.0) and a non-sentinel entry (v1.2.0) exist in the reconstructed ledger for the same `cycle_num` and `commit_sha`, the non-sentinel (v1.2.0) entry wins for any query that matches its specific `pr_number`. The sentinel entry remains in the ledger for other PR-number contexts until overwritten by a subsequent review cycle.
5. **Mixed-format deduplication**: During PR-comment reconstruction (`reconstruct_from_pr_comments`), if a v1.2.0 marker and a v1.1.0 marker are found for the same `cycle_num`, the v1.2.0 marker takes precedence and the v1.1.0 marker is discarded for that cycle slot.

---

## CI Reconstruction

When the cycle ledger is unavailable in a CI environment (e.g., ephemeral runner), `write-cycle-ledger.sh --reconstruct-from-pr` rebuilds it by parsing `DSO-Review-Cycle:` trailers from PR or ticket comments.

### Trailer Format (v1.2.0)

```
DSO-Review-Cycle: <cycle_num> pr_number=<n> commit_sha=<sha> findings_hash=<hash> tuples=<json>
```

Where `<n>` is the integer GitHub PR number (> 0; never 0), and `<json>` is a JSON array of `[file, line_range, category]` 3-element string arrays.

**Example**:

```
DSO-Review-Cycle: 2 pr_number=42 commit_sha=abc123def4 findings_hash=h2 tuples=[["src/auth/login.py","42-45","correctness"],["src/api/handler.py","100","security"]]
```

### Trailer Format (v1.1.0, still parsed for backward-compat)

```
DSO-Review-Cycle: <cycle_num> commit_sha=<sha> findings_hash=<hash> tuples=<json>
```

v1.1.0 markers lack `pr_number=`. When parsed by a v1.2.0 reader, these entries are materialized with `pr_number=_SENTINEL_PR_NUMBER` (0) in memory. A v1.2.0 marker for the same `cycle_num` supersedes a v1.1.0 marker during reconstruction (see [Sentinel-pr_number Migration Rule](#sentinel-pr_number-migration-rule)).

**Legacy v1.0.0 format** (still parsed for backward-compat):

```
DSO-Review-Cycle: <cycle_num> findings-hash=<hash>
```

When a marker lacks `commit_sha` and `tuples`, the reconstruction parser builds a cycle entry with `findings: []`, `commit_sha: ""`.

### Grammar Constraints

- **pr_number field**: Must be a positive integer (> 0). `pr_number=0` is the sentinel and MUST NEVER appear in an emitted marker. The field is required in v1.2.0 markers; its absence denotes a v1.1.0 marker.
- **Maximum findings per marker line**: 50. Beyond 50, the producer MUST emit a **continuation marker** with the same `cycle_num` and append additional tuples. Continuation markers carry `commit_sha` and `findings_hash` identical to the first marker for that cycle, allowing the reader to merge tuple arrays across continuation lines without ambiguity.
- **Escaping**: String values within tuples are JSON-encoded. Paths or categories containing spaces, colons, equals signs, or quotes are escaped per JSON string rules (e.g., `"path with spaces/file.py"`, `"some:category"`, `"key=value"`, `"quoted\"name"`).
- **Producer responsibility**: Story 13 (`runner.py` for CI mode) and Story 14 (`review-workflow.sh` for local mode) are responsible for emitting v1.2.0 markers (with `pr_number`). The shell `write-cycle-ledger.sh --reconstruct-from-pr` path parses markers but does **not** emit new ones.

### Where It Appears

- PR comment body (GitHub pull request comments)
- Ticket comment body (DSO ticket system comments)

### Parsing Rules

1. Each line in a comment body is scanned for the prefix `DSO-Review-Cycle:`.
2. The token immediately following the colon and whitespace is the `cycle_num` (integer).
3. **Format priority**: The parser tries v1.2.0 format (with `pr_number=`) first, then v1.1.0 (without `pr_number=`), then legacy v1.0.0 (`findings-hash=`). A v1.2.0 match for a given `cycle_num` supersedes any previously seen v1.1.0 or v1.0.0 entry for that `cycle_num`.
4. v1.1.0 entries are returned with `pr_number=_SENTINEL_PR_NUMBER` (0); legacy v1.0.0 entries have `commit_sha=""` and `findings=[]`.
5. If any cycles cannot be reconstructed (trailer missing or unparseable), the resulting ledger sets `reconstruction_gaps: true`.
6. The reconstructed `timestamp_utc` for a recovered cycle is set to the PR/ticket comment timestamp, not the original write timestamp; consumers must treat reconstructed timestamps as approximate.

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

A complete v1.2.0 `cycle-ledger.json` after two review cycles:

```json
{
  "schema_version": "1.2.0",
  "epic_id": "b575-ac1c-f720-4839",
  "cycles": [
    {
      "cycle_num": 1,
      "timestamp_utc": "2026-05-16T10:15:00Z",
      "pr_number": 42,
      "commit_sha": "abc123def4abc123def4abc123def4abc123def4",
      "findings_hash": "a1b2c3d4e5f6789012345678901234567890abcd",
      "findings": [["src/auth/login.py", "42-45", "correctness"]],
      "halt_reason": null
    },
    {
      "cycle_num": 2,
      "timestamp_utc": "2026-05-16T14:30:00Z",
      "pr_number": 42,
      "commit_sha": "def456abc789def456abc789def456abc789def4",
      "findings_hash": "b9e8f7c6d5a4321098765432109876543210dcba",
      "findings": [],
      "halt_reason": "STABLE_HALT"
    }
  ]
}
```

A ledger produced by incomplete CI reconstruction (one cycle's trailer was missing):

```json
{
  "schema_version": "1.2.0",
  "epic_id": "b575-ac1c-f720-4839",
  "cycles": [
    {
      "cycle_num": 2,
      "timestamp_utc": "2026-05-16T14:30:00Z",
      "pr_number": 42,
      "commit_sha": "def456abc789def456abc789def456abc789def4",
      "findings_hash": "b9e8f7c6d5a4321098765432109876543210dcba",
      "findings": [],
      "halt_reason": null
    }
  ],
  "reconstruction_gaps": true
}
```

A ledger after mixed-format reconstruction (v1.1.0 entry materialized with sentinel pr_number):

```json
{
  "schema_version": "1.2.0",
  "epic_id": "b575-ac1c-f720-4839",
  "cycles": [
    {
      "cycle_num": 1,
      "pr_number": 0,
      "commit_sha": "abc123def4abc123def4abc123def4abc123def4",
      "findings_hash": "a1b2c3d4e5f6789012345678901234567890abcd",
      "findings": [["src/auth/login.py", "42-45", "correctness"]],
      "halt_reason": null
    }
  ]
}
```

In the above example, `pr_number=0` indicates this entry was reconstructed from a v1.1.0 marker (sentinel). The next review cycle on this PR will emit a v1.2.0 marker that supersedes this entry for the specific `(pr_number, commit_sha)` tuple.

---

## Consumers

| Component | Role | Notes |
|---|---|---|
| `write-cycle-ledger.sh` | Writer | Appends cycle objects; seeds ledger on first write |
| Arbiter agent | Reader | Reads `cycles` array to determine the current cycle number |
| `write-cycle-ledger.sh --reconstruct-from-pr` | Writer (reconstruction) | Rebuilds ledger from `DSO-Review-Cycle:` trailers; sets `reconstruction_gaps: true` on partial recovery |

---

## Versioning

This contract is versioned via the `schema_version` field in the JSON document. The current version is **1.2.0**.

### Change Log

- **2026-05-16**: Initial version (`schema_version: "1.0.0"`) — defines top-level fields (`schema_version`, `epic_id`, `cycles`, `reconstruction_gaps`), cycle object fields (`cycle_num`, `timestamp_utc`, `findings_hash`), CI reconstruction trailer format, evolution rules (additive-only for minor versions), locking primitive (`_flock_write_json`), and example documents.
- **2026-05-17**: Schema bumped 1.0.0 → 1.1.0. Added cycle entry fields `commit_sha`, `findings` (tuple array), `halt_reason`. Extended PR comment Trailer Format with `commit_sha` and `tuples` fields; legacy v1.0.0 markers still parsed for backward-compat. Added Grammar Constraints subsection documenting 50-findings-per-line cap and producer responsibility. See story 45da-5043-aa3e-4f3c (epic b575-ac1c-f720-4839).
- **2026-05-19**: Schema bumped 1.1.0 → 1.2.0. Added `pr_number` (integer, required) to the cycle object. New v1.2.0 marker grammar adds `pr_number=<n>` field before `commit_sha=`. Added `_SENTINEL_PR_NUMBER = 0` constant semantics: v1.1.0 entries are materialized with `pr_number=0` (sentinel) during reconstruction; sentinel matches any PR filter until superseded by a v1.2.0 entry for the same `(cycle_num, commit_sha)`. Writers MUST NEVER emit `pr_number=0`. `append_cycle()` raises `ValueError` on sentinel-write attempts. Reader tolerates v1.0.0, v1.1.0, and v1.2.0 formats. Mixed-format deduplication: v1.2.0 entries supersede v1.1.0 entries for the same `cycle_num` during reconstruction. See task e28f-9853-90ef-4e58 (story 0aed-4d7a-991d-4f7f, epic f691-681e-0db9-4260).
