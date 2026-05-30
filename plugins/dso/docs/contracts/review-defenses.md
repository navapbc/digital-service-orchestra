# Contract: review-defenses

- Signal Name: review-defenses
- Status: accepted
- Scope: REVIEW-WORKFLOW.md orchestrator → DefenseStore backends (TrackerDefenseStore, GitHubPRDefenseStore)
- Date: 2026-05-07

## Purpose

This document defines the canonical DefenseStore record shape and the interfaces for storing and retrieving review defense records. A defense record is written when a resolver agent defends a finding (i.e., argues that a reviewer finding is invalid or already addressed). The orchestrator reads and writes these records via one of two backends depending on the execution context: TrackerDefenseStore (local `/dso:review` sessions) or GitHubPRDefenseStore (CI pipeline reviews against a pull request).

This contract must be agreed upon before any implementation begins to prevent implicit assumptions and ensure writers, readers, and arbiters all operate on the same shape.

---

## Signal Name

`review-defenses`

---

## DefenseStore Interface

All backends implement the following operations:

### `write(record: DefenseRecord) → void`

Persists a DefenseRecord. Raises an error (exit code 1) if ticket-binding is absent (see Ticket-Binding Integrity).

### `load(finding_id: string) → DefenseRecord | null`

Returns the defense record for the given `prior_finding_id`, or null if none exists.

### `load_for_region(region_files: list[string], query_sha: string | null = null) → list[DefenseRecord]`

Returns records filtered to those with any cited line path intersecting `region_files`.

**SHA-range validation** (when `query_sha` is provided and a candidate record contains both `story_branch_tip_sha` and `story_branch_base_sha`): the record is included only if `query_sha` satisfies at least one of the following conditions:

- **Condition A — in-range** (linear chain): `BASE` is an ancestor of `query_sha` AND `query_sha` is an ancestor of `TIP`. This covers commits that land directly on the story branch between the merge-base and the branch tip.
- **Condition B — post-merge**: `TIP` is an ancestor of `query_sha`. This covers merge commits and commits that come after the story branch tip (e.g., merge-back commits on the session branch).

Records that pass neither condition are excluded from the result even if their file paths intersect `region_files`. This prevents stale defenses from suppressing findings on commits that did not exist when the defense was recorded.

**Legacy fallback**: When a candidate record lacks `story_branch_tip_sha` or `story_branch_base_sha` (i.e., written before SHA-range attestation was introduced), the loader falls back to `diff_hash` lookup for that record and emits a warning to stderr containing the literal string `legacy attestation`. The legacy record is included if the `diff_hash` matches; otherwise it is excluded. No-op default (no `query_sha` supplied) returns all path-intersecting records unfiltered, preserving backward compatibility for backends that do not support SHA-range filtering.

---

## Record Shape

