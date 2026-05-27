# Contract: Obligation Ticket Schema

## Purpose

Contract for **rollout obligation tickets** auto-created by `dso:completion-verifier`
when a story Done Definition (DD) defers its validation evidence to operator execution
at rollout-time (or any post-merge moment).

This schema exists because epic `4047` closed with `P1=PASS` even though four of its
DDs read "deferred to operator execution per runbook" — and the "operator" role
does not run pre-merge. Deferred validation effectively meant skipped validation.
Bug `1761-21ca-cb74-44a6` captured the meta-bug; this schema is the structural fix.

## Trigger

The verifier scans each DD's evidence text against the regex:

```
\b(deferred|defer)\s+to\s+(operator|rollout|post.?merge|operator.?execution)\b
```

Case-insensitive. A match means the DD is not satisfied at closure time by
pre-merge evidence — it owes a future verification act. The verifier MUST then
create an obligation ticket parented to the story.

## Ticket fields

| Field         | Value                                                            |
|---------------|------------------------------------------------------------------|
| `type`        | `task`                                                           |
| `parent_id`   | The story id whose DD triggered the obligation                   |
| `priority`    | 2                                                                |
| `title`       | `Obligation: rollout-time validation for story <parent-story-id>` |
| `tags`        | MUST include `obligation:rollout` AND the parent epic id         |

The parent epic id is read from the story ticket's own `parent_id`. The tags
allow `obligation-monitor` to find all open obligations regardless of project
or epic.

## Description body (verbatim template)

```
## Obligation

Parent story: <parent-story-id>
Deadline: <ISO-8601 date — default = creation date + 30 days>
Owner: operator
Validation command: <verbatim command from the deferred DD>

Closure:
- comment with output of validation command
- transition to closed via `.claude/scripts/dso ticket transition <id> open closed`

This obligation was auto-created by `dso:completion-verifier` because the DD
"<verbatim DD text>" deferred its validation to operator execution. The
operator is responsible for running the validation command before the
deadline and recording the result on this ticket. If the deadline passes,
`obligation-monitor` will file a P1 bug parented to the originating story.
```

The `Deadline:` line MUST be parseable by the regex `Deadline:\s*(\d{4}-\d{2}-\d{2})`.

The `Validation command:` line MUST be parseable by the regex
`Validation command:\s*(.+)$` (one line; multi-line commands MUST be expressed
as a single line with `&&` separators).

## Verifier output extension

When the verifier creates one or more obligations, the output JSON gains an
`obligations_created` field — an array of ticket ids:

```json
{
  "obligations_created": ["abcd-1234-5678-9abc", "..."],
  ...
}
```

The verifier emits `P1=PASS` only if every required obligation was created
successfully. If `ticket create` exits non-zero for any obligation, the
verifier MUST emit `P1=FAIL` with a `criteria_results` entry whose
`evidence_found` field reads `obligation_creation_failed: <reason>`.

## Lifecycle

1. Verifier creates the obligation at story close.
2. Operator runs the validation command post-merge / at rollout.
3. Operator comments the command output on the obligation ticket.
4. Operator transitions the obligation `open → closed`.
5. If the deadline passes with the obligation still open, the obligation
   monitor (`${CLAUDE_PLUGIN_ROOT}/scripts/dso_reconciler/check-obligations.sh`) files
   a P1 bug parented to the obligation's parent story.

## Backfill policy

Existing closed stories whose DDs match the deferred-evidence regex MAY be
backfilled with obligations retroactively, but the schema does not REQUIRE
backfill. Per-epic backfill decisions live in the epic's ticket comments.
For epic 4047 / story 83ac, the four deferred DDs are subsumed by epic
`3e36-a1b8-4671-450c` story 4 (live phased rollout), recorded as a comment
on story 83ac rather than as four duplicate obligation tickets.
