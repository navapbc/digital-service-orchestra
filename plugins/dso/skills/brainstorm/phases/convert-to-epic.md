# Convert-to-Epic Path

Use this path when the Type Detection Gate's Option (a) is chosen — converting a non-epic ticket (`story`, `task`, `bug`) into a new, well-defined epic via the full brainstorm flow.

**Summary:** (1) Record the original ticket's content for seeding. (2) Run the full brainstorm flow (Phases 1–3) to create a new epic. (3) Only after the new epic is successfully created, close the original ticket. (4) Reference the original ticket ID on the new epic for traceability.

## Step 1 — Note the original ticket

Run `.claude/scripts/dso ticket show <original-ticket-id>` and capture the title, description, and comments. This content seeds Phase 1.

## Step 2 — Proceed to Phase 1 with seeding context

Begin Phase 1 (Context + Socratic Dialogue) with the original ticket's content as seeding material. Do NOT close the original ticket yet.

## Step 3 — Complete the full brainstorm flow

Run Phases 1, 2, and 3 in full. The new epic is "successfully created" when Phase 3 Step 1 (`ticket create epic ...`) completes without error and returns a new epic ID.

## Step 4 — Close the original ticket (ONLY AFTER new epic is successfully created)

```bash
.claude/scripts/dso ticket transition <original-ticket-id> <current-status> closed \
  --reason="Escalated to user: superseded by epic <new-epic-id>"
```

The `--reason` flag is required. Bug tickets must use the `Escalated to user:` prefix — omitting it causes a silent failure.

## Step 5 — Add traceability reference to the new epic

```bash
.claude/scripts/dso ticket comment <new-epic-id> \
  "Converted from original ticket <original-ticket-id> (reference original ticket ID for traceability)."
```

## Edge case — tickets with open children

If the original ticket has open child tickets, handle them before closing:
- Re-parent open children to the new epic: `.claude/scripts/dso ticket link <child-id> <new-epic-id> depends_on`, OR
- Close irrelevant children with `--reason="Escalated to user: superseded by epic <new-epic-id>"`

Only after all open children are resolved, proceed with Step 4.