The following table defines all fields of a DefenseRecord. All required fields must be present; optional fields may be omitted.

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `prior_finding_id` | string | yes | ID of the finding being defended, as it appears in `reviewer-findings.json`. |
| `cited_lines_fingerprint` | string | yes | SHA-256 (lowercase hex) of the UTF-8-encoded, LF-normalized, trailing-whitespace-stripped concatenation of `<path>:<line_number>:<content>` per cited line. Computed by the orchestrator before dispatching the resolver. Whitespace-only changes preserve binding; semantic edits void it. |
| `defense_text` | string | yes | Defense explanation. Maximum 4096 Unicode codepoints. Submissions exceeding this cap are rejected with an error (not silently truncated). |
| `defender` | string | yes | Agent or human identifier that wrote the defense (e.g., `dso:code-reviewer-standard`, `human:joe`). |
| `cycle_number` | integer | yes | Review cycle number when the defense was recorded (1-indexed). |
| `timestamp` | string | yes | ISO 8601 timestamp (UTC) when the defense was written. |
| `severity_history` | array | yes | Per-cycle severity records for SC1 telemetry. Each entry: `{cycle: int, severity: string, relation: string \| null}`. Must contain at least one entry. |
| `arbiter_ruling` | object | no | Present only when an arbiter resolved this defense. Fields: `ruling` (exactly one of `BLOCK`, `DEFER`, or `DROP`), `summary` (1–2 sentence summary in GitHubPRDefenseStore; full text in TrackerDefenseStore), `arbiter_cycle` (integer), `schema_version` (string, `"1.1.0"`), `cross_reviewer_agreement` (array of strings; enum from 4-value vocabulary — `UNANIMOUS`, `MAJORITY`, `SPLIT`, `SINGLE_REVIEWER`), `cross_cycle_pattern` (array of strings; enum from 7-value vocabulary — `NEW_INTRODUCED`, `RECURRING`, `RESUSTAIN_OF`, `RESOLVED_THEN_REINTRODUCED`, `ESCALATED`, `DEFENDED_PRIOR_CYCLE`, `UNKNOWN`), `impact_class` (single string; enum from 9-value vocabulary — 8-category floor `bug`/`unintended_behavior`/`security_vulnerability`/`data_loss_or_corruption`/`secret_exposure`/`compliance_violation`/`api_contract_break`/`infrastructure_break` plus `none`). The three classification fields are required when `schema_version` is `"1.1.0"` or later; legacy `"1.0.0"` records omit them. BLOCK rulings require `impact_class` to be in the 8-category floor (not `none`). |
| `ticket_id` | string | yes | Ticket bound at time of defense write. Set to `UNBOUND` when no session ticket — this value is invalid and causes write failure per the ticket-binding integrity rule. |
| `story_branch_tip_sha` | string | no | Tip commit SHA of the story branch at the time the defense was written. Used by `load_for_region` for SHA-range validation. When present, `story_branch_base_sha` must also be present. |
| `story_branch_base_sha` | string | no | Merge-base SHA between the story branch and the session branch at the time the defense was written. Used by `load_for_region` for SHA-range validation. When present, `story_branch_tip_sha` must also be present. |
| `cited_lines` | array of strings | no | List of file:line references copied from the defended finding's `cited_lines` field. Persisted format: either `file/path.py:42` (2-part `path:lineno`) or `file/path.py:42:<content>` (3-part `path:lineno:content` as emitted by `mirror-defenses-to-pr.sh`). Readers MUST normalize 3-part entries to 2-part form (drop the content segment) before proximity matching — `runner.py _normalize_cited_ref` performs this normalization at load time. When present, enables ±5-line proximity-matching suppression in `_suppress_defended_findings` (runner.py). When absent, the matcher falls back to `description[:80]` comparison. Populated by the REVIEW-WORKFLOW.md orchestrator at defense record assembly time. |

---

## Two-Backend Split

The DefenseStore record shape is identical across both backends. The backends differ in **where** they persist records and in the `arbiter_ruling.summary` verbosity.

### TrackerDefenseStore

Used by local `/dso:review` sessions (not attached to a GitHub PR).

- **Storage**: ticket comments on the session-bound ticket. Each defense record is serialized as a JSON code block in a ticket comment.
- **`arbiter_ruling.summary`**: full arbiter ruling text (no length restriction). Reviewers and developers can read the full rationale in ticket history.
- **`load_for_region`**: filters by path intersection against cited lines in stored records.

### GitHubPRDefenseStore

Used by CI pipeline reviews operating against a GitHub pull request.

- **Storage**: PR review comments on the associated pull request. Each defense record is serialized as a JSON code block in a PR comment.
- **`arbiter_ruling.summary`**: 1–2 sentence summary with a link to the full ruling in the CI job log. Keeps PR comments readable.
- **`load_for_region`**: filters by path intersection; backends backed by PR comment threads may scope to changed files in the PR.

Both backends reject writes when ticket-binding is absent (see Ticket-Binding Integrity).

---

## cited_lines_fingerprint Computation

The `cited_lines_fingerprint` field binds a defense to the specific lines of code it defends against. The orchestrator computes this fingerprint before dispatching the resolver agent.

