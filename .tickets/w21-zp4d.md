---
id: w21-zp4d
status: open
deps: [dso-9ltc]
links: []
created: 2026-03-21T00:02:22Z
type: story
priority: 1
assignee: Joe Oakhart
parent: w21-ykic
---
# As a DSO contributor, all review dimension references use the new 5-dimension schema

## Description

**What**: Rename 5 review dimension keys across all consuming files: correctness (replaces functionality), verification (replaces testing_coverage), hygiene (replaces build_lint), design (replaces object_oriented_design), maintainability (replaces readability).

**Why**: The renamed dimensions better encompass expanded review concerns introduced by this epic. All subsequent stories reference the new names — this must land first.

**Scope**:
- IN: record-review.sh, write-reviewer-findings.sh, validate-review-output.sh, code-review-dispatch.md, REVIEW-WORKFLOW.md, any orchestrator code reading dimension keys, all test fixtures constructing reviewer-findings JSON
- OUT: Enriching what each dimension checks for (that is Epic B: Review Intelligence & Precision)

## Done Definitions

- When this story is complete, reviewer-findings.json uses the 5 new dimension keys and all consuming scripts/prompts reference the new names
  ← Satisfies: "Review output schema updated from 5 dimension keys to 5 renamed keys"
- When this story is complete, validate-review-output.sh required_dims and valid_categories use the new 5 dimension names
  ← Satisfies: "All consumers updated"
- When this story is complete, record-review.sh embedded Python validator uses the new dimension names
  ← Satisfies: "All consumers updated"
- When this story is complete, all test fixtures constructing reviewer-findings JSON (test-record-review.sh, test-record-review-crossval.sh, test-write-reviewer-findings.sh) use the new dimension names
  ← Satisfies: "All consumers updated"
- When this story is complete, grep for old dimension names (functionality, testing_coverage, build_lint, object_oriented_design, readability) across all consumer AND test files returns zero matches
  ← Satisfies: "All consumers updated"
- Unit tests written and passing for all new or modified logic

## Considerations

- [Testing] Schema rename must be verified atomically across all consumers and test files — validate-review-output.sh is the gatekeeper for write-reviewer-findings.sh and will reject findings with mismatched dimension names

## Escalation Policy

**Escalation policy**: Proceed unless a significant assumption is required to continue — one that could send the implementation in the wrong direction. Escalate only when genuinely blocked without a reasonable inference. Document all assumptions made without escalating.

## Notes

<!-- note-id: pu8sct5w -->
<!-- timestamp: 2026-03-21T18:14:04Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->


## Update: Scope change due to dso-9ltc (review agent build process)

With dedicated review agents built from source fragments (dso-9ltc), the generated agent files will use new dimension names from day one. This story's scope shrinks to updating non-agent consumers only:
- record-review.sh
- write-reviewer-findings.sh
- validate-review-output.sh
- code-review-dispatch.md (legacy fallback, still operational)
- All test fixtures constructing reviewer-findings JSON

The agent source fragments (reviewer-base.md, per-agent deltas) are created by dso-9ltc with the new dimension names — no rename needed there. Done definition 1 should be read as: reviewer-findings.json uses the 5 new dimension keys and all non-agent consuming scripts/prompts reference the new names.

