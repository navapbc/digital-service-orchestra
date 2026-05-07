# Contract: Inferred-Source Marker

## Purpose

The `<<inferred:source-name>>` marker convention tags inferred input sources within Approach and Context narrative sections during spec drafting. It makes implicit premises visible, enabling the approval gate and gap-analysis scan to surface unverified assumptions before implementation begins.

## Marker Syntax

`<<inferred:source-name>>` where `source-name` is a short identifier naming the inferred input source (e.g., `<<inferred:config-rules>>`, `<<inferred:user-lookup-table>>`).

If `source-name` contains `>>`, escape as `\>\>` to prevent premature marker termination.

## Emit Site

The brainstorm orchestrator wraps inferred input source mentions in Approach and Context narrative sections at spec-drafting time (Phase 2 Step 2). Emission is triggered when the orchestrator detects an input source that is assumed but not explicitly documented in the epic description.

## Consume Sites

- **Approval gate renderer** (`approval-gate.md`): converts `<<inferred:...>>` to bold text in the rendered spec for human review
- **Gap-analysis scan**: preserves marker unchanged during analysis to maintain traceability
- **SC Gap Check**: passes through marker content unchanged

## Lifecycle

1. **Emitted** at spec-drafting time (Phase 2 Step 2 of brainstorm)
2. **Preserved** through gap-analysis — marker content is not modified
3. **Rendered** at approval gate — converted to bold for human review
4. **Retained** in final spec text as bold text after approval

## Scope Decisions

- Pre-S5 historical specs are left unmarked — no backfill required
- Marker emission in non-brainstorm skills is out of epic scope