**Algorithm** (computed by the orchestrator, not the reviewer):

1. For each cited line in the finding (in file-path-then-line-number order, ascending):
   a. Normalize the line content: strip trailing whitespace, normalize line endings to LF.
   b. Form the entry string: `<path>:<line_number>:<content>` (no trailing newline on the entry itself).
2. Concatenate all entry strings with a single LF (`\n`) between entries.
3. Encode the concatenated string as UTF-8 bytes.
4. Compute SHA-256 over the UTF-8 bytes.
5. Output as lowercase hexadecimal string (64 characters).

**Binding semantics:**

- Whitespace-only changes to cited lines (e.g., indentation normalization) preserve the binding — the normalized content is identical.
- Semantic edits to cited lines (e.g., logic changes, identifier renames) change the normalized content, void the fingerprint, and release the binding.
- A released binding means the finding is treated as `NEW_INTRODUCED` in the next review cycle; a prior defense does not apply.

**Relationship to the `cited_lines` field:** the `cited_lines_fingerprint` is computed over 3-part entries (`path:lineno:content`) and is used for fingerprint-based binding. The separate optional `cited_lines` field (see Record Shape) carries 2-part entries (`path:lineno`) and is used by `_suppress_defended_findings` for ±5-line proximity matching. The runner normalizes 3-part entries to 2-part form (dropping the content segment) before proximity matching, so callers may populate `cited_lines` directly with 2-part references.

> **cited_lines emission (active since Story A — 1ef8-79c4)**: `mirror-defenses-to-pr.sh` now includes the `cited_lines` array in every `DEFENSE_RECORD` it emits to GitHub PR comments. The array carries the 3-part `path:lineno:content` format used in `cited_lines_fingerprint` computation. This enables `runner.py _suppress_defended_findings` to perform proximity-overlap matching in subsequent review cycles without re-reading source files from the repository.

---

## Durable Binding Contract

Once a defense is recorded against a `cited_lines_fingerprint`, the following invariant holds for subsequent review cycles:

- **Subsequent cycles must not re-raise the same `finding_id` against the same fingerprint state.** If the fingerprint matches on a later cycle, the finding is considered defended and must not appear as a new finding.
- **If cited lines change semantically**, the fingerprint changes, the binding is released, and the finding may be re-raised under `NEW_INTRODUCED` authority. The prior defense record is retained in history but does not apply to the new fingerprint.
- **Arbiter rulings follow the fingerprint**: a `DEFER` ruling persists only while the fingerprint is stable. A semantic edit releases both the defense and the arbiter ruling.

---

## Ticket-Binding Integrity

Every review session must be bound to an active ticket before defense records can be written.

- **Rule**: a `write()` call without a session-bound ticket MUST fail with exit code 1 and stderr containing the literal string `ticket-binding required`.
- **`ticket_id` field**: set to the bound ticket ID at time of write. The value `UNBOUND` is never valid in a persisted record — it serves only as a sentinel to detect missing binding before the write is attempted.
- **Purpose**: ensures all defense records are traceable to a ticket for audit, SC1 telemetry, and multi-bound tiebreak resolution.

---

## Multi-Bound Session Tiebreak

When a session has more than one active ticket (e.g., a story and its parent epic are both open), the defense record is written to the **most-recently-active story**. If no story is active, the most-recently-active epic is used.

**Recency** is defined as the later of:
- the timestamp of the last `ticket transition` event on the ticket, or
- the timestamp of the last `ticket comment` on the ticket.

**Same-timestamp tiebreak**: lexicographic ordering by ticket ID (ascending), last ticket ID wins.

Only one `ticket_id` is recorded per defense record. The tiebreak is resolved by the orchestrator before calling `write()`.

---

## Example Payload

