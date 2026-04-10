# Shared Exploration Decomposition Protocol

Standalone sub-workflow for classifying exploration questions and decomposing them into focused sub-questions. Consulted by agents at the start of any investigation or research task to prevent answering compound questions with a single flawed synthesis.

---

## Classification: SINGLE_SOURCE vs MULTI_SOURCE

Before beginning exploration, classify the question by source and scope. The classification determines whether to proceed directly or to decompose first.

### SINGLE_SOURCE

A question is SINGLE_SOURCE when **all of the following** hold:

- The answer lives in one well-defined place (a specific file, a single API endpoint, an explicit config value).
- A specific artifact is named in the question (e.g., "What does `plugins/dso/hooks/pre-bash.sh` do?"). Pronouns alone (we, our, us) do NOT imply a project-scoped codebase search — they merely indicate the speaker's organizational context.
- The question has a single correct answer that does not depend on comparing multiple locations.

**Proceed directly** for SINGLE_SOURCE questions. No decomposition required.

### MULTI_SOURCE

A question is MULTI_SOURCE when **any of the following** hold:

- **Web questions**: The web is not a single source. Broad web questions (e.g., "what are best practices for X?") decompose by knowledge facet — each facet (e.g., security considerations, performance trade-offs, adoption patterns) is a separate sub-question. Do not treat a web search as atomic.
- **Multi-layer codebase questions**: A codebase search spanning multiple architectural layers (e.g., API layer + data layer + hook layer) is MULTI_SOURCE even when scoped to one repository. Searching across layers requires decomposition by layer.
- **Comparative questions**: Any question whose answer requires comparing two or more things (implementations, configurations, behaviors) is inherently multi-source.
- **Ambiguous scope**: When the question is ambiguous — it could refer to multiple things, multiple files, or multiple subsystems — ambiguity itself drives decomposition. Do not guess; decompose.
- **Contradictory signals detected**: When two pieces of evidence directly contradict each other (e.g., config A says X, code B says Y), this triggers the DECOMPOSE_RECOMMENDED escape hatch (see below).

---

## Classification Rules (Quick Reference)

| Rule | Behavior |
|------|----------|
| Specific artifact named | Scope to that artifact only — SINGLE_SOURCE |
| Pronouns (we/our/us) present, no artifact named | Do NOT assume project-codebase scope — classify by other signals |
| Web search involved | Decompose by knowledge facet — MULTI_SOURCE |
| Codebase search crosses architectural layers | MULTI_SOURCE — decompose by layer |
| Answer depends on a factor not stated in the question | Emit DECOMPOSE_RECOMMENDED |
| Two findings directly contradict | Emit DECOMPOSE_RECOMMENDED |
| Unfamiliar terms or acronyms present | Preserve them verbatim — do NOT rephrase or expand without evidence. Treat as opaque tokens until a source definition is found. Ambiguity in term meaning drives decomposition. |

---

## DECOMPOSE_RECOMMENDED Escape Hatch

When an agent is mid-exploration and encounters a bright-line trigger, it must emit `DECOMPOSE_RECOMMENDED` rather than guessing.

### Bright-Line Triggers

Emit `DECOMPOSE_RECOMMENDED` when **either** of the following is true:

1. **Factor not specified**: The correct answer depends on a factor that is not stated in the original question (e.g., environment, user role, version). The agent cannot answer without knowing this factor.
2. **Direct contradiction**: Two findings from separate sources directly contradict each other (e.g., a config file says the feature is enabled, but the implementation path never reads that config).

### DECOMPOSE_RECOMMENDED Response Format

```
DECOMPOSE_RECOMMENDED
reason: <one-sentence explanation of the trigger>
sub_questions:
  - <focused question 1>
  - <focused question 2>
  [...]
```

The caller receives this signal and re-dispatches sub-questions before synthesizing a final answer. Re-decomposition is bounded to **1 level** — sub-questions emitted via DECOMPOSE_RECOMMENDED must be answerable without further DECOMPOSE_RECOMMENDED emissions. If a sub-question is still too broad, the agent must narrow it before emitting, not defer the problem to the caller.

### Caller Dispatch Protocol (MULTI_SOURCE)

When a caller receives `DECOMPOSE_RECOMMENDED`:

1. **Dispatch in parallel** — dispatch each sub-question as a separate, concurrent Agent tool call. Do NOT answer sub-questions inline in the same agent context. Do NOT dispatch them sequentially (one after another, waiting for each result before starting the next).
2. **Synthesize after all return** — collect all FINDING responses from the parallel sub-agents before producing a synthesized answer.
3. **Serial fallback** — when the Agent tool is unavailable (sub-agent context, guard blocked), process sub-questions sequentially inline and note `dispatch_mode: serial_fallback` in the synthesized FINDING.

---

## Structured Finding Format

When exploration produces an answer (no decomposition needed), respond with a structured FINDING.

### FINDING Response Format

```
FINDING
source: <file path, URL, or "synthesized">
confidence: <high | medium | low>
answer: <the direct answer>
evidence: <quote or reference supporting the answer>
caveats: [<any conditions under which this answer may not hold>]
```

**Confidence levels:**

| Level | Meaning |
|-------|---------|
| `high` | Directly observed in a canonical source with no ambiguity |
| `medium` | Inferred from multiple consistent signals, but not directly stated |
| `low` | Best available evidence; contradictory signals exist or source is indirect |

Use `low` confidence whenever a DECOMPOSE_RECOMMENDED trigger was present but could not be resolved (e.g., the caller explicitly overrode decomposition). Do not silently inflate confidence.

---

## Acronym and Unfamiliar Term Handling

Do not rephrase, expand, or normalize acronyms or unfamiliar terms found in a question unless a source definition is confirmed. Treat them as opaque search tokens:

- Pass them verbatim to search queries.
- If the term is unfamiliar and no definition is found in Tier 1–2 of the prior-art search, emit DECOMPOSE_RECOMMENDED with a sub-question that specifically targets the term definition.
- Never substitute a guess (e.g., treating "DSO" as "Data Services Organization" without evidence) — incorrect expansion corrupts all downstream exploration.

---

## Re-Decomposition Depth Bound

Re-decomposition is bounded to **1 level**. When DECOMPOSE_RECOMMENDED is emitted, the resulting sub-questions must be leaf questions — each must be answerable with a FINDING directly, without triggering another DECOMPOSE_RECOMMENDED. If a candidate sub-question is still multi-source, narrow it before emitting rather than deferring the bound violation to the caller. One re-decomposition cycle maximum per exploration chain.

---

## Relationship to Other Protocols

- **Prior-art search** (`plugins/dso/skills/shared/prompts/prior-art-search.md`): Applies at task start to determine whether to search before writing code. Exploration decomposition applies during investigation to structure the search itself. The two protocols are complementary and non-overlapping.
- **Empirical Validation Directive**: Governs how hypotheses are validated during active debugging. Exploration decomposition governs how questions are structured before hypotheses are formed.
