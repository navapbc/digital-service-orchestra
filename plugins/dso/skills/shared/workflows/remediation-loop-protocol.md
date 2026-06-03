# Remediation Loop Protocol

A caller-agnostic shared workflow spec that governs the remediation cycle: cycle-declaration format, termination tokens, oscillation-check hard gate, HALT-vs-REPLAN exclusivity invariant, DELTA OUTPUT template, upstream enum, MAX_CYCLES sourcing, and the conformance harness reference.

Invoking skills (brainstorm, preplanning, and any future planner) execute this protocol within their own remediation loops. All callers MUST conform; the conformance harness at `tests/lib/protocol-conformance-harness.sh` is the canonical check.

> **REPLAN_ESCALATE signal ownership**: The REPLAN_ESCALATE signal is defined and owned by `${CLAUDE_PLUGIN_ROOT}/docs/contracts/replan-escalate-signal.md`. This document limits its treatment to the upstream-enum extension (Section 6). It does NOT redefine the signal text, line-format, or emission rules — those remain in the canonical contract.

---

## Section 1: Per-Cycle Declaration Format

At the start of every remediation cycle, callers MUST emit exactly the following declaration line:

```
Current cycle: N of MAX_CYCLES
```

Where `N` is the 1-based cycle counter and `MAX_CYCLES` is the resolved maximum (see Section 7). The declaration line MUST appear before any findings, deltas, or token emissions within that cycle. This line is the machine-parseable hook for the conformance harness.

---

## Section 2: Termination Tokens

Exactly four terminal tokens are defined. Each has a precise emission condition; no other tokens may be used as substitutes.

### 2.1 `REPLAN_ESCALATE: <upstream>`

Emitted IFF `cycle_count == MAX_CYCLES AND findings non-empty`.

- `cycle_count` is the current cycle number (see Section 1).
- `findings non-empty` means the cycle produced at least one unresolved finding that requires upstream re-examination.
- `<upstream>` MUST be one of the values defined in Section 6 (Upstream Enum).
- See `${CLAUDE_PLUGIN_ROOT}/docs/contracts/replan-escalate-signal.md` for the full signal format, field definitions, and canonical parsing prefix.

### 2.2 `HALT_FOR_USER`

Emitted when human input is required before proceeding. The caller must stop remediation and surface the blocking question or decision to the user. Execution does not resume until the user provides the required input.

### 2.3 `OSCILLATION_HALT`

Emitted when oscillation is detected — defined as the same findings appearing on consecutive cycles without resolution. Detection is mandatory on cycle >= 2 via the oscillation-check hard gate (Section 3). When `OSCILLATION_HALT` fires, the caller MUST stop remediation immediately and report the oscillating findings.

### 2.4 `PROTOCOL_ERROR`

Emitted on illegal state transitions — e.g., attempting to emit `REPLAN_ESCALATE` when `cycle_count < MAX_CYCLES`, emitting multiple terminal tokens in the same execution, or violating the HALT-vs-REPLAN exclusivity invariant (Section 4).

**Mutual exclusivity**: `REPLAN_ESCALATE` and `PROTOCOL_ERROR` are mutually exclusive — they can never both appear in the same execution. An execution that emits `REPLAN_ESCALATE` correctly MUST NOT emit `PROTOCOL_ERROR`, and vice versa.

---

## Section 3: Oscillation-Check Hard Gate

**Cycle >= 2 is a hard gate**: on any cycle where `N >= 2`, callers MUST invoke `/dso:oscillation-check` before proceeding with findings analysis. This gate is not optional.

The oscillation check compares the current cycle's findings against the previous cycle's findings. If the same findings recur without resolution, the check triggers `OSCILLATION_HALT`.

### Escape: `OSCILLATION_CHECK_SKIPPED`

