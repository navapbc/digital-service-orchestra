# Lightweight Mode (loaded by /dso:preplanning when --lightweight is passed)

**Trigger**: `/dso:preplanning` invoked with the `--lightweight` flag. Lightweight mode produces an enriched epic description (done definitions + scope + considerations) without decomposing the epic into stories.

When `--lightweight` is passed:

1. **Skip Steps 3-5 of Phase A** (no children to reconcile).
2. **Skip Phase E** (Adversarial Review) entirely — lightweight mode does not create stories, so cross-story analysis is not applicable.
3. Proceed to **Phase C (abbreviated)**: Run the Risk & Scope Scan with these modifications:
   - **Run** the Concern Areas scan (Security, Performance, Accessibility, Testing, Reliability, Maintainability).
   - **Run** the qualitative override check from the epic complexity evaluator (multiple personas, UI + backend, new DB migration, foundation/enhancement candidate, external integration).
   - **Skip** split-candidate identification (no stories to split).
4. **If any COMPLEX qualitative override is discovered** that the evaluator missed:
   - Do NOT write the preplanning context file.
   - Do NOT modify the epic description.
   - Return immediately:
     ```json
     {
       "result": "ESCALATED",
       "reason": "<override name>: <explanation>",
       "recommendation": "full_preplanning",
       "epicId": "<epic-id>"
     }
     ```
5. **If no overrides discovered**, proceed to write done definitions:
   - Update the epic description with:
     - **Done Definitions**: Observable outcomes from the epic description, formatted the same way as story-level done definitions (see Phase H Step 2).
     - **Scope**: What's in and what's explicitly out.
     - **Considerations**: Flags from the abbreviated risk scan.
   - Write the preplanning context to the epic ticket as a comment (same schema as Phase H Step 6, but with an empty `stories` array) using Python subprocess to avoid ARG_MAX shell argument limits. This write is an optional cache — if it fails, log a warning and continue; do not abort the phase:
     ```python
     import json, subprocess
     payload = json.dumps(<context-dict>, separators=(",",":"))
     body = "PREPLANNING_CONTEXT_LIGHTWEIGHT: " + payload
     result = subprocess.run(
         [".claude/scripts/dso", "ticket", "comment", "<epic-id>", body],
         check=False
     )
     if result.returncode != 0:
         print("WARNING: Failed to write PREPLANNING_CONTEXT_LIGHTWEIGHT comment to epic ticket — continuing without cache write")
     ```
   Note: Lightweight mode uses the `PREPLANNING_CONTEXT_LIGHTWEIGHT:` key to avoid overwriting a full `PREPLANNING_CONTEXT:` comment. Consumers (e.g., `/dso:implementation-plan`) read `PREPLANNING_CONTEXT:` by default and only fall back to `PREPLANNING_CONTEXT_LIGHTWEIGHT:` if no full context exists.
   - Return:
     ```json
     {
       "result": "ENRICHED",
       "epicId": "<epic-id>",
       "doneDefinitions": ["<list of done definitions written>"],
       "considerations": ["<list of considerations>"]
     }
     ```
