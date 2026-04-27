# Design Review Scorecard

| Field | Value |
|-------|-------|
| **Design ID** | `{DESIGN_UUID}` |
| **Story** | {STORY_ID} — {STORY_TITLE} |
| **Review Cycle** | {N} of 3 |
| **Date** | {YYYY-MM-DD} |

---

## Senior Product Manager

| Dimension | Score | Justification |
|-----------|-------|---------------|
| Story Alignment | {1-5 / N/A} | {brief justification} |
| User Value | {1-5 / N/A} | {brief justification} |
| Scope Appropriateness | {1-5 / N/A} | {brief justification} |
| Consistency | {1-5 / N/A} | {brief justification} |
| Epic Coherence | {1-5 / N/A} | {brief justification} |

**Recommendation**: {APPROVE / REVISE / REJECT}

**Summary**: {one paragraph assessment}

**Actionable feedback** (for scores below 4):
{numbered list of specific changes, or "None — all dimensions pass."}

---

## Senior Design Systems Lead

| Dimension | Score | Justification |
|-----------|-------|---------------|
| Component Reuse | {1-5 / N/A} | {brief justification} |
| Visual Hierarchy | {1-5 / N/A} | {brief justification} |
| Design System Compliance | {1-5 / N/A} | {brief justification} |
| New Component Justification | {1-5 / N/A} | {brief justification} |
| Cross-Story Component Consistency | {1-5 / N/A} | {brief justification} |

**Recommendation**: {APPROVE / REVISE / REJECT}

**Summary**: {one paragraph assessment}

**Actionable feedback** (for scores below 4):
{numbered list of specific changes, or "None — all dimensions pass."}

---

## CPWA Accessibility Specialist

| Dimension | Score | Justification |
|-----------|-------|---------------|
| WCAG 2.1 AA Compliance | {1-5 / N/A} | {brief justification} |
| Keyboard Navigation | {1-5 / N/A} | {brief justification} |
| Screen Reader Support | {1-5 / N/A} | {brief justification} |
| Inclusive Design | {1-5 / N/A} | {brief justification} |

**Recommendation**: {APPROVE / REVISE / REJECT}

**Summary**: {one paragraph assessment}

**Actionable feedback** (for scores below 4):
{numbered list with specific WCAG criteria cited, or "None — all dimensions pass."}

---

## Senior Frontend Software Engineer

| Dimension | Score | Justification |
|-----------|-------|---------------|
| Implementation Feasibility | {1-5 / N/A} | {brief justification} |
| Performance | {1-5 / N/A} | {brief justification} |
| State Complexity | {1-5 / N/A} | {brief justification} |
| Specification Clarity | {1-5 / N/A} | {brief justification} |

**Recommendation**: {APPROVE / REVISE / REJECT}

**Summary**: {one paragraph assessment}

**Actionable feedback** (for scores below 4):
{numbered list with complexity estimates, or "None — all dimensions pass."}

---

## Aggregate Result

| Metric | Value |
|--------|-------|
| **Total dimensional scores** | {count of all non-N/A scores} |
| **Scores at 4 or 5** | {count} |
| **Scores at N/A** | {count} |
| **Scores below 4** | {count} |
| **Result** | {APPROVED / REVISION REQUIRED / ESCALATE TO USER} |

### Scores Below 4 (if any)

| Reviewer | Dimension | Score | Core Issue |
|----------|-----------|-------|------------|
| {reviewer} | {dimension} | {score} | {one-line summary of the issue} |

---

## Revision Plan (if REVISION REQUIRED)

Priority-ordered list of changes to make before the next review cycle:

1. **[Priority 1 — Score {N}]** {Reviewer}: {Dimension}
   - Issue: {what is wrong}
   - Action: {specific artifact to modify and how}

2. **[Priority 2 — Score {N}]** {Reviewer}: {Dimension}
   - Issue: {what is wrong}
   - Action: {specific artifact to modify and how}

{Continue for all scores below 4, ordered by score ascending (1s first)}

---

## Revision History

{For review cycles 2 and 3, append the changes made since the previous cycle:}

### Changes from Cycle {N-1} to Cycle {N}

| Feedback Addressed | Artifact Modified | Change Description |
|-------------------|-------------------|-------------------|
| {reviewer: dimension} | {spatial-layout.json / wireframe.svg / tokens.md} | {what changed} |