`OSCILLATION_CHECK_SKIPPED` is the only documented escape from this gate. When the oscillation check cannot be invoked (e.g., the tool is unavailable, the previous cycle's findings cannot be retrieved, or a technical failure prevents the check), the caller MUST:

1. Emit `OSCILLATION_CHECK_SKIPPED` as a standalone output line.
2. Capture the rationale for skipping — describing why the check was not feasible.
3. Proceed with caution; manual review of cycle-over-cycle findings is required before closing remediation.

No other reason for skipping the oscillation check is permitted. Any skip without `OSCILLATION_CHECK_SKIPPED` and a captured rationale is a protocol violation.

---

## Section 4: HALT-vs-REPLAN Exclusivity Invariant

`REPLAN_ESCALATE` is emitted IFF `cycle_count == MAX_CYCLES AND findings non-empty`. No other condition may emit `REPLAN_ESCALATE`.

All other terminal states use a different token:
- Human-input required → `HALT_FOR_USER`
- Oscillation detected → `OSCILLATION_HALT`
- Illegal state transition → `PROTOCOL_ERROR`

**Exclusivity rule**: `REPLAN_ESCALATE` and `PROTOCOL_ERROR` are mutually exclusive — never both in the same execution. Emitting both is itself a `PROTOCOL_ERROR` (i.e., the error token supersedes and replaces any `REPLAN_ESCALATE` that was incorrectly emitted).

If `cycle_count == MAX_CYCLES AND findings is empty`, the loop terminates successfully — none of the four tokens is emitted.

---

## Section 5: DELTA OUTPUT Template and Token

The `DELTA OUTPUT:` token marks structured output produced by remediation sub-agents (SC1 and SC2 producers). All producers MUST prefix their structured output with this token.

### Producers

**SC1 — Story-level producer** (`story-decomposer`):
Produces story draft deltas — additions, removals, or modifications to story drafts since the previous cycle.

**SC2 — Approach/task-level producer** (`approach-proposer` or `task-decomposer`):
Produces approach deltas or task decomposition deltas since the previous cycle.

### DELTA OUTPUT Template

```
DELTA OUTPUT:
  producer: <story-decomposer | approach-proposer | task-decomposer>
  cycle: <N>
  delta_type: <story_drafts | approach | tasks>
  items_added: <count>
  items_removed: <count>
  items_modified: <count>
  summary: <one-line human-readable description of changes>
  findings_resolved: <count of findings addressed in this delta>
  findings_remaining: <count of unresolved findings carried to next cycle>
```

All fields are required. `items_added`, `items_removed`, `items_modified`, and `findings_resolved` must be non-negative integers. `findings_remaining` drives the termination token decision: if `findings_remaining == 0`, the loop terminates successfully; if `findings_remaining > 0` and `cycle == MAX_CYCLES`, `REPLAN_ESCALATE` is emitted.

### Schema Preservation — approach-proposer

When the `approach-proposer` agent runs in delta mode (cycle >= 2), its output MUST follow these schema-preservation rules. Delta mode is a partial-update of the prior cycle's structured output, not a full regeneration.

1. **Preserved top-level keys (verbatim when not named in any finding).** The following top-level keys MUST appear in the delta output unchanged from the prior cycle whenever no finding names them as needing modification:
   - `proposals`
   - `distinctness_summary`
   - `complexity_gate_summary`
   - `generation_notes`

   When a finding does name one of these keys, only the parts of that key explicitly addressed by the finding are modified; all other parts are preserved verbatim.

2. **Preserve-by-omission rule.** Proposals not named in any finding MUST appear unchanged in the delta output. Partial-update is only valid for proposals explicitly named in a finding — omitting a proposal that no finding addressed is a protocol violation. Equivalently: a proposal that is not named in any finding is omitted from the diff but preserved unchanged in the merged output.

3. **Distinctness-gate preservation.** The four-axis distinctness invariant MUST still hold across the delta output, evaluated over the union of modified proposals and preserved proposals. The agent MUST re-check distinctness on the merged set, not only on the modified subset. If the merged set violates the four-axis distinctness invariant, the agent MUST surface a finding rather than emitting an invalid delta.

4. **Complexity-gate preservation.** Each preserved proposal's prior complexity-gate outcomes are carried forward verbatim — the agent MUST NOT re-run the gates on unchanged proposals. Only proposals being modified in the current cycle re-run the complexity gates, and only their gate outcomes are refreshed in `complexity_gate_summary`. Preserved proposals' gate outcomes remain bit-identical to the prior cycle.

### Schema Preservation — task-decomposer

When the `task-decomposer` agent runs in delta mode (cycle >= 2), its output MUST follow these schema-preservation rules. Delta mode is a partial-update of the prior cycle's structured output, not a full regeneration.

1. **Preserved top-level keys (verbatim when not named in any finding).** The following top-level keys MUST appear in the delta output unchanged from the prior cycle whenever no finding names them as needing modification:
   - `task_drafts`
   - `dd_partition_map`
   - `decomposition_notes`

   When a finding does name one of these keys, only the parts of that key explicitly addressed by the finding are modified; all other parts are preserved verbatim.

2. **Preserve-by-omission rule.** Task drafts not named in any finding MUST appear unchanged in the delta output, including their full `acceptance_criteria` list, `file_impact`, `depends_on`, and `retry_budget`. Partial-update is only valid for task drafts explicitly named in a finding — omitting a task draft that no finding addressed is a protocol violation. Equivalently: a task draft that is not named in any finding is omitted from the diff but preserved unchanged in the merged output.

3. **TDD-structure preservation.** For task drafts being modified, the TDD invariants MUST be preserved across the merged delta output: the RED-before-GREEN sequencing (a task with `testing_mode: "RED"` for a given behavior MUST precede any `testing_mode: "GREEN"` or `testing_mode: "UPDATE"` task that depends on that behavior), the `depends_on` chain integrity (no orphaned edges — every referenced `temp_id` or pre-existing ticket id MUST resolve to a task in the merged set or an existing ticket), and the `testing_mode` field (RED/GREEN/UPDATE) on each preserved task MUST carry forward verbatim. Additionally, the DD-partition-map invariant MUST still hold across the merged set: every DD continues to be owned by exactly one task — delta-mode output may not silently drop or duplicate DD ownership. The agent MUST re-check these invariants on the merged set, not only on the modified subset. If the merged set violates any TDD invariant or the DD-partition invariant, the agent MUST surface a finding rather than emitting an invalid delta.

4. **Acceptance-criteria preservation.** Each preserved task's prior `acceptance_criteria` list is carried forward verbatim — the agent MUST NOT re-author AC on unchanged tasks. Only task drafts being modified in the current cycle re-author AC, and even then the three Universal Criteria (`Unit tests pass`, `Lint passes`, `Format check passes`) MUST remain as the first three AC entries on every preserved or modified task, bit-identical to the canonical wording in the task-decomposer agent's Universal Criteria template. Preserved tasks' AC lists remain bit-identical to the prior cycle.

### Schema Preservation — story-decomposer

When the `story-decomposer` agent runs in delta mode (DELTA OUTPUT MODE active, i.e., `remediation_context` is provided), its output MUST follow these schema-preservation rules. Delta mode is a partial-update of the prior cycle's story drafts, not a full re-decomposition.

1. **Preserve-by-omission rule for `done_definitions`.** For each targeted story, the returned `done_definitions` array MUST be a superset of the prior draft's `done_definitions`. Every DD not explicitly named in a finding MUST be carried forward verbatim. Omitting a prior DD that no finding addresses is a protocol violation.

2. **Full-draft emission with carried-forward content.** The agent emits only `story_drafts` whose `target_story_id` appears in the finding set, but each emitted draft MUST include its complete `done_definitions` list — the union of carried-forward (unmodified) DDs and delta (new or modified) DDs. An emitted draft that silently drops carried-forward DDs violates the superset invariant and constitutes a protocol violation.

3. **Finding-scoped modification only.** Only the parts of a story's `done_definitions` array explicitly addressed by a finding may be modified or replaced. All other DDs on that story are preserved verbatim, even if the story itself is in the target set.

4. **Protocol-violation framing.** When the story-decomposer produces a `done_definitions` list that fails the superset check (i.e., a prior DD is absent and no finding named it), the orchestrator MUST treat this as a protocol violation: log the discrepancy, reconstruct the superset from the prior draft's DDs plus the delta, and record a `decomposition_notes` entry indicating the violation was detected and corrected.

---

## Section 6: Upstream Enum

The `<upstream>` field in `REPLAN_ESCALATE: <upstream>` MUST be one of the following values — no others are permitted:

| Value | Meaning |
|---|---|
| `brainstorm` | Escalate to `/dso:brainstorm` for epic-level re-examination |
| `preplanning` | Escalate to `/dso:preplanning` for story decomposition re-examination |
| `planner_supplied` | Escalate to the planner that supplied the current task decomposition |

These are the only valid upstream targets. Any value not in this enum is a `PROTOCOL_ERROR`.

---

## Section 7: MAX_CYCLES Sourcing

The `MAX_CYCLES` value used in all cycle declarations and termination conditions is sourced from the `planning.max_remediation_cycles` config key.

- **Default**: 3
- **Minimum**: 2 (values below 2 are **rejected** at load time with a non-zero exit and a stderr message of the form `planning.max_remediation_cycles must be >= 2 (got: <value>)` — the function does NOT silently clamp. See `CONFIGURATION-REFERENCE.md` for the canonical contract.)
- **Config file**: the project's `.claude/dso-config.conf` (read via the standard `read-config.sh` helper)

Callers source `MAX_CYCLES` via the `get_max_remediation_cycles()` function from `${CLAUDE_PLUGIN_ROOT}/hooks/lib/planning-config.sh`. Direct reading of the config key outside this function is not permitted; using the function ensures default-fallback logic and load-time minimum-validation are applied consistently. Callers MUST check the function's exit code — on a non-zero exit, `MAX_CYCLES` will be empty and proceeding into a remediation loop would silently skip all cycles.

```bash
source "$CLAUDE_PLUGIN_ROOT/hooks/lib/planning-config.sh"
MAX_CYCLES=$(get_max_remediation_cycles) || {
    echo "ERROR: planning.max_remediation_cycles invalid — halting remediation entry" >&2
    exit 1
}
```

---

## Section 8: Harness Reference

`tests/lib/protocol-conformance-harness.sh` is the canonical conformance check. Any touchpoint that implements or invokes the remediation loop protocol MUST invoke this harness as part of its test suite.

The harness verifies:
- Per-cycle declaration format matches `Current cycle: N of MAX_CYCLES`
- All four termination tokens are defined and emitted under correct conditions
- Oscillation-check gate is present on cycle >= 2
- `OSCILLATION_CHECK_SKIPPED` escape is captured with rationale when used
- DELTA OUTPUT template fields are all present and correctly typed
- Upstream enum values are constrained to the permitted set
- `REPLAN_ESCALATE` and `PROTOCOL_ERROR` are never both emitted in the same execution

To invoke the harness in a test script:

```bash
REPO_ROOT=$(git rev-parse --show-toplevel)
bash "$REPO_ROOT/tests/lib/protocol-conformance-harness.sh" --doc "${CLAUDE_PLUGIN_ROOT}/skills/shared/workflows/remediation-loop-protocol.md"
```
