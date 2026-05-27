# Contract: Comment Binding Schema

---

## Purpose

Defines how Jira comments map to local ticket comments for bidirectional
comment sync. Specifies the binding lifecycle, conflict resolution rules,
and the matching algorithm used by `dso_reconciler/comment_binding.py`.

---

## Comment Binding

Each local ticket comment can optionally carry a `jira_comment_id` field
that binds it to a specific Jira comment.

### Binding lifecycle

1. **Outbound create**: local comment created -> outbound sync creates Jira
   comment -> store `jira_comment_id` on local comment.
2. **Inbound create**: Jira comment detected -> inbound sync creates local
   comment with `jira_comment_id` set.
3. **Edit**: bound comment edited on either side -> sync updates the other
   side using the binding.
4. **Delete**: bound comment deleted on one side -> sync deletes on the
   other side.

### Conflict resolution

- **Local wins**: if both sides edited since last sync, local body is pushed
  outbound.
- **Tombstone**: deleted comments are NOT re-created on the next sync pass.

### Schema

Local comment event includes:

| Field              | Type                        | Description                        |
|--------------------|-----------------------------|------------------------------------|
| `body`             | `str`                       | Comment text                       |
| `author`           | `str`                       | Who wrote it                       |
| `timestamp`        | `str` (ISO 8601)            | When                               |
| `jira_comment_id`  | `str \| null`               | Jira comment ID, or null (unbound) |

### Matching algorithm

`match_comments(local_comments, jira_comments)` in
`dso_reconciler/comment_binding.py` matches by `jira_comment_id` on the
local side against `id` on the Jira side. Unmatched items are candidates
for create in the appropriate direction:

- `local_only` entries -> outbound create (push to Jira)
- `jira_only` entries -> inbound create (pull to local)
