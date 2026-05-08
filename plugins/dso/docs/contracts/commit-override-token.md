# Contract: commit-override-token

- Signal Name: commit-override-token
- Status: accepted
- Scope: commit-override.sh → post-commit-override-cleanup.sh (commit workflow override path)
- Date: 2026-05-08

## Purpose

This document defines the override token written when a user invokes the commit override path (e.g., via `dso commit-override`). The token records the diff hash, user-supplied reason, timestamp, and attribution for the override invocation. It is consumed (deleted) by the post-commit cleanup hook after a successful commit, ensuring the override is single-use per invocation. Dry-run hook invocations must NOT consume the token. Each use also appends a JSON Lines entry to a persistent override log for audit purposes.

---

## Signal Name

`commit-override-token`

---

## Schema

The token is a single JSON object written to `$ARTIFACTS_DIR/override.token`. All fields are required unless noted otherwise.

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `diff_hash` | string | yes | First 12 characters of the SHA-256 hex digest of the `git diff --cached` output at override invocation time. Binds the token to the specific staged diff. |
| `reason` | string | yes | User-supplied `--reason=` argument text. Must be non-empty; the override command rejects a missing or empty reason. |
| `timestamp` | string | yes | ISO 8601 UTC timestamp of when the token was written (e.g., `2026-05-08T17:00:00Z`). |
| `attribution` | object | yes | Reserved for future population. Currently null-initialized. Shape: `{skill_name: string \| null, agent_id: string \| null}`. Both sub-fields are null placeholders until attribution tracking is implemented. |

---

## Storage

- **Path**: `$ARTIFACTS_DIR/override.token`
- **Format**: a single JSON object (not JSON Lines).
- **Overwrite behavior**: each invocation of `commit-override.sh` overwrites any existing `override.token`. Only the most recent override invocation is retained.

---

## Lifecycle

1. **Created** by `commit-override.sh` immediately before the commit proceeds. The file is written atomically (write to a temp file then rename) to prevent partial reads by hook scripts.
2. **Consumed (deleted)** by `post-commit-override-cleanup.sh` after a successful commit. Deletion confirms the override was used and prevents the same token from authorizing a future commit.
3. **NOT consumed** by dry-run hook invocations. Hooks that execute in dry-run mode (e.g., during pre-commit checks without a real commit) must leave `override.token` in place. Only the post-commit cleanup hook — which runs exclusively on a real successful commit — is permitted to delete the token.
4. **Stale token**: if a commit fails (non-zero exit), `post-commit-override-cleanup.sh` does not run and the token remains. A stale token does not authorize subsequent commits automatically; `commit-override.sh` must be re-invoked, which overwrites the token with a new `diff_hash` for the new staged state.

---

## Override Log

In addition to writing `override.token`, each invocation of `commit-override.sh` appends a JSON Lines entry to `$ARTIFACTS_DIR/commit-overrides.log`. Each log entry conforms to the same schema as the token object, plus the `diff_hash` from the invocation:

```
{"diff_hash":"<first12>","reason":"<reason>","timestamp":"<iso8601>","attribution":{"skill_name":null,"agent_id":null}}
```

The log is append-only; entries are never removed. It provides a persistent audit trail of all override invocations within the session/artifacts context.

---

## Example Token

```json
{
  "diff_hash": "a3f9c2d1e4b7",
  "reason": "Docs-only change; review gate not applicable to markdown edits",
  "timestamp": "2026-05-08T17:00:00Z",
  "attribution": {
    "skill_name": null,
    "agent_id": null
  }
}
```

---

## Example Log Entry (`commit-overrides.log`)

```
{"diff_hash":"a3f9c2d1e4b7","reason":"Docs-only change; review gate not applicable to markdown edits","timestamp":"2026-05-08T17:00:00Z","attribution":{"skill_name":null,"agent_id":null}}
```

---

## Failure Contract

| Condition | Behavior |
|-----------|----------|
| `--reason` is absent or empty | `commit-override.sh` exits non-zero; token is NOT written; commit does not proceed |
| `$ARTIFACTS_DIR` is unset or does not exist | `commit-override.sh` exits non-zero with an error message; token is NOT written |
| Token write fails (disk full, permission error) | `commit-override.sh` exits non-zero; commit does not proceed |
| Dry-run hook reads token | Token is read for validation only; it is NOT deleted; subsequent real commit still finds the token |
| `post-commit-override-cleanup.sh` fails to delete token | Logged as a warning; commit result is not affected; operator should manually remove stale token |

---

### Canonical parsing prefix

The override token is a JSON file (not a line-prefixed signal). Consumers locate it by the well-known path `$ARTIFACTS_DIR/override.token`. Parsers must:

1. Check for file existence at `$ARTIFACTS_DIR/override.token`
2. If present, deserialize as a single JSON object and validate required fields: `diff_hash`, `reason`, `timestamp`, `attribution`
3. No line-prefix string matching applies — the entire file is one JSON object

The audit log at `$ARTIFACTS_DIR/commit-overrides.log` is JSON Lines; each line is a complete JSON object conforming to the same schema. Consumers parse line-by-line.

---

## Consumers

| Component | Role | Notes |
|-----------|------|-------|
| `commit-override.sh` | Writer | Creates `override.token` and appends to `commit-overrides.log` on each invocation |
| Pre-commit hook (override path) | Reader | Reads `override.token` to verify the diff_hash matches current staged diff before allowing the commit to proceed |
| `post-commit-override-cleanup.sh` | Consumer (deleter) | Deletes `override.token` after successful commit; does NOT run on dry-run invocations |

All implementors must read this contract before modifying `commit-override.sh`, the pre-commit hook override path, or `post-commit-override-cleanup.sh`.

---

## Versioning

This contract is unversioned. Breaking changes (field removal, type changes) require updating all writers, readers, and this document atomically in the same commit. Additive field additions are backward-compatible.

### Change Log

- **2026-05-08**: Initial version — defines token schema ({diff_hash, reason, timestamp, attribution}), storage path, lifecycle (create/consume/dry-run exclusion), and override log format.
