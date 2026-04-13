# Complexity Gate

<!-- Disambiguation: This file (complexity-gate.md) is a shared prompt for inline LLM-based complexity threshold checks, consumed directly by brainstorm and implementation-plan skill workflows. It is NOT the named sub-agent. The named sub-agent (agents/complexity-evaluator.md) is dispatched via dso:complexity-evaluator for structured ticket classification. -->

## Purpose

This gate evaluates whether a proposed complexity (library dependency, new abstraction, or performance optimization) is warranted by confirmed requirements or evidence — not hypothetical future needs.

## Output Format

Each gate check must produce a structured output block:

```
GATE: Rule of Three
CHECKED: Does this abstraction have 3+ existing call sites?
FINDING: Only 1 call site found (TicketService.create). No existing reuse.
VERDICT: FAIL — abstraction not warranted. Use inline logic.
```

Fields:
- **GATE**: Name of the gate being applied.
- **CHECKED**: The specific question or criterion being evaluated.
- **FINDING**: Observed evidence from the codebase or ticket (concrete, not hypothetical).
- **VERDICT**: PASS or FAIL, with a one-line rationale and recommended action on FAIL.

## Gate 1: YAGNI

Block complexity added in anticipation of future needs not present in the current ticket's done definitions.

**Rule**: If the proposed feature, abstraction, or configuration option addresses a requirement absent from the current story's done definitions, it is premature.

**VERDICT**: FAIL if the proposed feature/abstraction addresses a requirement absent from the current story.

**Common triggers**:
- "We might need this later"
- "Future stories will use this"
- "This makes it extensible for when..."
- Adding configuration knobs for behaviors not yet required

## Gate 2: Rule of Three

No new abstraction (base class, protocol, factory, shared utility) unless the pattern appears in 3+ existing confirmed call sites in the codebase. A single planned future use does not satisfy this gate.

**Rule**: Count actual existing call sites in the codebase. Do not count the proposed new usage. Do not count planned future usages from other stories.

**VERDICT**: FAIL if fewer than 3 existing call sites.

**Note**: "We're going to add two more callers in the next sprint" does not satisfy this gate. The callers must exist now.

## Gate 3: Dependency Cost/Benefit

A new library dependency must satisfy at least one of:

- (a) The functionality cannot be replicated in ≤30 lines of straightforward code, OR
- (b) The library provides a correctness or security guarantee not achievable with custom code (e.g., cryptographic primitives, protocol compliance, time zone handling).

**Required documentation**: State the line count estimate for the inline alternative and explain why the library wins (correctness, security, or genuine complexity reduction beyond the 30-line threshold).

**VERDICT**: FAIL if neither condition (a) nor condition (b) is met.

## Gate 4: Scale Threshold

A performance optimization (caching, indexing, async processing, batch processing) must be justified by a scale estimate from `scale-inference.md` or a profiling result showing measured degradation.

**Rule**: When scale-inference.md yields no estimate, assume "small scale" — FAIL for any performance optimization without evidence.

**VERDICT**: FAIL if no scale evidence or profiling result is cited.

**Valid evidence**:
- Scale estimate from `scale-inference.md` showing the optimization threshold would be reached
- A profiling run (see Gate 5) showing measured degradation under realistic load
- An explicit requirement in the story's done definitions calling for the optimization

## Gate 5: Profiling-First

No performance optimization without a measured baseline. You must cite:

- The profiling tool used (e.g., `cProfile`, `py-spy`, `hyperfine`, browser DevTools)
- The metric measured (e.g., p95 latency, CPU time, memory allocation)
- The threshold that was exceeded (e.g., "p95 > 200ms under 100 concurrent users")

**VERDICT**: FAIL if the optimization is proposed without citing a benchmark.

**Note**: Gates 4 and 5 are complementary. Gate 4 requires scale justification; Gate 5 requires a measured baseline. Both must pass for any performance optimization.

## Gate 6: LLM Self-Audit

Before proposing any complex approach, run this structured self-check and include the reflection in your proposal rationale:

1. "Is this complexity serving a requirement in the current story's done definitions, or am I solving a hypothetical future problem?"
2. "What is the simplest implementation that satisfies all done definitions and passes all tests?"
3. "If I were a reviewer, what would I flag as over-engineered here?"

**VERDICT**: The self-audit does not produce PASS/FAIL — it produces a reflection that must be included in the proposal rationale.

This gate exists because LLMs have a well-documented bias toward producing complex, impressive-looking solutions. The self-audit surfaces that bias before it reaches the reviewer.

## Justified-Complexity Path

When a gate fails but complexity IS warranted (e.g., a genuine security requirement demands a library despite being <30 lines), document:

1. **Which gate was checked**: Identify the gate number and rule that was evaluated.
2. **What evidence overrides the gate**: Cite scale data, a security requirement, a correctness guarantee, or explicit user direction (with ticket reference or session quote).
3. **Why the simpler alternative cannot satisfy the requirement**: Explain concretely what the simpler path would leave broken or insecure.

This path is not a loophole — it requires affirmative evidence, not an absence of disqualifying evidence.

## Sandbagging Prohibition

When a simple baseline option is required (e.g., in a proposal comparison), it must represent a genuinely viable implementation path.

**Prohibited**: Describing a technically inadequate option while loading the description with scalability caveats unless those caveats are grounded in Phase 1 scale evidence. A strawman simple option exists only to make the complex option look better — this is prohibited.

**Required**: The simple option must be presented as viable for the current ticket's scope. If evidence (scale data, profiling results, security requirements) genuinely disqualifies it, that evidence must come from the scale/profiling gates above, not from speculation introduced at proposal time.
