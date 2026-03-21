---
id: dso-dywv
status: closed
deps: []
links: []
created: 2026-03-19T18:21:03Z
type: epic
priority: 1
assignee: Joe Oakhart
jira_key: DIG-50
---
# Improved code review

Code review should have complexity logic that applies higher scrutiny to more complex changes. Complexity measured by lines of code, number of files touched, cross-cutting concerns, etc.

A 1-line import removal from lint should use a simpler model with a less complex prompt. A huge migration or refactor should use multiple agents and better models to better cover multiple dimensions.

Re-review should be scoped to files changed since last review + files flagged by the last review. We want to ensure that this is implemented in a way that makes it difficult for agents to game. An agent shouldn't be able to rationalize a minor change as "nothing significant changed" and exclude it from review. Our review gate needs to remain intact.

One goal is to prevent the anti-pattern of agents skipping tests, adding inline exceptions to lint rules, increasing error tolerance levels, and other behavior that quickly resolves a failure without addressing the underlying issue. We want to fix the problem, not remove visibility into the problem. Code review agents should be instructed to apply additional scrutiny to inline lint exceptions, skipped tests, and other changes that reduce visibility into problems.

Agents commonly generate code that duplicates functionality already present in the codebase. For example, generating a new type instead of reusing or extending an existing type. We want to update our code review prompt to explicitly search for similar code that already exists, protecting us from creating the same or similar functionality repeatedly. All repeated code shouldn't necessarily be consolidated. We should include guidance for how to differentiate code that should be reusable from code where centralization or abstraction would create a maintenance burden. We should use websearch and webfetch when writing this guidance (not when performing the review) to research expert guidance on how to distinguish between duplicate code that should be consolidated and duplicate code that should remain separate.

Add fragility as a code review criteria. Examples of anti-pattern include paths, dependencies, and parameters without fallbacks. We want to be hardening our codebase, not making it more brittle.

Add performance criteria to code review. Evaluate Big O notation of operations and whether a more efficient approach can be used. Avoid individual operations that can be batched. Be skeptical of nested loops and recursion. When there is a significant tradeoff between performance and complexity and the scope of data being handled is not specified, escalate to the user for guidance.

The reviewer should also consider: Does it reuse existing utilities and components where applicable? Does it follow conventions consistent with the rest of the codebase?

If the code contains visual changes (e.g to a web UI), a separate visual review should be conducted. The visual review should assess how well the implemented changes match the design manifest, whether accessibility is properly addressed, and many of the same factors used in the design review process.

## Parallel Specialized Code Reviewers (Quality + Token Efficiency)

Replace single-reviewer dispatch in REVIEW-WORKFLOW.md Step 4 with 5 parallel focused reviewers. Each reviewer gets a tight, domain-specific prompt, runs in parallel, and produces findings that map to the existing 5-dimension schema.

Schema constraint: record-review.sh enforces exactly 5 dimension keys: build_lint, object_oriented_design, readability, functionality, testing_coverage. Each parallel reviewer MUST emit findings using only these categories. The mapping:
- Reviewer 1 (Compliance) → readability + object_oriented_design
- Reviewer 2 (Bug Detection) → functionality
- Reviewer 3 (Security) → functionality (security is a functional concern)
- Reviewer 4 (Type Safety) → build_lint + testing_coverage
- Reviewer 5 (Simplification) → object_oriented_design + readability

Merge contract: The orchestrator collects reviewer-findings.json fragments from each parallel reviewer (each writes to a separate temp file), then merges them into a single reviewer-findings.json with deduplicated findings, preserving the hash-verification chain. A new merge script (merge-reviewer-findings.sh) handles this.

Token impact: Each focused reviewer needs less context than one large prompt. Parallel execution reduces wall-clock time. Net token cost may increase slightly (5 small agents vs 1 large) but quality improvement justifies it.

## Per-Finding Confidence Scores

Add per-finding confidence scores to the code reviewer prompt template. Require reviewers to self-assess confidence per finding and exclude anything below 80. This eliminates the "fix-then-revert" cycles caused by uncertain findings.

Important: The code review system and the /dso:review-protocol system are separate. This change targets only the code review pipeline:
- code-review-dispatch.md defines the code reviewer's output schema (findings in reviewer-findings.json)
- REVIEW-SCHEMA.md defines the /dso:review-protocol schema (plan/artifact reviews with perspectives and conflicts)
- These should NOT be conflated.

## Objective False-Positive Filters

Add objective false-positive filters to the reviewer prompt. Scope to verifiable, non-subjective categories only:
- Pre-existing problems not in the current diff (verifiable: compare against git diff)
- Issues a linter, type checker, or compiler would catch (verifiable: these tools already run in Step 1)
- Temporal information (model names, API versions, URLs that change over time)

Explicitly excluded from filters (these reintroduce the judgment calls R2 prevents):
- "Pedantic nitpicks senior engineers wouldn't flag" — subjective
- "Style preferences without functional impact" — subjective

This preserves R2's intent: the reviewer's judgment calls about what is "pedantic" or "stylistic" are exactly the kind of suppression R2 was designed to prevent. Objective filters (linter-catchable, not-in-diff, temporal) are safe because they can be mechanically verified.

## Additional Review Guidance

Our review prompts should exercise care over the quality of our codebase and skepticism over the code being reviewed. They should not discount review defense comments, but they should ensure that they understand the situation and agree with the comment's assessment before accepting it.

Our reviews should include a checklist that the reviewer can follow to evaluate specific aspects of the code. We should build this checklist by using websearch and webfetch to look for PR templates, code review checklists, and expert guidance on how to ensure quality through code reviews.

Review as a Senior Software Architect at Google: identify anti-patterns that will cause future issues, code that doesn't make sense, and vestigial code that is no longer needed. We want to avoid dead code in our codebase, and should be proactive about identifying dead code related to changes being reviewed.
