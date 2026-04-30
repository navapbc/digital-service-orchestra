# Consumer Migration Audit — Epic 3e74-56da
# Ticket-create stdout format: `ticket create` now emits two lines on stdout
# (human summary first, canonical ID last). All consumers must use `| tail -1`
# to extract the canonical ID.

## Scope

This document is the grep audit log for `rg '[0-9a-f]{4}-[0-9a-f]{4}'` call sites
in SKILL.md files and plugin scripts that consume the output of `.claude/scripts/dso
ticket create`. Required by SC5 of epic 3e74-56da.

## Call Sites

### plugins/dso/skills/create-bug/SKILL.md — line 33, 55

```
BUG_CREATE_OUT=$(.claude/scripts/dso ticket create bug \
  "[Component]: [Condition] -> [Observed Result]" \
  ... 2>"$BUG_CREATE_ERR_FILE")
BUG_TICKET_ID=$(echo "$BUG_CREATE_OUT" | tail -1)
```

**Migration status: migrated** — uses `| tail -1` to extract ID. The summary line
now goes to stdout but `tail -1` is unaffected.

### plugins/dso/skills/debug-everything/SKILL.md — line 373, 375

```
BUG_CREATE_OUT=$(.claude/scripts/dso ticket create bug "..." 2>/tmp/ticket_create_stderr.tmp)
NEW_TICKET_ID=$(echo "$BUG_CREATE_OUT" | tail -1)
```

**Migration status: migrated** — uses `| tail -1` to extract ID.

### plugins/dso/skills/fix-bug/SKILL.md — line 162, 164

```
BUG_CREATE_OUT=$(.claude/scripts/dso ticket create bug "..." 2>/tmp/ticket_create_stderr.tmp)
BUG_TICKET_ID=$(echo "$BUG_CREATE_OUT" | tail -1)
```

**Migration status: migrated** — uses `| tail -1` to extract ID.

### plugins/dso/skills/onboarding/SKILL.md — line 1537

```
TEST_ID=$(.claude/scripts/dso ticket create task "DSO smoke test — delete me" 2>/dev/null | tail -1)
```

**Migration status: migrated** — uses `| tail -1` inline; `2>/dev/null` suppresses
the summary that previously appeared on stderr (now on stdout, but `tail -1` still
extracts the ID correctly).

### plugins/dso/skills/preplanning/SKILL.md — line 568

```
STORY_ID=$(.claude/scripts/dso ticket create story "As a [persona], [goal]" ... -d "$(cat <<'DESCRIPTION'
...
DESCRIPTION
)" | tail -1)
```

**Migration status: migrated** — `| tail -1` added inside the outer `$(...)` before
the closing `)`, after the heredoc substitution closes; extracts canonical ID from
the two-line stdout.

### plugins/dso/skills/implementation-plan/SKILL.md — line 757

```
TASK_ID=$(.claude/scripts/dso ticket create task "{title}" --parent=<story-id> ... -d "$(cat <<'DESCRIPTION'
...
DESCRIPTION
)" | tail -1)
```

**Migration status: migrated** — same heredoc pattern as preplanning; `| tail -1`
added before the outer closing `)`.

### plugins/dso/scripts/end-session/error-sweep.sh — line 207

```
new_id=$("$TICKET_CMD" create bug "$ticket_title" --priority 2 | tail -1) || true
```

**Migration status: migrated** — `| tail -1` added; the subsequent `ticket comment "$new_id"` call
now receives the canonical ID rather than the two-line stdout string.

### plugins/dso/hooks/resolve-overlay-findings.sh — lines 161–163

```
ticket_id=$(
    "$TICKET_CMD" create task "$_title" --priority=3 2>/dev/null | tail -1
) || ticket_id="error"
echo "OVERLAY_TICKET_CREATED:$ticket_id"
```

**Migration status: migrated** — `| tail -1` added; the `OVERLAY_TICKET_CREATED:` output line now
contains the canonical ID rather than the two-line summary+ID string.

## Non-Skill Call Sites

The following call sites in scripts do not capture ticket create output (they
only invoke it for its side effects or discard output) and require no change:

- `plugins/dso/scripts/agent-batch-lifecycle.sh:437` — comment only, no live invocation
- `plugins/dso/skills/brainstorm/SKILL.md:378` — invocation without ID capture (the
  output ID is implicitly the brainstorm epic; epic-select logic reads it from the
  tickets branch)
- `plugins/dso/skills/roadmap/SKILL.md:237` — invocation without ID capture
- `plugins/dso/skills/preplanning/SKILL.md:391` — table cell example only, not a
  live invocation (no variable capture)

## Summary

All 8 known consumers of `ticket create` output that capture the canonical ID
have been migrated to `| tail -1`: 6 skill-file consumers and 2 script-level
consumers (error-sweep.sh, resolve-overlay-findings.sh). No consumer is broken
by the SC3 change (summary moved from stderr to stdout). The `2>...` stderr
redirects in create-bug and fix-bug SKILL.md remain valid for capturing actual
error messages (which remain on stderr).
