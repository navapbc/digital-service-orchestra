# Shared Value/Effort Scorer

Standalone sub-workflow for value/effort scoring of epics. Used identically by `/dso:brainstorm` and `/dso:roadmap` to assign a recommended priority (P0–P4) to an epic based on business value and implementation effort.

## Input

| Field | Description |
|-------|-------------|
| Epic title | The short name of the epic |
| Epic description / success criteria | What the epic delivers and how success is measured |
| Value assessment (1–5) | Agent-assigned score from the Value scoring rubric (1=minimal, 5=critical) |
| Effort assessment (1–5) | Agent-assigned score from the Effort scoring rubric (1=trivial, 5=multi-sprint) |

## Output

Return a single JSON block:

```json
{
  "value": 4,
  "effort": 2,
  "priority": "P1",
  "rationale": "One sentence explaining the value/effort tradeoff and priority assignment."
}
```

**Rules:**
- `value` and `effort` MUST each be an integer 1–5 inclusive
- `priority` MUST be exactly one of: P0, P1, P2, P3, P4
- `rationale` MUST be one sentence
- Do NOT modify any files — this is assessment only

---

## Value Scale (1-5)

Assess the business or user value delivered if this epic is completed. Use the 1-5 range below.

| Score | Label | Definition |
|-------|-------|------------|
| **1** | Minimal impact | Negligible user or business benefit; cosmetic or internal-only change with no measurable outcome |
| **2** | Small quality-of-life | Modest improvement to existing workflows; reduces friction but does not unlock new capability |
| **3** | Measurable user value | Delivers a visible improvement users will notice; enables a meaningful workflow or reduces significant pain |
| **4** | Significant business impact | Unlocks new capability, revenue opportunity, or major efficiency gain; directly supports strategic goals |
| **5** | Critical business need | Blocking issue or must-have capability; failure to deliver has serious consequences for users, revenue, or compliance |

---

## Effort Scale (1-5)

Assess the implementation effort required to complete this epic end-to-end (design, implementation, testing, and review).

| Score | Label | Definition |
|-------|-------|------------|
| **1** | Trivial | Under 1 day; single file or script change, no new abstractions, no coordination required |
| **2** | Small | 1–3 days; a few files, one layer touched, low design complexity |
| **3** | Moderate | 1–2 weeks; multiple files and layers, some design decisions, standard integration work |
| **4** | Large | 3–4 weeks; significant scope, cross-team or cross-layer coordination, non-trivial design risk |
| **5** | Multi-sprint | More than one sprint; high uncertainty, architectural change, or heavy integration surface |

---

## Priority Matrix (Value × Effort → P0–P4)

Look up the cell where the row is Value (1–5) and the column is Effort (1–5).

| Value \ Effort | 1 (Trivial) | 2 (Small) | 3 (Moderate) | 4 (Large) | 5 (Multi-sprint) |
|----------------|-------------|-----------|--------------|-----------|------------------|
| **5 (Critical)** | P0 | P0 | P1 | P1 | P1 |
| **4 (Significant)** | P0 | P1 | P2 | P2 | P2 |
| **3 (Measurable)** | P1 | P2 | P2 | P3 | P3 |
| **2 (Small QoL)** | P2 | P3 | P3 | P4 | P4 |
| **1 (Minimal)** | P3 | P4 | P4 | P4 | P4 |

Full mapping (exhaustive):

| (Value, Effort) | Priority |
|-----------------|----------|
| (5, 1) | P0 |
| (5, 2) | P0 |
| (4, 1) | P0 |
| (5, 3) | P1 |
| (4, 2) | P1 |
| (3, 1) | P1 |
| (5, 4) | P1 |
| (5, 5) | P1 |
| (4, 3) | P2 |
| (3, 2) | P2 |
| (4, 4) | P2 |
| (3, 3) | P2 |
| (2, 1) | P2 |
| (4, 5) | P2 |
| (3, 4) | P3 |
| (2, 2) | P3 |
| (1, 1) | P3 |
| (3, 5) | P3 |
| (2, 3) | P3 |
| (2, 4) | P4 |
| (1, 2) | P4 |
| (2, 5) | P4 |
| (1, 3) | P4 |
| (1, 4) | P4 |
| (1, 5) | P4 |

---

## Example Scoring

**Epic**: "Add real-time collaboration cursors to the document editor"

**Assessment:**
- *Value*: Users on shared documents currently have no awareness of where collaborators are editing — collisions and confusion are a top complaint. Score: **4** (Significant business impact — directly addresses a major pain point and differentiates from competitors).
- *Effort*: Requires WebSocket integration, cursor position broadcasting, frontend overlay rendering, and conflict with existing autosave logic. Score: **3** (Moderate — 1–2 weeks, touches multiple layers).

**Matrix lookup**: (4, 3) → **P2**

```json
{
  "value": 4,
  "effort": 3,
  "priority": "P2",
  "rationale": "High-value collaboration feature addresses a top user complaint, but moderate WebSocket + frontend integration effort places it at P2 rather than P1."
}
```

---

## Skill-Agnostic Usage

This scorer is invoked identically by both `/dso:brainstorm` and `/dso:roadmap`:

1. Read this file to load the value scale, effort scale, and priority matrix.
2. Assess the epic's value (1–5) and effort (1–5) using the definitions above.
3. Look up the resulting priority in the matrix.
4. Return the JSON output block and use `priority` as the `-p` argument when creating the epic ticket.

Neither skill customizes the scoring logic — the matrix and scale definitions here are the single source of truth.
