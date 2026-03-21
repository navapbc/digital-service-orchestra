---
id: w21-ovpn
status: open
deps: [w21-ykic]
links: []
created: 2026-03-20T23:49:59Z
type: epic
priority: 1
assignee: Joe Oakhart
---
# Review Intelligence & Precision


## Notes

**2026-03-20T23:50:55Z**


## Context

With tiered review routing in place (w21-ykic: Tiered Review Architecture), the review system directs changes to appropriate scrutiny levels. But reviewers have blind spots: they cannot see code duplication against the broader codebase (only the diff), they report uncertain findings at the same confidence as definitive ones (creating fix-then-revert cycles), and failed review cycles always escalate to the user even when a more capable model might resolve the disagreement. This epic makes reviewers smarter — giving them codebase-wide visibility, confidence-aware reporting, and self-correcting escalation — while measuring whether these improvements actually reduce the three failure modes (false positives, false negatives, debt accumulation).

Epic A (w21-ykic) owns the review dimension names (correctness, verification, hygiene, design, maintainability) and their top-level definitions. This epic's checklist work is additive only — it adds sub-criteria, confidence rules, and similarity hooks to each dimension. No story in this epic renames or restructures dimensions. Escalation tier upgrade is additive to Epic A's routing — it does not redefine tier boundaries.

## Success Criteria

### Pre-Analysis Similarity Pipeline
- A pre-review script (plugins/dso/scripts/review-similarity-search.sh) extracts added/modified function and class names from the staged diff. Python: ast module. Other files: regex fallback (def, class, function, const/let/var patterns).
- Searches codebase for exact-name matches plus >70% token overlap signatures. Capped at 20 matches, each with file path, line number, 5-line snippet. Output to $ARTIFACTS_DIR/pre-analysis-report.json.
- Included in reviewer context on initial review. Re-reviews use cached report (not recomputed).
- Graceful degradation: if search fails (error, exit 144, timeout), review proceeds without it. Reviewer prompt includes fallback instruction for extra duplication scrutiny.

### Enriched Review Checklists (6 per-reviewer stories)
The single "Enriched Review Checklist" criterion is decomposed into 6 stories, one per reviewer agent. Each story produces a dimension-specific checklist in the corresponding reviewer-delta file — a partial prompt file merged with reviewer-base.md at build time via build-review-agents.sh to produce the full reviewer prompt. All checklists are informed by research into Google engineering practices, OWASP, test smell literature, and criteria analysis from 5 popular Claude Code review plugins.

**Story 1 — Light tier (haiku) checklist:**
- 6 items only: silent failures (swallowed exceptions, empty catch blocks), tolerance/assertion weakening, test-code correspondence (production change → test change in same diff?), type system escape hatches without justification, dead code introduced in the diff, non-descriptive names in the diff
- No codebase research (no Grep/Read), no similarity pipeline, no ticket context
- Escape hatch: if no issues found, state so explicitly

**Story 2 — Standard tier (sonnet) checklist:**
- Full coverage across all 5 dimensions with researched sub-criteria
- Ticket context: condensed (title + acceptance criteria, token-budgeted)
- Correctness: edge cases/failure states with escape hatch, race conditions in async operations, silent failures, tolerance/assertion weakening, over-engineering/YAGNI
- Verification: behavior-driven not implementation-driven tests, test-code correspondence in same changeset, assertion quality (meaningful assertions vs. "assert not None"), arrange-act-assert structure, test smells (naming after concepts not behaviors, verbose inline fixtures)
- Hygiene: type system escape hatches (Any/any/interface{}) without justifying comments, nesting depth >2 levels (suggest early returns or extraction), dead code, suppression scrutiny (noqa/type:ignore must have justifying comments), explicit exclusion of linter-catchable issues
- Design: SOLID adherence, architectural pattern adherence, correct file/folder placement, Rule of Three duplication via similarity pipeline (flag at 3+ occurrences with same reason to change), coupling/dependency direction (no circular deps, no cross-layer reaching), reuse of existing utilities
- Maintainability: codebase consistency (local patterns — error handling style, return type patterns, abstraction level — not linter rules), clear and accurate naming (flag non-descriptive names AND names that imply different behavior than implementation), comments explain "why" not "what", doc correspondence for public interface changes (minor severity — flag only when a specific existing doc artifact is stale; do not flag documentation that never existed)
- Anti-shortcut detection distributed: noqa/type:ignore -> hygiene, skipped tests -> verification, increased tolerances/removed assertions -> correctness
- Consolidation findings always severity=minor. No inline resolution. Orchestrator creates tracking ticket (tk create) for each

**Story 3 — Deep Sonnet A (correctness) checklist:**
- Deep correctness specialist with full ticket context (minus verbose status update notes)
- All Standard correctness criteria plus: acceptance criteria validation against ticket, deeper edge-case analysis with explicit escape hatch ("if code handles this adequately, state so — do not manufacture findings")
- Inaccurate naming (name implies different behavior than implementation) elevated from minor to important at this tier

