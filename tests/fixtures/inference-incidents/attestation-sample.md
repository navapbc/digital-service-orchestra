# Inference Incident Corpus — Attestation Sample

This file contains a human-review sample drawn from the holdout partition.
A human reviewer should assess each incident and mark the `reviewer_verdict` column.

**Partition**: holdout (md5(ticket_id)[0:8] as int mod 3 == 0)
**Sample size**: 6 of 9 holdout entries

## Review Instructions

For each incident, confirm:
1. The `inferred_decision_text` represents a decision made without explicit user input.
2. The `outcome` accurately reflects what happened as a result.
3. The record does not violate the Zero Inference Rule (no root-cause speculation).

Mark `reviewer_verdict` as one of: `VALID`, `INVALID`, `AMBIGUOUS`.

---

## Incident Sample

| ticket_id | inferred_decision_text | affects_fields | outcome | reviewer_verdict | notes |
|-----------|------------------------|----------------|---------|-----------------|-------|
| `3da0-dc8c` | Agent inferred that brainstorm epic w21-bsnz was complete without defining agent contracts, assuming downstream agents would align independently | `done_definitions` | `user_corrected` | PENDING | |
| `027a-ad30` | Agent inferred that the first task creation template (bare, without -d flag) was the intended format, creating tasks with empty descriptions | `description` | `ticket_reopened` | PENDING | |
| `1175-497a` | Brainstorm gap analysis agent inferred that input sources explicitly mentioned in design docs were verified even when no verification command had been run | `done_definitions` | `planning_error` | PENDING | |
| `0fb0-e23a` | PR comment response agent inferred that applying only the first requested change per comment thread was sufficient, missing multi-part comment requests | `acceptance_criteria` | `user_corrected` | PENDING | |
| `3916-ad17` | Brainstorm orchestrator inferred that running web research in orchestrator context (rather than a sub-agent) was equivalent since results would be incorporated into the plan | `acceptance_criteria` | `user_corrected` | PENDING | |
| `0ecc-9ce1` | Developer agent inferred that Python AST subtree hashing was sufficiently stable across minor Python versions without explicit version-pinning in the test fixtures | `done_definitions` | `task_regenerated` | PENDING | |

---

*Reviewer: _______________*
*Review date: _______________*
