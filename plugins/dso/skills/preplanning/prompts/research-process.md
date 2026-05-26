# Research Process (shared between Phase D and Phase G)

This prompt is referenced by `/dso:preplanning` Phase D (Integration Research, pre-slicing) and Phase G (Story-Level Research, post-slicing). The trigger conditions and time-axis position differ between phases; the research procedure itself does not.

## Pre-flight: deduplicate against `researchFindings`

Before issuing any WebSearch call for a qualifying story's capability, check the merged `researchFindings` array (loaded from the epic's last `RESEARCH_FINDINGS:` ticket comment per Phase H Step 6) for a matching `capability` entry:

- `verified` → skip WebSearch entirely for this capability and reuse the prior `source` citation directly. Skipping verified entries avoids redundant network calls and accelerates preplanning when upstream skills have already established the constraint.
- `partially_verified` → run a light WebSearch (1 spot-check query) to confirm the prior finding still holds.
- `unverified` or `contradicted` → run full WebSearch verification as described below.
- Empty array (no prior findings) → run full WebSearch verification for every qualifying capability.

**Per-command contract check (CLI tools only)**: When a qualifying story references a CLI tool integration signal AND the story's Done Definition mentions a specific CLI subcommand (create, edit, transition, delete, comment, label-add, etc.), additionally check whether the matching `researchFindings` entry contains a non-null `command_surface` field with a `MATCH` or `MISMATCH` verdict for that subcommand. If `command_surface` is null or absent for the relevant subcommand:

1. Log: `"Per-command contract gap: <tool> <subcommand> has no verified command_surface entry in researchFindings."`
2. Run `<tool> <subcommand> --help` (or equivalent) empirically to observe the actual flag surface. Record the observed flags, payload shape, and idempotency semantics.
3. Append a `command_surface` update to the story's Considerations as a **Verified Constraint**:
   ```
   - [Integration] Per-command contract: <tool> <subcommand> — flags: <observed flags>; payload: <shape>; idempotency: <behavior>; verdict: MATCH|MISMATCH
   ```
4. If the verdict is MISMATCH (the story's assumed invocation does not match what `--help` reports), flag the story as **HIGH-RISK** and surface the exact mismatch to the user before proceeding to story slicing. Do not silently proceed — a MISMATCH at this stage means implementation will fail at runtime.

This per-command contract check prevents the class of bugs described in bug 0dee-a535-45dd-4bc4, where integration-level verification ("ACLI authenticates") was captured but command-surface mismatches (`--label` vs `--labels`, priority dict shape) were not caught until runtime.

After research, append new entries (or upgrade existing entries) to `researchFindings` with the latest `status`, `source`, `skill_name: "preplanning"`, and current `timestamp` so downstream consumers benefit from the same dedup.

## Procedure

For each qualifying story:

1. Use WebSearch to find known-working code that uses the specific integration or topic. Search GitHub for repositories that import or call the tool/API.
2. Verify specific capabilities claimed or implied by the story scope. Check official documentation against what the story requires.
3. Add findings to the story's Considerations as **Verified Constraints**:
   ```
   - [Integration] Verified: <tool> supports <capability> (source: <URL>)
   - [Integration] NOT verified: <tool> does not appear to support <capability>
   ```
4. If no sandbox or test environment is available for integration testing, flag this to the user during preplanning: "No sandbox available for <tool> — integration testing will require a live environment."
5. If research finds no verified code or capabilities for a story's integration, emit `REPLAN_ESCALATE: brainstorm` with explanation of the unresolved gap. Sprint's replan machinery routes this signal. Track the current iteration in `feasibility_cycle_count` (state variable exposed for planning-intelligence log consumption).

## Graceful degradation

If WebSearch or WebFetch fails or is unavailable, continue without research rather than blocking the workflow. Log: `"Research skipped for <story-id>: WebSearch/WebFetch unavailable."` and proceed to the next phase per the calling phase's instructions.
