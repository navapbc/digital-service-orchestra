# Doc Target Router

Shared decision prompt for any task or sub-agent that intends to add or update project documentation. Runs at planning time (preplanning, implementation-plan) and at execution time (sprint sub-agents executing doc tasks). Replaces ad-hoc target selection that biases toward CLAUDE.md.

This prompt enforces a write-time CLAUDE.md guard and complements the `dso:doc-writer` agent's Constraint Gate (`agents/doc-writer.md` §2). The doc-writer guard fires only at the late `/dso:update-docs` stage; this router fires for **every** doc-creating task.

## When to invoke

- Inside `/dso:preplanning` Phase H Step 2 (Documentation Update Story decision).
- Inside `/dso:implementation-plan` Step 3 (Documentation Updates task decision).
- Inside any sprint sub-agent dispatched to execute a doc task.
- Whenever an orchestrator considers editing CLAUDE.md, a SKILL.md, or a reference doc as part of a workflow.

## Decision gates

Evaluate in order; route to the **first matching** target and stop.

### Gate 1 — Skill-scoped rule or workflow detail

The content describes a rule, phase step, contract field, or internal behavior of **one** skill, agent, or workflow.

→ **Target**: `${CLAUDE_PLUGIN_ROOT}/skills/<skill>/SKILL.md` (or a prompt under that skill's directory).
→ Do **not** add to CLAUDE.md.

Examples: a new phase in `/dso:fix-bug`; a contract field for `dso:completion-verifier`; a sub-step inside `/dso:sprint`.

### Gate 2 — Reference content for an existing doc

The content extends or supersedes material that already lives in a reference doc.

→ **Target**: the existing doc. The current set:
- `${CLAUDE_PLUGIN_ROOT}/docs/AGENTS.md` — named-agent routing
- `${CLAUDE_PLUGIN_ROOT}/docs/HOOKS-REFERENCE.md` — pre-commit hooks, gates, hook error handler
- `${CLAUDE_PLUGIN_ROOT}/docs/WORKTREE-GUIDE.md` — worktree lifecycle and isolation
- `${CLAUDE_PLUGIN_ROOT}/docs/CONFIGURATION-REFERENCE.md` — config keys
- `${CLAUDE_PLUGIN_ROOT}/docs/CI-INTEGRATION.md` — CI llm-review, version resolution, release channels
- `${CLAUDE_PLUGIN_ROOT}/docs/ticket-cli-reference.md` — ticket CLI
- `${CLAUDE_PLUGIN_ROOT}/docs/contracts/` — contract schemas
- `${CLAUDE_PLUGIN_ROOT}/docs/SUB-AGENT-BOUNDARIES.md` — sub-agent rules
- `${CLAUDE_PLUGIN_ROOT}/docs/REVIEW-SCHEMA.md`, `REVIEWER-FILE-CHECKLIST.md` — review internals
- `.claude/docs/KNOWN-ISSUES.md` — operational fixes
→ Do **not** add to CLAUDE.md.

### Gate 3 — User-facing or onboarding content

The content applies once at install/setup, targets humans rather than agents, or describes external behavior.

→ **Target**: `INSTALL.md`, `README.md`, or `docs/user/` (consuming projects).
→ Do **not** add to CLAUDE.md.

### Gate 4 — Decision rationale (why, not what)

The content explains *why* a choice was made; future agents need only the outcome.

→ **Target**: a new sequentially numbered ADR in `docs/adr/`.
→ Do **not** add to CLAUDE.md.

### Gate 5 — Eligible for CLAUDE.md (strict)

All four conditions must hold:

1. The rule or pointer applies to **every session**, not to one workflow or one skill.
2. The content is **not already covered** by an existing entry in CLAUDE.md (Quick Reference, Never Do These, Always Do These, Architectural Invariants, Architecture pointers). Strengthen the existing entry if drift is the issue.
3. The behavior **cannot be enforced by a hook, skill, or settings change** instead. Deterministic enforcement belongs in code, not prose.
4. The addition is **≤ 2 lines** in CLAUDE.md, with all detail externalized to a referenced doc.

If all four hold, the eligible target is CLAUDE.md — but **do not write directly**. Emit a `CLAUDE_MD_SUGGESTED_CHANGE` report (format below) and stop. The orchestrator collects the report and routes it to the user for approval.

## `CLAUDE_MD_SUGGESTED_CHANGE` format

```
CLAUDE_MD_SUGGESTED_CHANGE:
Section: <Quick Reference | Never Do These | Always Do These | Architectural Invariants | Architecture pointers>
Gate 5 self-check:
  - Every-session: <yes — why>
  - Not duplicated: <yes — confirmed against existing rules X, Y>
  - Not enforceable as hook/skill: <yes — why>
  - ≤ 2 lines: <yes>
Proposed line(s): <the exact ≤ 2 lines to add, verbatim>
Pointer target: <the doc that holds the full detail; the line(s) reference it>
Rationale (1 sentence): <why this rule is load-bearing per session>
```

The orchestrator MUST surface every `CLAUDE_MD_SUGGESTED_CHANGE` to the user before any CLAUDE.md edit lands. Sub-agents are not authorized writers of CLAUDE.md.

## Self-check before any doc write

Every doc task MUST include this attestation in its completion report:

```
DOC_ROUTER_ATTESTATION:
Gate fired: <1 | 2 | 3 | 4 | 5 | none — no doc change warranted>
Target file: <path>
CLAUDE.md edited directly: <no — N/A | no — emitted CLAUDE_MD_SUGGESTED_CHANGE>
Lines added to CLAUDE.md: <0, or count if a prior CLAUDE_MD_SUGGESTED_CHANGE was approved>
```

If any answer is uncertain, halt and emit:

```
DOC_ROUTER_AMBIGUOUS: <which gate boundary is unclear, what content>
```

The orchestrator resolves ambiguity (typically by escalating to the user) before the doc task proceeds.

## Anti-patterns

- **"This rule is important so it must go in CLAUDE.md"**: importance ≠ universal scope. Skill-specific rules belong in the skill's SKILL.md, where they are loaded with full attention only when relevant. CLAUDE.md rules compete for attention every session — context-rot research (Chroma 2025; lost-in-the-middle) shows degradation at all length increments.
- **"This is architectural so it must go in CLAUDE.md"**: architecture descriptions belong in reference docs (Gate 2). CLAUDE.md holds **pointers** to architecture, not architecture itself. See CLAUDE.md Architectural Invariant #2 (bloat criteria a–d).
- **"It's only a few lines"**: bloat is cumulative. Rules added as 2-line entries become 6-line entries with examples and exceptions over time. Externalize first; let CLAUDE.md hold the one-liner pointer.
- **Duplicating an existing rule under a slightly different framing**: strengthen the existing rule instead.
