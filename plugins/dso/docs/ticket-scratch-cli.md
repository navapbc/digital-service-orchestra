# Ticket Scratch CLI Reference

Authoritative reference for the `dso ticket scratch` subcommands and the `--include-scratch` flag on `dso ticket show`.

Scratch storage is an **ephemeral, off-context key/value store** attached to a ticket. It lets orchestrator agents stash large handoff payloads between steps without polluting the ticket event log or the context window.

> **Isolation**: scratch files live at `.claude/scratch/<ticket_id>/<key>` in the main repo, are excluded from the `tickets` orphan branch via `.git/info/exclude` (never committed to git history), and are never read by the Jira reconciler. Per-ticket scratch directories are removed automatically on close and archive (story c7f3-1faf-6bb4-4ed7).

---

## Synopsis

```
.claude/scripts/dso ticket scratch set   <ticket_id> <key> <value>
.claude/scripts/dso ticket scratch get   <ticket_id> <key>
.claude/scripts/dso ticket scratch clear <ticket_id> [<key>]
.claude/scripts/dso ticket show --include-scratch <ticket_id>
```

---

## Key-Namespace Convention

Keys **MUST** follow the `<skill>:<step>:<purpose>` naming pattern:

```
implementation-plan:step2:arch-review-draft
sprint:step18:batch-plan
```

**Rationale**: Multiple orchestrator skills share the same per-ticket scratch namespace. The `<skill>` prefix prevents key collisions when two skills operate on the same ticket in sequence. The `<step>` segment scopes the key to a specific phase within that skill, making keys self-documenting and enabling targeted `clear` calls at phase boundaries.

**Charset rules** (enforced by `_scratch_resolve_and_validate` in `ticket-lib.sh`):

| Rule | Detail |
|------|--------|
| No empty string | `ticket_id` and `key` must be non-empty |
| No leading dot | Must not start with `.` |
| No path traversal | Must not contain `..` |
| No slash | Must not contain `/` |
| No control characters | No bytes in range `0x00`–`0x1F` |