**Story 4 — Deep Sonnet B (verification) checklist:**
- Deep verification specialist, no ticket context
- All Standard verification criteria plus: test as documentation (can someone read the test and understand intended behavior?), test isolation evaluation
- Does not identify edge cases itself — evaluates whether test suite covers edge cases present in the code
- Scope boundary with dso-ppwp: this story owns checklist criteria for how the reviewer evaluates test quality in the diff; dso-ppwp owns the pre-commit test gate enforcement that blocks commits when tests haven't been run

**Story 5 — Deep Sonnet C (hygiene + design + maintainability) checklist:**
- Deep structural specialist, no ticket context
- All Standard hygiene/design/maintainability criteria plus: flag functions where branching depth suggests extraction opportunities, evaluate whether new abstractions follow single responsibility, flag in-place mutation of shared data structures when immutable patterns are established in surrounding code

**Story 6 — Deep Opus (architectural synthesis) checklist:**
- Cross-cutting synthesis reviewer with full ticket context and all 3 specialists' findings
- Self-directed git history investigation (no orchestrator pre-gathering — opus runs targeted git blame/log on specific files based on what it sees in findings and diff)
- Cross-cutting coherence: resolve contradictions between specialist findings
- Untested edge cases: cross-reference Sonnet A edge cases against Sonnet B test coverage findings
- Architectural boundary shifts: logic/validation/data moving between layers
- Pattern divergence: new approach to something the codebase already has a pattern for
- Acceptance criteria completeness: does the change fulfill what the ticket asked for?
- Unrelated scope: flag changes that include modifications unrelated to the stated ticket objective
- Regression awareness: repeated patches to same area suggesting deeper issue (via targeted git blame)
- Root cause vs. symptom: does the fix address the underlying cause or just the visible symptom?

### Shared Base Prompt Updates
- Anti-manufacturing directive: "Report only findings where your confidence is high. If a dimension is well-handled by the code under review, state so explicitly — do not manufacture findings to fill gaps. A clean pass with rationale is more valuable than a low-confidence finding."
- Independent validation: "Each flagged issue must be independently validated with high-confidence confirmation before reporting."
- These are universal behavioral instructions in reviewer-base.md, not dimension-specific criteria.

### Ticket Context Strategy
- Light (haiku): none — context budget too small
- Standard (sonnet): condensed (title + acceptance criteria, token-budgeted) — reduces false positives at the most common tier
- Deep Sonnet A (correctness): full ticket (minus verbose status update notes) — acceptance criteria validation is a correctness checklist item
- Deep Sonnet B (verification): none — test quality is code-observable
- Deep Sonnet C (hygiene/design/maintainability): none — structural quality is ticket-independent
- Deep Opus (architectural): full ticket (minus verbose status update notes) — cross-cutting synthesis needs intent context
- Ticket context is optional — not all changes have tickets. Reviewers must not block on missing ticket context.

### Confidence Scoring
- Per-finding confidence scores (integer 0-100) required in reviewer output.
- 80+ included. Below 60 excluded. 60-79 triggers investigation: reviewer greps for flagged symbol/pattern, checks for corroborating evidence. If investigation raises above 80, include. If confirms spurious, exclude with one-line rationale.
- Investigation capped at 3 per review. Findings 4+ in 60-79 band: same-dimension findings inherit prior investigation result; otherwise below 70 excluded, 70+ included at 80.
- Confidence recorded as field on each finding in reviewer-findings.json.

### False-Positive Filters
- Objective filters: (1) exclude linter/type-checker-catchable issues, (2) exclude temporal information (model names, API versions, URLs). (3) Pre-existing not-in-diff filter applies only to files entirely untouched by the commit — modified files have all findings eligible.
- Subjective filters explicitly excluded per R2 no-dismissal rule.

### Escalation Tier Upgrade
- After 2 consecutive failed review cycles (resolution sub-agent completes fix, subsequent re-review produces critical or important findings), the third cycle uses the next higher model tier for both reviewer and resolution sub-agent (sonnet -> opus); the model upgrade is recorded in reviewer-findings.json (escalation_tier field).
- Maximum cycles before user escalation configurable via review.max_cycles in dso-config.conf (default: 3).
- Escalated reviewer evaluates whether persisting findings are legitimate. If cleared, review passes. If findings persist, escalate to user.

### Re-Review Scoping
- Re-review receives scoped diff: (1) files changed since last review, (2) files flagged in previous findings, (3) files that import any changed file (1-hop only; Python import/from and shell source parsed; unrecognized languages included by default as safety measure).
- Generated by plugins/dso/scripts/review-scope-diff.sh. Interface: --previous-files=<comma-separated> (from prior reviewer-findings.json) and --staged flag (uses git diff --cached). Outputs scoped diff to stdout.
- Initial similarity report included as static context on re-reviews.
- Resolution sub-agent MUST NOT read or write reviewer-findings.json. Receives findings via task prompt only.

