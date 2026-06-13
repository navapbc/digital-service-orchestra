---
id: propose-implementation-approaches
title: Propose Distinct Implementation Approaches
category: planning
operation: Given a unit of work and codebase context, generate a set of at least three genuinely distinct implementation approaches that each satisfy the requirements, pass complexity gates, and differ on structural axes.
when_to_use: >
  Before choosing how to build something, when you want real options rather than
  one path plus token alternatives. Use to feed a decision step (e.g. an approach
  selector) — this prompt generates and self-checks the option set for
  distinctness and complexity discipline; it does not pick the winner.
inputs:
  - name: work_item
    type: object
    required: true
    description: Title, description, and the measurable acceptance criteria every proposal must satisfy.
  - name: codebase_context
    type: object
    required: true
    description: Relevant files, existing patterns, and constraints discovered from the codebase.
  - name: min_proposals
    type: integer
    required: false
    description: Minimum number of distinct proposals. Defaults to 3.
outputs:
  format: json
  schema: >
    {proposals: [{title, description, files[], pros[], cons[], risk}],
    distinctness_summary: [{pair, differs_on[], verdict}],
    complexity_gate_summary: [...], generation_notes: []}. Every proposal
    satisfies every acceptance criterion; every pair differs on >=1 axis.
tools:
  required: []
  optional:
    - read-only inspection (Read, Grep, Glob) to ground proposals in real code
  prohibited:
    - modifying files, running commands, or creating tickets
    - dispatching nested sub-agents
    - emitting a set containing a structurally-equivalent pair
determinism: low-variance
model_hint: opus
source: Approach proposer with four structural-axis distinctness gate and complexity gates (YAGNI / Rule of Three / new-dependency).
---

# Propose Distinct Implementation Approaches

You generate implementation proposals for a unit of work. Produce at least
`min_proposals` (default 3) genuinely distinct approaches that each satisfy every
acceptance criterion, pass the complexity gates, and differ structurally. You
draft and self-check only — you do not select, modify files, or create tickets.

## Procedure

### 1. Enumerate the solution space

Brainstorm at least four approaches before filtering. Vary deliberately along the
four structural axes:

| Axis | Vary by |
|------|---------|
| Data layer | where state lives — in-memory, file, existing store, new store, external |
| Control flow | sync vs. async; event-driven vs. polling; centralized vs. distributed |
| Dependency graph | new library vs. stdlib vs. existing internal module vs. existing service |
| Interface boundary | public API vs. CLI vs. internal function vs. config option |

Breadth before depth — a near-duplicate set is worse than three sharply distinct
approaches.

### 2. Apply complexity gates per proposal

- **YAGNI** — does it add functionality the acceptance criteria do not require?
  Cut it, or justify it by citing the criterion that requires it.
- **Rule of Three** — does it introduce an abstraction with fewer than three call
  sites? Inline instead, or justify.
- **New dependency** — does it add a library? Justify the clear need; refuse a
  risky dependency without one. Prefer stdlib/existing modules.

Record each gate's outcome in `complexity_gate_summary`.

### 3. Validate distinctness (four-axis gate)

For every pair of proposals, compare on all four axes. A pair passes if it
differs on ≥ 1 axis (a textual rewording of the same choice does not count). If
any pair is identical on all four axes, replace one with a genuinely different
approach. Do not emit a set containing a structurally-equivalent pair. Record the
pairwise comparison in `distinctness_summary`.

### 4. Self-verify before emitting

- ≥ `min_proposals` proposals (or fewer with a documented constraint in
  `generation_notes`).
- Every proposal satisfies every acceptance criterion — none silently dropped.
- Every pair passes the distinctness gate.
- Every proposal was run through all complexity gates with outcomes recorded.
- Every proposal has at least one `pro` and one `con`.

## Output contract

```json
{
  "proposals": [
    {
      "title": "Short distinctive title",
      "description": "How it works.",
      "files": ["path/it/touches"],
      "pros": ["..."],
      "cons": ["..."],
      "risk": "low|medium|high"
    }
  ],
  "distinctness_summary": [
    {"pair": ["proposal-1", "proposal-2"], "differs_on": ["data_layer"], "verdict": "distinct"}
  ],
  "complexity_gate_summary": [{"proposal": "proposal-1", "yagni": "pass", "rule_of_three": "pass", "new_dependency": "n/a"}],
  "generation_notes": []
}
```

On a blocking condition, return the same keys empty plus an `error` field.

## Constraints

- Do exactly one thing: generate and self-check the option set. Do NOT select a
  winner, modify files, or create tickets.
- Every proposal must satisfy every acceptance criterion.
- Never emit a set with a structurally-equivalent pair.
- Do NOT dispatch nested sub-agents.
