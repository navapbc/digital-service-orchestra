# Shared Prior-Art Search Protocol

Standalone sub-workflow for determining whether to search for prior art before writing or modifying code. Consulted by agents at the start of any implementation task to avoid redundant work, inconsistent patterns, or missed reuse opportunities.

## Bright-Line Triggers

Agents MUST search for prior art before writing code when ANY of the following conditions are true:

- New utility function, helper, or module is being created (may already exist elsewhere)
- New abstraction, interface, or design pattern is being introduced into the codebase
- External API, CLI tool, or third-party library is being integrated for the first time
- A workaround or fix is being applied to a problem that has been seen before (recurrence risk)
- A new test pattern, fixture, or testing helper is being created
- A configuration key or schema field is being added (may conflict or duplicate existing keys)
- Cross-cutting concerns are being addressed (logging, error handling, auth, metrics)
- Code is being copied or adapted from external sources (license and prior usage check required)

## Trust Validation Gate

Before treating any discovered prior art as a reliable reference, agents must evaluate its trustworthiness. Hard blockers are evaluated first and must be resolved before proceeding.

**Hard Blockers (evaluated first):**

- **Open bug tickets on the pattern** — if an open bug ticket references the file, function, or pattern you found, that pattern is a hard blocker. You must not copy or extend it until the bug is resolved or the user explicitly overrides.
- **CI failures on the same files** — if the files containing the discovered prior art are associated with recent CI failures, that code is a hard blocker. Treat it as untrusted until failures are resolved.

When a hard blocker is present, agents shall surface it to the user and block the planned code change. Do not proceed by substituting soft signals when a hard blocker is unresolved.

**Soft Signals (apply only when no hard blockers are present):**

- Passing tests covering the discovered code increase trust
- Consistent usage patterns across multiple files indicate established convention
- Recent authorship (within the last few sprints) suggests the pattern is current

Trust level determines how closely to follow the prior art: high trust → replicate exactly; medium trust → adapt with caution; low trust → note pattern but derive independently.

## Tiered Search Protocol

Execute tiers in order. Stop when sufficient prior art is found or the budget is exhausted.

**Tier 1 — Project documentation and index (~2 calls)**

1. Read `CLAUDE.md` and any `.claude/docs/` files for guidance on the pattern area.
2. Check `.test-index` and any architecture decision records in `docs/` for related patterns.

If the answer is found here, stop.

**Tier 2 — Narrow codebase search (~6 calls)**

Search the current project with targeted queries:

1. Grep for the function name, class name, or concept keyword in the source tree.
2. Grep for the relevant import or dependency identifier.
3. Read the most relevant 1–3 files that surface from those searches.

Budget: approximately 6 tool calls total for this tier. If no clear prior art is found within budget, advance to Tier 3.

**Tier 3 — Broad outcome-reframed search (~10 calls)**

Reframe the search around outcomes, not implementation:

1. Search GitHub (or available code index) for projects solving the same user-facing problem.
2. Look for alternate naming conventions (synonyms, abbreviations, domain-specific terms).
3. Search for the pattern in test files — tests often name concepts more explicitly than source.
4. Read 2–4 additional files identified by these broader searches.

Budget: approximately 10 tool calls total for this tier. If no usable prior art is found, advance to user escalation.

**Tier 4 — User escalation**

If Tiers 1–3 find no usable prior art within budget, stop and report to the user:

- What was searched, including specific queries and files read
- What was found and why it was insufficient
- A concrete proposal (e.g., "implement from scratch using pattern X as the closest analogy")

Do not proceed past Tier 3 without either finding prior art or escalating.

## Routine Exclusions

Do not run a prior-art search for the following routine changes — they are low-risk and the search overhead is not justified:

- **Single-file logic fixes** — a change confined to one file that corrects a clear bug without introducing new abstractions does not require a prior-art search.
- **Formatting or lint fixes** — automated reformatting, import sorting, and lint-only corrections (no logic changes) are excluded.
- **Test reversions** — reverting a test to a known-good state (e.g., restoring a snapshot or re-enabling a skipped test) does not require a search.
- **Documentation-only edits** — changes to `.md`, `.txt`, or comment blocks with no code impact.
- **Config value updates** — changing a value in an existing config key (not adding a new key) is excluded.

## Relationship to Empirical Validation Directive (EVD)

The prior-art search protocol and the Directive address different phases of the development workflow and are complementary, not overlapping. Understanding the boundary between them prevents agents from conflating the two or applying the wrong discipline.

**Prior-art search answers the question: "Should I search before writing code?"** It operates at the decision point before any code is written or any hypothesis is formed. Its purpose is to find existing patterns, avoid duplication, and identify reuse opportunities. The output is a reference point — a piece of code, a pattern, or a design decision that the agent can follow, adapt, or cite as justification.

**The Directive answers the question: "How do I validate my assumptions during investigation?"** It operates during active investigation of a bug or behavior, after the decision to write or change code has already been made. Its purpose is to ensure that beliefs about how a system behaves are backed by empirical evidence — actual test runs, real command output — rather than documentation alone.

These two protocols complement each other without superseding one another. A prior-art search may surface code that the agent then needs to validate empirically under the Directive. Conversely, empirical investigation may reveal that a prior-art search should have been run first. The two disciplines reinforce the same underlying principle: do not act on untested assumptions.

Agents should apply both disciplines sequentially and in the appropriate context: prior-art search at task start, the Directive throughout investigation. The boundary is clear — prior-art search concerns discovery and reuse decisions; the Directive concerns hypothesis validation during active debugging.

## Non-Interactive Fallback

In sub-agent contexts where the agent cannot prompt the user (e.g., invoked via the Task tool inside `/dso:sprint` or `/dso:debug-everything`), prior-art search results must be communicated via structured output rather than an interactive dialogue.

When operating non-interactively and prior art is found, include the following JSON block in the agent's output report:

```json
{
  "prior_art_search": {
    "tier_reached": "tier2",
    "found": true,
    "references": [
      {
        "file": "${CLAUDE_PLUGIN_ROOT}/skills/shared/prompts/value-effort-scorer.md",
        "pattern": "shared prompt fragment",
        "trust": "high",
        "hard_blockers": []
      }
    ],
    "recommendation": "Follow existing pattern from reference file."
  }
}
```

When no prior art is found within budget, the output format signals the escalation:

```json
{
  "prior_art_search": {
    "tier_reached": "tier3",
    "found": false,
    "references": [],
    "recommendation": "No prior art found. Proceeding from scratch using [pattern] as closest analogy.",
    "escalation_required": true
  }
}
```

The orchestrator receiving this structured output is responsible for surfacing the escalation to the user when `escalation_required` is `true`.
