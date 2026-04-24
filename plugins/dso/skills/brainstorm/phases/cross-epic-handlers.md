# Cross-Epic Signal Handlers

These handlers execute **after** Step 2.25 (Cross-Epic Interaction Scan) and **before** Step 2.5 of the scrutiny pipeline. They process `CROSS_EPIC_SIGNALS` by severity.

Signal routing from Step 2.25:
- **benign**: log only, no action; proceed to Step 2.5 directly
- **consideration**: execute Step 2.26 (AC injection) → Step 2.27 check → Step 2.5
- **ambiguity** or **conflict**: execute Step 2.27 (halt/resolution) before Step 2.5

---

## Step 2.26 — Consideration AC Injection

For each signal in `CROSS_EPIC_SIGNALS` where `severity = "consideration"`:

1. **Construct a structured AC** with these three required fields:
   - (a) Shared resource name: `signal.shared_resource`
   - (b) Overlapping epic ID + title: `signal.overlapping_epic_id` — `signal.overlapping_epic_title`
   - (c) Falsifiable integration constraint: `signal.integration_constraint`

2. **Deduplicate by shared resource name**: if multiple CONSIDERATION signals share the same `shared_resource` value, consolidate to a single AC (use the first or most descriptive integration_constraint).

3. **Mark as `injected` provenance**: each constructed AC carries `injected` provenance — applied before the Phase 3 clean-text strip pass.

4. **Append to the epic spec** under a new `## Cross-Epic Interactions` section (separate from `## Success Criteria`). This keeps SC Gap Check and completion verifier operating on user-authored SCs, while injected ACs are tracked independently.

If `CROSS_EPIC_SIGNALS` has no consideration-severity signals, skip this step and proceed to Step 2.27.

---

## Step 2.27 — Halt and Resolution for Ambiguity/Conflict Signals

If `CROSS_EPIC_SIGNALS` contains signals with `severity="ambiguity"` or `severity="conflict"`, halt and present them to the user for resolution before entering the scrutiny pipeline.

1. **Tag the epic** with `interaction:deferred`:
   ```bash
   .claude/scripts/dso ticket tag <epic-id> interaction:deferred
   ```

2. **If running non-interactively** (`BRAINSTORM_INTERACTIVE=false`): log `INTERACTIVITY_DEFERRED: cross-epic interaction signals require practitioner resolution. Epic tagged interaction:deferred. Re-run /dso:brainstorm <epic-id> interactively to resolve.` and exit without proceeding to Step 2.5.

3. **If running interactively**: Present the signals to the user:

   ```
   Cross-epic interaction signals detected:

   - Epic <overlapping_epic_id>: <overlapping_epic_title>
     Shared resource: <shared_resource>
     Signal severity: <conflict | ambiguity>
     Description: <description>
     Constraint: <integration_constraint>

   This epic has been tagged interaction:deferred. How would you like to proceed?

   (a) Resolve — I will clarify the approach or scope to eliminate the conflict (return to Phase 1)
   (b) Override — proceed to scrutiny anyway (removes interaction:deferred tag)
   (c) Halt — stop now; I will address the conflict separately
   ```

   Wait for the user's response:
   - **(a) Resolve**: Re-enter Phase 1 (Context + Socratic Dialogue) with the conflict context as seeding material. After the user provides clarification, return to Step 2.25 and re-run the scan.
   - **(b) Override**: Remove the `interaction:deferred` tag: `.claude/scripts/dso ticket untag <epic-id> interaction:deferred`. Log: `"CROSS_EPIC_SIGNALS overridden by practitioner — proceeding to scrutiny pipeline."` Continue to Step 2.5.
   - **(c) Halt**: Log: `"Brainstorm halted at practitioner request — cross-epic signals unresolved. Epic remains tagged interaction:deferred."` Stop. Do NOT proceed to Step 2.5.

4. **If no ambiguity or conflict signals**: proceed to Step 2.5 normally.

**Failure contract**: If tagging fails, log a warning and present signals to the user anyway — do not block on infrastructure failures.

---

## Step 2.28 — Relates-to AC Injection (runs AFTER Step 3 SC Gap Check)

After the SC Gap Check completes, scan the epic spec for cross-epic consideration signals produced by the epic scrutiny pipeline's Part C Cross-Epic Relates_to extension. For each relates_to signal that includes a `shared_resource` field, inject a structured acceptance criterion (AC) into the `## Cross-Epic Interactions` section.

### URL Navigability Classification

For each `signal.shared_resource` value, classify the resource type:

- **Navigable URL**: the `shared_resource` value starts with `/` OR contains `http://` or `https://`
- **Non-URL resource**: all other values (file paths, config keys, CLI tool names, data structures, etc.)

### AC Structure

**For navigable URL signals** (4-field AC):
```
- Resource: <shared_resource>
  Interaction: <description of the cross-epic interaction>
  Gate: <acceptance condition>
  Playwright assertion: await page.goto('<shared_resource>'); await expect(page).not.toHaveURL(/4[0-9]{2}/);
```

**For non-URL resource signals** (3-field AC, no Playwright assertion):
```
- Resource: <shared_resource>
  Interaction: <description of the cross-epic interaction>
  Gate: <acceptance condition>
```

### Injection Procedure

1. If the epic spec does not already contain a `## Cross-Epic Interactions` section, append one after the `## Dependencies` section.
2. For each cross-epic signal with a `shared_resource`, determine its URL navigability classification (above).
3. Append the appropriate AC entry (3-field or 4-field) to the `## Cross-Epic Interactions` section.
4. If no cross-epic signals with `shared_resource` fields are present, skip this step and log: `"Step 2.28 skipped: no shared_resource signals from Part C extension."`

The Playwright assertion is always appended within the same AC entry as the 4th field — it is not a separate section or bullet. Non-URL resources receive no Playwright assertion and use only the 3-field structure.