```json
{
  "prior_finding_id": "finding-0042",
  "cited_lines_fingerprint": "a3f9c2d1e4b78f60123456789abcdef0a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6",
  "defense_text": "The null check on line 87 is guarded by the caller contract — callers in this module guarantee non-null per the module-level invariant documented in the module header. No defensive null check is needed here.",
  "defender": "dso:code-reviewer-standard",
  "cycle_number": 2,
  "timestamp": "2026-05-11T14:32:00Z",
  "severity_history": [
    {"cycle": 1, "severity": "important", "relation": null},
    {"cycle": 2, "severity": "important", "relation": "DEFENDED"}
  ],
  "ticket_id": "7597-3b9c-8d56-4f54",
  "story_branch_tip_sha": "a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0",
  "story_branch_base_sha": "0f1e2d3c4b5a6978869758647362514039281706"
}
```

**Legacy record (pre-2026-05-11, diff_hash only — no SHA-range fields):**
```json
{
  "prior_finding_id": "finding-0042",
  "cited_lines_fingerprint": "a3f9c2d1e4b78f60123456789abcdef0a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6",
  "defense_text": "The null check on line 87 is guarded by the caller contract — callers in this module guarantee non-null per the module-level invariant documented in the module header. No defensive null check is needed here.",
  "defender": "dso:code-reviewer-standard",
  "cycle_number": 2,
  "timestamp": "2026-05-07T14:32:00Z",
  "severity_history": [
    {"cycle": 1, "severity": "important", "relation": null},
    {"cycle": 2, "severity": "important", "relation": "DEFENDED"}
  ],
  "ticket_id": "7597-3b9c-8d56-4f54"
}
```

**With arbiter ruling (TrackerDefenseStore — full summary):**
```json
{
  "prior_finding_id": "finding-0042",
  "cited_lines_fingerprint": "a3f9c2d1e4b78f60123456789abcdef0a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6",
  "defense_text": "The null check on line 87 is guarded by the caller contract ...",
  "defender": "dso:code-reviewer-standard",
  "cycle_number": 2,
  "timestamp": "2026-05-07T14:32:00Z",
  "severity_history": [
    {"cycle": 1, "severity": "important", "relation": null},
    {"cycle": 2, "severity": "important", "relation": "DEFENDED"}
  ],
  "arbiter_ruling": {
    "ruling": "DEFER",
    "summary": "The module-level caller contract is clearly documented and consistently enforced across all call sites. Finding is deferred to next review cycle.",
    "arbiter_cycle": 3,
    "schema_version": "1.0.0"
  },
  "ticket_id": "7597-3b9c-8d56-4f54"
}
```

**With arbiter ruling (GitHubPRDefenseStore — 1–2 sentence summary with link):**
```json
{
  "arbiter_ruling": {
    "ruling": "DEFER",
    "summary": "Finding deferred: caller contract is well-documented and enforced. [Full ruling in CI log](https://ci.example.com/runs/12345#arbiter-ruling-0042)",
    "arbiter_cycle": 3,
    "schema_version": "1.0.0"
  }
}
```

### Retired Arbiter Ruling Values

The following ruling values from the pre-cycle-end arbiter (per-finding severity-dispute arbiter) are retired as of the cycle-end arbiter schema:

| Old Value | Mapped To | Notes |
|-----------|-----------|-------|
| `SUSTAIN_AT_SEVERITY` | `DEFER` | Finding persists; reviewer severity claim stands; maps to DEFER at cycle-end |
| `ACCEPT_DEFENSE` | `DROP` | Defense accepted; finding resolved; maps to DROP at cycle-end |
| `DOWNGRADE_TO_<severity>` | `DEFER` | Severity adjusted but finding not resolved; maps to DEFER with severity adjustment |

**Schema version**: The cycle-end arbiter output schema is `schema_version: "1.0.0"` (matches cycle-ledger convention from story aead-ae88). Records written by the old severity-dispute arbiter do not include `schema_version`; records written by the new cycle-end arbiter include `schema_version: "1.0.0"` in the `arbiter_ruling` sub-object.