**Max-byte ceiling**: 98304 bytes (96 KB) per value (configurable via `_scratch_atomic_write`'s `max_bytes` argument; default 98304). Empirically sized against 200 closed+archived epics (P99 story-decomposer payload ~72KB, historical max ~91KB at epic `dbbc-cf67`). Overflow is signalled by a structured error envelope rather than silent truncation. The cap remains bounded so multi-MB payloads route via filesystem path (with a pointer in scratch) rather than inflating the tickets-tracker disk. See bug 3e82 for the migration history (4096 → 32768 → 98304).

---

## Migration Sites

The following 5 call sites have been identified as consumers of scratch storage. Each entry shows the file, line number, and authoritative key name in `<skill>:<step>:<purpose>` form.

| File:Line | Authoritative Key |
|-----------|-------------------|
| `${CLAUDE_PLUGIN_ROOT}/skills/implementation-plan/SKILL.md:511` | `implementation-plan:step2:arch-review-draft` |
| `${CLAUDE_PLUGIN_ROOT}/skills/implementation-plan/SKILL.md:978` | `implementation-plan:step4:plan-review-draft` |
| `${CLAUDE_PLUGIN_ROOT}/skills/implementation-plan/SKILL.md:1238` | `implementation-plan:step6:gap-analysis-draft` |
| `${CLAUDE_PLUGIN_ROOT}/skills/preplanning/SKILL.md:513` | `preplanning:step4:story-decomp-draft` |
| `${CLAUDE_PLUGIN_ROOT}/skills/sprint/SKILL.md:2332` | `sprint:step18:batch-plan` |

These sites were enumerated during story 6ba0-4a19-7810-4568 (the scratch CLI walking skeleton). The SKILL.md migration itself is tracked separately.

---

## `scratch set`

Write a key/value pair to the scratch store for a ticket.

```
.claude/scripts/dso ticket scratch set <ticket_id> <key> <value>
```

**Arguments:**

| Argument | Required | Description |
|----------|----------|-------------|
| `ticket_id` | Yes | Ticket namespace (e.g., `abcd-1234-efgh-5678`) |
| `key` | Yes | Scratch key name — must follow `<skill>:<step>:<purpose>` convention |
| `value` | Yes | Payload string to store (arbitrary JSON or plain text; max 98304 bytes / 96 KB) |

**Behavior:**

- Wraps the value in a JSON envelope: `{"ts": "<iso8601-utc>", "value": "<value>"}`
- Writes atomically via same-directory temp file + `fsync(temp)` + `rename` + `fsync(parent dir)` — crash-safe (no partial writes observable)
- On overflow (`len(value) > 98304` bytes UTF-8), emits a structured error envelope and exits non-zero without writing any file
- Creates `<SCRATCH_BASE_DIR>/<ticket_id>/` on first write

**JSON envelope shape (stored on disk):**

```json
{"ts": "2026-05-25T13:04:00Z", "value": "<arbitrary string>"}
```

**Success output** (stdout, exit 0):

```json
{"status": "ok", "ticket_id": "abcd-1234-efgh-5678", "key": "implementation-plan:step2:arch-review-draft"}
```

**Error output** (stdout, exit non-zero):

```json
{"status": "error", "code": "oversize", "limit": 98304, "actual": 102400}
{"status": "error", "code": "invalid_key", "reason": "key must not contain '/': 'bad/key'"}
```

**Exit codes:**

| Code | Meaning |
|------|---------|
| `0` | Value written atomically |
| Non-zero | Validation failure, overflow, or write error |

**Example:**

```bash
.claude/scripts/dso ticket scratch set abcd-1234-efgh-5678 \
    "implementation-plan:step2:arch-review-draft" \
    '{"verdict":"pass","findings":[]}'
# → {"status":"ok","ticket_id":"abcd-1234-efgh-5678","key":"implementation-plan:step2:arch-review-draft"}
```

---

## `scratch get`

Read a scratch value for a ticket key.

```
.claude/scripts/dso ticket scratch get <ticket_id> <key>
```

**Arguments:**

| Argument | Required | Description |
|----------|----------|-------------|
| `ticket_id` | Yes | Ticket namespace |
| `key` | Yes | Scratch key name |

**Behavior:**

- On **hit** (file exists and is non-empty): returns the stored envelope with a `"status":"hit"` wrapper; exits 0.
- On **miss** (file absent or empty): returns a miss envelope with exit 0. Callers MUST distinguish hit from miss by inspecting the `status` field — the exit code is 0 in both cases.
- On invalid `ticket_id` or `key`: returns a structured error envelope; exits non-zero.

**JSON response shapes:**

Hit (exit 0):
```json
{"status": "hit", "ts": "2026-05-25T13:04:00Z", "value": "{\"verdict\":\"pass\",\"findings\":[]}"}
```

Miss (exit 0):
```json
{"status": "miss", "ticket_id": "abcd-1234-efgh-5678", "key": "implementation-plan:step2:arch-review-draft"}
```

Error (exit non-zero):
```json
{"status": "error", "code": "invalid_key", "reason": "key must not be empty"}
```

> **Load-bearing contract**: `get` exits 0 on both hit AND miss. The `status` field is the sole signal of key presence. Do not use `$?` to branch on existence — use `jq -r .status` or equivalent.

**Exit codes:**

| Code | Meaning |
|------|---------|
| `0` | Hit or miss (check `status` field) |
| Non-zero | Validation failure or internal error |

**Example:**

```bash
result=$(.claude/scripts/dso ticket scratch get abcd-1234-efgh-5678 \
    "implementation-plan:step2:arch-review-draft")
status=$(echo "$result" | python3 -c "import json,sys; print(json.load(sys.stdin)['status'])")
if [ "$status" = "hit" ]; then
    value=$(echo "$result" | python3 -c "import json,sys; print(json.load(sys.stdin)['value'])")
    echo "Loaded draft: $value"
else
    echo "No draft found — running fresh arch review"
fi
```

---

## `scratch clear`

Remove one scratch key or the entire per-ticket scratch directory.

```
.claude/scripts/dso ticket scratch clear <ticket_id> [<key>]
```

**Arguments:**

| Argument | Required | Description |
|----------|----------|-------------|
| `ticket_id` | Yes | Ticket namespace |
| `key` | No | When provided, removes only this key. When omitted, removes the entire per-ticket scratch directory. |

**Behavior:**

- Missing target is always OK (idempotent — not an error)
- Single-key mode emits `"removed": 1` (deleted) or `"removed": 0` (already absent)
- Whole-ticket mode emits `"removed": <N>` where N is the count of files removed

**JSON response shapes:**

Single-key mode (exit 0):
```json
{"status": "ok", "ticket_id": "abcd-1234-efgh-5678", "key": "implementation-plan:step2:arch-review-draft", "removed": 1}
```

Whole-ticket mode (exit 0):
```json
{"status": "ok", "ticket_id": "abcd-1234-efgh-5678", "removed": 3}
```

**Exit codes:**

| Code | Meaning |
|------|---------|
| `0` | Cleared (or no-op) |
| `1` | Validation failure (`ticket_id` or `key` failed charset rules) |

**Example:**

```bash
# Remove a single key after a phase completes
.claude/scripts/dso ticket scratch clear abcd-1234-efgh-5678 \
    "implementation-plan:step2:arch-review-draft"

# Remove all scratch for a ticket (e.g., on manual cleanup)
.claude/scripts/dso ticket scratch clear abcd-1234-efgh-5678
```

---

## `ticket show --include-scratch`

Merge per-ticket scratch entries into the compiled ticket state output.

```
.claude/scripts/dso ticket show --include-scratch <ticket_id>
```

**Behavior:**

- Without `--include-scratch`: the `scratch` key is absent from output (backward-compatible default)
- With `--include-scratch`: a top-level `"scratch"` object is added to the ticket state. Each key in the object maps to the stored `{"ts": ..., "value": ...}` envelope
- When the scratch directory is absent or empty, `"scratch"` is `{}` (empty object — never absent when the flag is set)

**Output shape (with scratch data):**

```json
{
  "ticket_id": "abcd-1234-efgh-5678",
  "ticket_type": "task",
  "title": "...",
  "status": "in_progress",
  "scratch": {
    "implementation-plan:step2:arch-review-draft": {
      "ts": "2026-05-25T13:04:00Z",
      "value": "{\"verdict\":\"pass\",\"findings\":[]}"
    }
  }
}
```

**Output shape (no scratch data):**

```json
{
  "ticket_id": "abcd-1234-efgh-5678",
  "scratch": {}
}
```

---

## Storage Layout

```
<repo_root>/
  .claude/
    scratch/
      <ticket_id>/
        <key>          ← JSON envelope: {"ts":"<iso8601>","value":"<string>"}
```

The base directory defaults to `<REPO_ROOT>/.claude/scratch/`. Override via the `SCRATCH_BASE_DIR` environment variable (used in tests).

**Git isolation**: the `.claude/scratch/` path is added to the `tickets` worktree's local `.git/info/exclude` by `ticket-init.sh` so scratch files are never committed to git history (story beaa-9f9d-d3ae-4a83).

---

## Common Workflows

**Store a large draft between skill steps:**

```bash
.claude/scripts/dso ticket scratch set "$TICKET_ID" \
    "implementation-plan:step2:arch-review-draft" \
    "$ARCH_REVIEW_JSON"
```

**Resume from scratch on retry:**

```bash
result=$(.claude/scripts/dso ticket scratch get "$TICKET_ID" \
    "implementation-plan:step2:arch-review-draft")
if [ "$(echo "$result" | python3 -c "import json,sys; print(json.load(sys.stdin)['status'])")" = "hit" ]; then
    # Reuse prior draft
    ARCH_REVIEW_JSON=$(echo "$result" | python3 -c "import json,sys; print(json.load(sys.stdin)['value'])")
else
    # Run fresh
    ARCH_REVIEW_JSON=$(run_arch_review)
    .claude/scripts/dso ticket scratch set "$TICKET_ID" \
        "implementation-plan:step2:arch-review-draft" "$ARCH_REVIEW_JSON"
fi
```

**Clean up after a phase:**

```bash
.claude/scripts/dso ticket scratch clear "$TICKET_ID" \
    "implementation-plan:step2:arch-review-draft"
```

**Inspect all scratch for a ticket during debugging:**

```bash
.claude/scripts/dso ticket show --include-scratch "$TICKET_ID" | python3 -m json.tool
```
