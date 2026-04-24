# Enrich-in-Place Path

Use this path when the Type Detection Gate's Option (b) is chosen — enriching an existing non-epic ticket with structured acceptance criteria, approach, and file paths **without** converting it to an epic.

**Ticket type is preserved throughout this path — do not convert, close, or recreate the original ticket.**

## Step 1 — Load ticket content

Run `.claude/scripts/dso ticket show <ticket-id>` and read the existing description, title, and type. Summarize what is already defined so the dialogue is targeted, not redundant.

## Step 2 — Streamlined Socratic dialogue

Ask **1–3 targeted questions** to clarify intent — this is NOT the full Phase 1 multi-area probe. Use one question at a time (same rule as Phase 1). Focus only on gaps that prevent writing structured acceptance criteria or a clear approach. Good targets:

- "What does done look like?"
- "Which file or module is the entry point?"
- "Are there edge cases that matter?"

Stop asking once you can draft meaningful acceptance criteria and an approach summary.

## Step 3 — Update the ticket description

Update the existing ticket's description field using `ticket edit --description` — do not post a comment. Replace the description with enriched content including:

- Structured acceptance criteria (Given/When/Then format or bullet checklist)
- An approach summary (1–2 sentences on how to implement this)
- Relevant file paths (use Glob/Grep to resolve any module or directory references from the ticket to actual repo paths; include only paths that exist)

```bash
.claude/scripts/dso ticket edit <id> --description="
Summary: [Original or refined one-sentence summary of the ticket]

Acceptance Criteria:
- Given [context], when [action], then [outcome]
- [ ] [Verifiable condition 1]
- [ ] [Verifiable condition 2]

Approach Summary:
[1-2 sentences on how to implement this — the concrete mechanism, not just the goal]

Relevant Files:
- path/to/relevant/file.py
- path/to/another/module.sh
"
```

## Step 4 — Present and stop

Present the updated ticket content to the user and stop. Do not route to downstream skills.

## Explicitly skipped

These apply to the full brainstorm → epic flow only, not this path:

- Skip fidelity review (Step 2.5/3 gap analysis and reviewer agents)
- Skip scenario analysis (Step 2.75 red/blue team review)
- Skip web research phase (Step 2.6)
- Skip ticket creation (Phase 3) — the ticket already exists
- Skip complexity evaluation (Phase 3, complexity evaluator dispatch)
- Skip routing to downstream skills — do not invoke `/dso:preplanning` or `/dso:implementation-plan`
- Skip writing the brainstorm completion sentinel (Step 3b)

**REVIEW-DEFENSE**: enrich-in-place is used on existing tickets that are already defined, not on new features being scoped from scratch. The brainstorm-before-plan-mode enforcement is designed to ensure new ideas are properly scoped before entering plan mode. When enriching an existing ticket, the user is refining something already in the system — not discovering and framing a new feature — so the sentinel gate correctly does not apply to this path.