**Transition policy**: Old ruling values (`SUSTAIN_AT_SEVERITY`, `ACCEPT_DEFENSE`, `DOWNGRADE_TO_*`) are rejected by the new arbiter validation (`validate_cycle_end_ruling` in `dso_ci_review/arbiter.py`). Defense store readers that encounter old ruling values in records written before the cycle-end arbiter shipped must handle them gracefully (log + skip, as documented in the Failure Contract section).

---

## Two-Tier Promotion Gate

Establishes the load-bearing review gate for code reaching `main`. This contract is the design rationale for the post-PR-R1 verifier behavior and the ruleset scoping decisions in `provision-ruleset.sh`.

### Topology

```text
feature-branch / worktree-<ts>  (unrestricted: no ruleset, push freely)
    ↓ PR1 — review-sub-pr workflow required (sub-PR ruleset, ID 16961402)
staged-<short-sha>-<unix-ts>     (ephemeral; created from main HEAD on session close)
    ↓ PR2 — check-staged-head + standard required checks (main ruleset, ID 15629023)
main
```

### Invariants

1. **PR1 is the comprehensive review gate.** The sub-PR ruleset targets `refs/heads/staged-*` and requires `review-sub-pr` to pass on every PR landing into a `staged-*` branch. Every commit reaching `main` has passed through review-sub-pr at PR1 time.
2. **Main only accepts `staged-*` heads.** The main ruleset's `check-staged-head` required check fails any PR to main whose head doesn't match the `staged-*` pattern.
3. **Pushes to `staged-*` branches are unrestricted at ref-update time** (`do_not_enforce_on_create: true`), enabling the `_create_staged_ref` helper in `merge-to-main-pr.sh` to fast-create the ref from `origin/main` HEAD. The required status check fires at PR-merge time.
4. **Direct commits to `main` are impossible.** No bypass channel under `bypass_mode: pull_request`; admin bypass at PR-merge time produces a visible PR-time audit-trail entry.

### What this contract means for `verify-session-provenance.sh`

Because PR1 has already verified `review-sub-pr` for every worktree commit, the verifier's covering-PR API lookup at PR2 time finds PR1 with `review-sub-pr=success` for each commit in `BASE_SHA..SESSION_HEAD`. Under v4 (PR-R1), the verifier no longer parses `DSO-Story(-Merge):` trailers for provenance — the trailer was a self-attested claim, not evidence. The trailer remains in commit messages as human-readable attribution metadata.

### Drift detection

`tests/scripts/test-ruleset-design-invariants.sh` (wired into CI via `.github/workflows/ruleset-invariants.yml` as a required check) asserts the live ruleset state against the design invariants above. Any drift — sub-PR ruleset broadened to `~ALL`, `check-staged-head` removed from main's required list, bypass_mode reverted to `always` — fails the check and blocks the PR that caused the drift.

### Anti-pattern: do NOT broaden the sub-PR ruleset to `~ALL minus main`

A previous design used `include=["~ALL"]` with `exclude=["refs/heads/main"]`. That re-introduces the chicken-and-egg where pushing any new feature branch is blocked because `review-sub-pr` cannot run before a PR exists. The `staged-*` scoping plus `do_not_enforce_on_create: true` is the resolution; the operator-warning comment block above `SUB_PR_INCLUDE_JSON` in `provision-ruleset.sh` is there to prevent regression.

---

## Runner Exit Code Contract

The `dso_ci_review.runner.main()` function uses three exit codes to communicate the review outcome to the CI workflow's "Classify llm-review failure" step:

| Exit code | Meaning | CI workflow action |
|-----------|---------|---------------------|
| `0` | Review passed — no blocking findings, no infra failure | Step succeeds; no annotation |
| `1` | Review failed with usable content — typically blocking findings (critical / important / fragile) from the severity gate or arbiter ruling. Also covers a small set of other partial-failure paths (OVER_BOUND admin route, schema-correction exhaustion). | Step fails with `::error::llm-review failed (exit 1)` and a hint to read findings JSON / stderr |
| `4` | Infrastructure failure — no valid review content produced (all specialists crashed, all findings synthetic, runner-level exception, agent file missing, provider config/auth error, empty diff in PR context, schema validator process error) | Step fails with `::error::llm-review infrastructure failure (exit 4)` |

