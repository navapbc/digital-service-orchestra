# Research-When-Stuck Pattern

> **Audience**: All agents (orchestrators and leaf/sub-agents). Read this file when you are stuck and considering a web search before attempting a fix.
>
> **Date**: 2026-02
> **Status**: Active

---

## Overview

Research is a targeted recovery tool, not a default step. Use it when you have hit a specific knowledge boundary that is blocking progress. Never use it speculatively or as a substitute for reading existing code and documentation.

---

## When to Research (Trigger Criteria)

Research is appropriate when **all three** of the following are true:

1. **You are blocked**: You cannot proceed without information you do not have.
2. **The blocker is a knowledge gap about an external system**: A library API, framework behavior, error message from a third-party tool, or protocol specification.
3. **The codebase and project docs do not answer the question**: You have already checked `.claude/docs/`, `CLAUDE.md`, relevant source files, and `KNOWN-ISSUES.md`.

### Examples That Justify Research

| Situation | Why research is justified |
|-----------|--------------------------|
| A third-party library raises an undocumented exception | External behavior not visible in the codebase |
| An error message refers to a framework-specific version incompatibility | Version-specific behavior changes over time |
| You need the exact API signature for a library function not used elsewhere in the project | Not derivable from existing code |
| A CI failure references an external service behavior you cannot reproduce locally | Requires current documentation |

---

## When NOT to Research (Guardrails)

Do not research in any of the following situations:

- **The answer exists in the codebase**: Check `src/`, `tests/`, and `.claude/docs/` first. Reading is faster and more reliable than searching.
- **You are speculating about a better approach**: Research is for blocked gaps, not exploring alternatives. If no specific blocker exists, skip it.
- **You already know the answer or can derive it**: Do not use web search to confirm what you already know.
- **The task is purely internal logic**: If the question is about this project's own business rules, pipeline architecture, or agent conventions, the answer is in the codebase or project docs — not on the web.
- **You are mid-fix and drifting**: If you started implementing and are now reaching for research to pivot, stop and re-read the task description instead.
- **You have already spent your token budget** (see Token Budget below): Stop researching and proceed with best available information.

---

## How to Research: Orchestrators

Orchestrators (main session, `/dso:sprint`, `/dso:debug-everything`, etc.) must not perform inline web searches — they manage concurrency budgets and doing research inline inflates their context cost.

**Pattern: Spawn a general-purpose research sub-agent.**

```
Task tool call:
  model: haiku          # Tier 1: structured query → structured summary, no judgment needed
  prompt: |
    Research the following question and return a concise answer (3–5 sentences max).
    Do not include preamble. Return only the answer and, if applicable, the source URL.

    Question: <specific technical question>

    Token budget: max 3 web searches, max 2 page fetches.
```

- Use `haiku` because the research sub-agent has a well-defined input/output contract: one question in, one short answer out. No architectural reasoning is needed.
- The sub-agent uses inline `WebSearch`/`WebFetch` tools (see Leaf Agent pattern below).
- Collect the result and include it inline in your existing planning or diagnostic output. Do not create a separate research report section.

---

## How to Research: Leaf Agents

Leaf agents (sub-agents dispatched by orchestrators, including fix sub-agents and implementation sub-agents) perform research inline using the `WebSearch` and `WebFetch` tools directly.

**Pattern: Inline search before attempting the fix.**

```
Step order for a leaf agent hitting a blocker:
  1. Identify the specific external knowledge gap.
  2. Run up to 3 WebSearch calls with precise queries.
  3. Run up to 2 WebFetch calls on the most relevant results.
  4. Incorporate findings directly into your implementation or diagnosis.
  5. Do not narrate the research process — include the findings naturally in your
     output (error diagnosis, implementation note, or task report).
```

### Query Guidelines

- Be specific: include library name, version if known, error text, and language.
- Prefer official documentation domains: `docs.python.org`, `flask.palletsprojects.com`, `docs.sqlalchemy.org`, etc.
- Stop after you have enough to unblock. Do not continue searching once the gap is filled.

---

## Token Budget

Per session (one fix attempt, one implementation sub-agent, one diagnostic run):

| Tool | Limit |
|------|-------|
| `WebSearch` | Max **3** searches |
| `WebFetch` | Max **2** fetches |

These limits apply to the entire session, not per blocker. If you hit the budget before resolving the blocker, proceed with best available information and note the unresolved gap in your output.

---

## Output Format

There is no separate research output format. Incorporate findings naturally into your existing report fields:

- In a fix sub-agent: include a one-sentence note in your diagnostic summary (e.g., "Per SQLAlchemy 2.x docs, `session.query()` is deprecated — updated to `session.execute(select(...))`").
- In an implementation sub-agent: include a brief inline comment in the code if the research revealed a non-obvious decision.
- In an orchestrator planning step: fold the research answer into the relevant planning narrative.

Do not add a "Research Results" section to any report. Surfacing research as a named section implies it required special handling — if the research was necessary, it should already be reflected in the decision it informed.

---

## Quick Decision Reference

```
Stuck on something?
  ├─ Is the answer in the codebase or .claude/docs/?  → Read those files. Stop.
  ├─ Is it internal project logic?                    → Read the codebase. Stop.
  ├─ Is it external knowledge (library, API, error)?
  │   ├─ Am I an orchestrator?                        → Spawn haiku research sub-agent.
  │   └─ Am I a leaf agent?                           → WebSearch inline (≤3 searches, ≤2 fetches).
  └─ Have I hit the token budget?                     → Proceed with best available info.
```