### Validation Signals (post-deployment monitoring, not pre-launch gates)
All four metrics must be instrumented and queryable at launch:
- False positive rate: median re-review iteration count per commit is equal to or lower after 30 commits than the pre-deployment baseline. Baseline artifact: median iteration count over last 30 pre-deployment commits must be captured and committed before the similarity pipeline story ships.
- False negative rate: post-commit CI failure rate is tracked 2 weeks pre/post deployment and queryable via classifier-telemetry.jsonl.
- Debt accumulation: new reviewer run against last 10 merged commit diffs produces equal or higher design/maintainability finding rate than current reviewer on same diffs.
- Confidence calibration: on 20 historical findings labeled by the implementing engineer against ground-truth outcomes from merged commits, the 60/80 threshold buckets achieve >=80% precision AND >=80% recall before deployment.

## Approach
Enhance reviewers with codebase-wide visibility (similarity pipeline), confidence-aware reporting (scoring bands with investigation), and self-correcting escalation (tier upgrade on repeated failures). Measure impact against the three original failure modes with instrumented telemetry.

## Referenced Artifacts
- code-review-dispatch.md (plugins/dso/docs/workflows/prompts/) — legacy fallback, no longer primary modification target — modified
- reviewer-base.md (plugins/dso/docs/workflows/prompts/) — anti-manufacturing directive, independent validation, confidence scoring, false-positive filters — modified
- reviewer-delta-light.md (plugins/dso/docs/workflows/prompts/) — Light tier checklist — new file
- reviewer-delta-standard.md (plugins/dso/docs/workflows/prompts/) — Standard tier checklist — new file
- reviewer-delta-deep-correctness.md (plugins/dso/docs/workflows/prompts/) — Deep Sonnet A checklist — new file
- reviewer-delta-deep-verification.md (plugins/dso/docs/workflows/prompts/) — Deep Sonnet B checklist — new file
- reviewer-delta-deep-hygiene-design-maint.md (plugins/dso/docs/workflows/prompts/) — Deep Sonnet C checklist — new file
- reviewer-delta-deep-architectural.md (plugins/dso/docs/workflows/prompts/) — Deep Opus checklist — new file
- REVIEW-WORKFLOW.md (plugins/dso/docs/workflows/) — escalation upgrade, re-review scoping, ticket context dispatch — modified
- reviewer-findings.json ($ARTIFACTS_DIR/) — confidence field, escalation_tier field added — modified
- review-status ($ARTIFACTS_DIR/) — escalation cycle tracking — modified
- .claude/dso-config.conf — read review.behavioral_patterns (from Epic A), review.max_cycles — read/modified
- review-similarity-search.sh (plugins/dso/scripts/) — new file
- review-scope-diff.sh (plugins/dso/scripts/) — new file
- pre-analysis-report.json ($ARTIFACTS_DIR/) — new file
- classifier-telemetry.jsonl ($ARTIFACTS_DIR/) — add iteration count field — modified

## Dependencies
- w21-ykic (Tiered Review Architecture): Hard dependency — requires classifier, tier routing, and renamed schema. Escalation tier upgrade adds dynamic model upgrade to w21-ykic's routing; this is additive (does not redefine tier boundaries) but requires explicit coordination checkpoint before escalation story implementation. Interface ownership: w21-ykic owns tier definitions, classifier, and routing dispatch; this epic owns escalation logic, confidence scoring, and checklist content within each tier's reviewer-delta files.
- dso-ppwp (Add test gate enforcement): Soft overlap on verification anti-shortcut checks. Boundary: this epic owns reviewer checklist criteria for evaluating test quality in the diff; dso-ppwp owns pre-commit gate enforcement.
- dso-t4k8 (Don't cover up problems): Aligned intent, no hard dependency


<!-- note-id: yd0v276r -->
<!-- timestamp: 2026-03-21T18:14:34Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->


## Update: Source fragment architecture due to dso-9ltc

With review agents built from source fragments (dso-9ltc in parent epic w21-ykic), this epic's enrichments target the source fragments rather than a single code-review-dispatch.md:
- Enriched review checklist: sub-criteria added to per-agent delta files (dimension-specific content per agent)
- Confidence scoring: added to reviewer-base.md (universal — all agents need it)
- False-positive filters: added to reviewer-base.md (universal)
- Pre-analysis similarity pipeline: results passed as per-review dispatch context (not baked into agent definitions)
- Re-review scoping: dispatch context changes, not agent definition changes

After modifying source fragments, run build-review-agents.sh to regenerate all 6 agent files. The commit workflow enforces this via content hash validation.

Referenced artifacts updated:
- reviewer-base.md (replaces code-review-dispatch.md for universal guidance changes)
- reviewer-delta-*.md (replaces code-review-dispatch.md for dimension-specific changes)
- code-review-dispatch.md remains as legacy fallback but is no longer the primary modification target