**R4 (bug f148 PR-C)**: prior behavior returned `1` for both "blocking findings" and "infrastructure failure", indistinguishable to operators. Exit code `4` was introduced to separate the two so the CI annotation correctly directs operators (look at the diff for `1`; look at the LLM-provider / runner state for `4`).

**Config gate**: `DSO_INFRA_EXIT_CODE_ENABLED` (default `1`). Set to `0` to roll back to legacy "all infra failures return 1" behavior — useful if the Classify step has a bug or hasn't been deployed yet. The runner reads this at exit time, so a rollback is a single env-var flip with no code change.

**Code paths returning `4`** (when the gate is enabled):
- Runner-level unhandled exception (outer `except Exception` in `main()`)
- All-specialist-errors detected pre-schema-validation (Step 7a.5)
- All-specialist-errors detected post-cycle-action (severity gate)
- All-synthetic findings (`specialist_error` / `fallback_exhausted` / `parse_error` only)
- Required agent files missing at startup (`_validate_agent_files` raised)
- Provider config / auth failure at startup (`ConfigError` / `AuthError` from `get_provider`)
- Empty diff received in PR context (caller wiring break)
- Schema validator subprocess failure (`validator_error` status)

Schema-correction failure paths continue to return `1` — those represent a partially-failed review (real specialist findings produced, malformed output that schema-correction couldn't repair), not an absence of review content.

---

## Failure Contract

| Condition | Behavior |
|-----------|----------|
| `ticket_id` is `UNBOUND` or absent at `write()` time | Exit code 1; stderr contains literal string `ticket-binding required` |
| `defense_text` exceeds 4096 Unicode codepoints | `write()` rejected with error; record not persisted; caller must truncate or shorten before retrying |
| `severity_history` is empty or absent | `write()` rejected with error; at least one entry is required |
| `cited_lines_fingerprint` is absent or malformed | `write()` rejected with error; orchestrator must compute a valid SHA-256 hex string before calling `write()` |
| `arbiter_ruling.ruling` is not in `{BLOCK, DEFER, DROP}` | Record stored as-is with a warning to stderr; defense store readers that do not recognize the ruling value log and skip it. Legacy values (`SUSTAIN_AT_SEVERITY`, `ACCEPT_DEFENSE`, `DOWNGRADE_TO_*`) from pre-cycle-end arbiter records are treated as unrecognized values. |
| Backend storage failure (ticket comment write fails, PR API error) | `write()` raises an error; caller is responsible for retry or escalation; no partial writes |
| Fork PR (no write access to base repo PR comments) | GitHubPRDefenseStore `write()` is a no-op for fork PRs; returns success silently; defense records are not persisted for fork-origin PRs |

---

### Canonical parsing prefix

Defense records are stored as ticket comments (TrackerDefenseStore) or PR comments (GitHubPRDefenseStore). Parsers identify defense records by the literal prefix:

```
DEFENSE_RECORD: 
```

(The prefix is the string `DEFENSE_RECORD: ` — ten characters plus a colon and space.) Everything after the prefix is a JSON object conforming to this contract's record shape. Parsers MUST:

1. Match lines starting with exactly `DEFENSE_RECORD: ` (case-sensitive; colon required; trailing space required before JSON).
2. Parse the remainder as a JSON object. Lines that do not parse as valid JSON are silently skipped (corrupt or truncated records).
3. Never treat a line containing `DEFENSE_RECORD:` without the trailing space as a valid record.

---

## Consumers

| Component | Role | Notes |
|-----------|------|-------|
| REVIEW-WORKFLOW.md orchestrator | Writer (via TrackerDefenseStore) | Writes defense records during local `/dso:review` resolution cycles |
| CI llm-review job | Writer (via GitHubPRDefenseStore) | Writes defense records during CI pipeline review cycles |
| REVIEW-WORKFLOW.md orchestrator Step 4a | Reader | Reads existing defenses via `load_for_region` before dispatching reviewers to suppress re-raises on stable fingerprints |
| SC1 telemetry pipeline | Reader | Reads `severity_history` from all defense records for drift and oscillation detection |
| Arbiter agents | Writer (updating records) | Append `arbiter_ruling` to existing records after arbitration |

All implementors must read this contract before modifying any defense-store write path, resolution agent prompts, or the REVIEW-WORKFLOW.md Step 4a parser logic. Changes to the record shape require updating all writers and readers and this document atomically in the same commit.

---

## Schema Migration

### SHA-range attestation fields (introduced 2026-05-11)

Records written **before 2026-05-11** use `diff_hash`-only attestation. They do not contain `story_branch_tip_sha` or `story_branch_base_sha`. When the loader encounters such a record during `load_for_region`:

1. It emits a warning to stderr containing the literal string `legacy attestation`.
2. It falls back to `diff_hash` matching against the current diff hash for the region.
3. The record is included if the `diff_hash` matches; otherwise excluded.

Records written **on or after 2026-05-11** include both `story_branch_tip_sha` and `story_branch_base_sha` in addition to any existing fields. These records are validated using the SHA-range conditions described in `load_for_region` above. The `diff_hash` field is still included in new records for cross-version compatibility; loaders that do not support SHA-range validation will fall back to it transparently.

Both record formats coexist in the same store. The loader handles both transparently — no migration of existing records is required.

---

## Versioning

This contract is versioned. Breaking changes (field removal, type changes, algorithm changes to `cited_lines_fingerprint`) require updating all writers, readers, and this document atomically in the same commit. Additive field additions that do not affect existing required fields are backward-compatible.

### Change Log

- **2026-05-07**: Initial version — defines DefenseStore record shape, two-backend split (TrackerDefenseStore / GitHubPRDefenseStore), cited_lines_fingerprint SHA-256 computation algorithm, durable binding contract, ticket-binding integrity rule, multi-bound session tiebreak, `load_for_region` interface, and failure contract.
- **2026-05-11**: Added SHA-range attestation fields (`story_branch_tip_sha`, `story_branch_base_sha`) to the record shape; extended `load_for_region` with `query_sha` parameter and two-condition OR ancestry-path validation (Condition A: in-range linear chain, Condition B: post-merge); defined legacy fallback contract (`diff_hash` lookup with `legacy attestation` stderr warning) for records lacking SHA fields; added Schema Migration section documenting the two-era record formats and transparent loader handling.
- **2026-05-15**: Added optional `cited_lines` field (array of `path:lineno` strings) to DefenseRecord shape. Copied from the finding being defended at defense assembly time. Enables ±5-line proximity-matching suppression in `_suppress_defended_findings`. Absent on legacy records; falls back to description-prefix matching.
- **2026-05-16**: Updated arbiter_ruling sub-schema to cycle-end BLOCK/DEFER/DROP ruling enum. Retired old severity-dispute ruling values (SUSTAIN_AT_SEVERITY, ACCEPT_DEFENSE, DOWNGRADE_TO_*) with migration mapping. Added schema_version field to arbiter_ruling. Update Change Log with 2026-05-16 entry and Failure Contract row for unrecognized rulings. See story 0652-809a-d1fc-4d36 (S3) and epic b575-ac1c-f720-4839.
- **2026-05-17**: Bumped arbiter_ruling.schema_version to 1.1.0. Added required enum-array fields cross_reviewer_agreement (4-val), cross_cycle_pattern (7-val), and impact_class (9-val, 8-cat floor + 'none'). BLOCK-gate AND-logic extended with impact_class floor enforcement. See story 62c9-46f5-f287-4c24 (epic b575-ac1c-f720-4839).
