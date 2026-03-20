---
id: dso-dywv
status: open
deps: []
links: []
created: 2026-03-19T18:21:03Z
type: epic
priority: 1
assignee: Joe Oakhart
jira_key: DIG-50
---
# Improved code review

Code review should have complexity logic that applies higher scrutiny to more complex changes. Complexity measured by lines of code, number of files touched, cross-cutting concerns, etc. A 1-line import removal from lint should use a simpler model with a less complex prompt. A huge migration or refactor should use multiple agents and better models to better cover multiple dimensions.

Re-review should be scoped to files changed since last review + files flagged by the last review. We want to ensure that this is implemented in a way that makes it difficult for agents to game. An agent shouldn't be able to rationalize a minor change as "nothing significant changed" and exclude it from review. Our review gate needs to remain intact. One goal is to prevent the anti-pattern of agents skipping tests, adding inline exceptions to lint rules, increasing error tolerance levels, and other behavior that quickly resolves a failure without addressing the underlying issue. We want to fix the problem, not remove visibility into the problem. Code review agents should be instructed to apply additional scrutiny to inline lint exceptions, skipped tests, and other changes that reduce visibility into problems.

Agents commonly generate code that duplicates functionality already present in the codebase. For example, generating a new type instead of reusing or extending an existing type. We want to update our code review prompt to explicitly search for similar code that already exists, protecting us from creating the same or similar functionality repeatedly. All repeated code shouldn't necessarily be consolidated. We should include guidance for how to differentiate code that should be reusable from code where centralization or abstraction would create a maintenance burden. We should use websearch and webfetch when writing this guidance (not when performing the review) to research expert guidance on how to distinguish between duplicate code that should be consolidated and duplicate code that should remain separate.

Add fragility as a code review criteria. Examples of anti-patterns include paths, dependencies, and parameters without fallbacks. We want to be hardening our codebase, not making it more brittle.

Add performance criteria to code review. Evaluate Big O notation of operations and whether a more efficient approach can be used. Avoid individual operations that can be batched. Be skeptical of nested loops and recursion. When there is a significant tradeoff between performance and complexity and the scope of data being handled is not specified, escalate to the user for guidance.

The reviewer should also consider: Does it reuse existing utilities and components where applicable? Does it follow conventions consistent with the rest of the codebase?

If the code contains visual changes (e.g. to a web UI), a separate visual review should be conducted. The visual review should assess how well the implemented changes match the design manifest, whether accessibility is properly addressed, and many of the same factors used in the design review process.

**Parallel Specialized Code Reviewers (Quality + Token Efficiency)**: Dispatch 5 focused parallel review agents — Compliance (CLAUDE.md adherence), Bug Detection (logic errors, null gaps, race conditions), Security (OWASP, injection, auth gaps), Type Safety & Performance (type correctness, memory leaks, missing await), Code Simplification (overly complex conditionals, unnecessary abstractions, duplication). Each reviewer gets a tight, domain-specific prompt, runs in parallel, and produces findings mapped to the existing 5-dimension schema (build_lint, object_oriented_design, readability, functionality, testing_coverage). A merge script collects and deduplicates findings into a single reviewer-findings.json.

**Per-Finding Confidence Scores**: Add per-finding confidence scores to the code reviewer prompt template. Require reviewers to self-assess confidence per finding and exclude anything below 80. This eliminates "fix-then-revert" cycles caused by uncertain findings.

**Objective False-Positive Filters**: Add filters to the reviewer prompt scoped to verifiable, non-subjective categories only: pre-existing problems not in the current diff (verifiable via git diff), issues a linter/type checker/compiler would catch (already run in Step 1), temporal information (model names, API versions, URLs). Explicitly excluded: "pedantic nitpicks" and "style preferences" — these are subjective and reintroduce the judgment calls R2 prevents.

Our review prompts should exercise care over the quality of our codebase and skepticism over the code being reviewed. They should not discount review defense comments, but they should ensure that they understand the situation and agree with the comment's assessment before accepting it.

Reviews should include a checklist built from websearch/webfetch research on PR templates, code review checklists, and expert guidance on ensuring quality through code reviews.

Review for anti-patterns that will cause future issues, code that doesn't make sense, and vestigial code that is no longer needed. Be proactive about identifying dead code related to changes being reviewed.

