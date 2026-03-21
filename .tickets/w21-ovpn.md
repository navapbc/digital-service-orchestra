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

### Enriched Review Checklist
- Reviewer dispatch prompt (code-review-dispatch.md) updated with specific checks per dimension:
  - correctness: fragility (paths/deps/params without fallbacks), performance (Big O, batching, nested loops), security (OWASP), error handling robustness
  - verification: test-code correspondence, test quality (behavior not implementation), anti-shortcut (skipped tests, reduced assertions)
  - hygiene: dead code (unused imports, unreachable branches, vestigial functions), inline suppression scrutiny (noqa/type:ignore must have justifying comments)
  - design: duplication detection via similarity report, AHA/Rule of Three consolidation guidance (flag only at 3+ occurrences sharing same reason to change; keep separate when consolidation would require conditional branching or couple independently-evolving concerns), reuse of existing utilities
  - maintainability: codebase consistency, naming conventions, import organization consistent with surrounding code
- Anti-shortcut detection distributed: noqa/type:ignore -> hygiene, skipped tests -> verification, increased tolerances/removed assertions -> correctness.
- Consolidation findings always severity=minor. No inline resolution. Orchestrator creates tracking ticket (tk create) for each.

### Confidence Scoring
- Per-finding confidence scores (integer 0-100) required in reviewer output.
- 80+ included. Below 60 excluded. 60-79 triggers investigation: reviewer greps for flagged symbol/pattern, checks for corroborating evidence. If investigation raises above 80, include. If confirms spurious, exclude with one-line rationale.
- Investigation capped at 3 per review. Findings 4+ in 60-79 band: same-dimension findings inherit prior investigation result; otherwise below 70 excluded, 70+ included at 80.
- Confidence recorded as field on each finding in reviewer-findings.json.

### False-Positive Filters
- Objective filters: (1) exclude linter/type-checker-catchable issues, (2) exclude temporal information (model names, API versions, URLs). (3) Pre-existing not-in-diff filter applies only to files entirely untouched by the commit — modified files have all findings eligible.
- Subjective filters explicitly excluded per R2 no-dismissal rule.

### Escalation Tier Upgrade
- After 2 consecutive failed review cycles (resolution sub-agent completes fix, subsequent re-review produces critical or important findings), the third cycle dispatches next higher model for BOTH reviewer and resolution sub-agent (sonnet -> opus).
- Escalation state tracked via review_cycle_count in $ARTIFACTS_DIR/review-status. Escalation triggers at review.max_cycles - 1 (configured in .claude/dso-config.conf, default 3 if unset).
- Maximum review.max_cycles cycles before user escalation. Configurable per project.
- Escalated reviewer evaluates whether persisting findings are legitimate. If cleared, review passes. If findings persist, escalate to user.

### Re-Review Scoping
- Re-review receives scoped diff: (1) files changed since last review, (2) files flagged in previous findings, (3) files that import any changed file (1-hop only; Python import/from and shell source parsed; unrecognized languages included by default as safety measure).
- Generated by plugins/dso/scripts/review-scope-diff.sh. Interface: --previous-files=<comma-separated> (from prior reviewer-findings.json) and --staged flag (uses git diff --cached). Outputs scoped diff to stdout.
- Initial similarity report included as static context on re-reviews.
- Resolution sub-agent MUST NOT read or write reviewer-findings.json. Receives findings via task prompt only.

### Validation Signals (post-deployment monitoring, not pre-launch gates)
- False positive rate: re-review iteration count per commit in classifier telemetry. After 30 commits, compare median to pre-deployment baseline. Any reduction is directionally positive.
- False negative rate: post-commit CI failures tracked 2 weeks pre/post deployment. Sustained increase (>10% week-over-week for 2 consecutive weeks) indicates a gap.
- Debt accumulation: run new reviewer against last 10 merged commit diffs as calibration before go-live. Higher design/maintainability finding rate than current reviewer on same diffs.
- Confidence threshold calibration: before deploying 60/80 thresholds, run against 20 labeled historical findings (labeled by implementing engineer as true-positive or false-positive). Thresholds must achieve >=80% precision AND >=80% recall. Adjust before deployment if not met.

## Approach
Enhance reviewers with codebase-wide visibility (similarity pipeline), confidence-aware reporting (scoring bands with investigation), and self-correcting escalation (tier upgrade on repeated failures). Measure impact against the three original failure modes with instrumented telemetry.

## Referenced Artifacts
- code-review-dispatch.md (plugins/dso/docs/workflows/prompts/) — enriched checklist, confidence, filters — modified
- REVIEW-WORKFLOW.md (plugins/dso/docs/workflows/) — escalation upgrade, re-review scoping — modified
- reviewer-findings.json ($ARTIFACTS_DIR/) — confidence field added — modified
- review-status ($ARTIFACTS_DIR/) — escalation cycle tracking — modified
- .claude/dso-config.conf — read review.behavioral_patterns (from Epic A), review.max_cycles — read/modified
- review-similarity-search.sh (plugins/dso/scripts/) — new file
- review-scope-diff.sh (plugins/dso/scripts/) — new file
- pre-analysis-report.json ($ARTIFACTS_DIR/) — new file
- classifier-telemetry.jsonl ($ARTIFACTS_DIR/) — add iteration count field — modified

## Dependencies
- w21-ykic (Tiered Review Architecture): Hard dependency — requires classifier, tier routing, and renamed schema
- dso-ppwp (Add test gate enforcement): Soft overlap on verification anti-shortcut checks
- dso-t4k8 (Don't cover up problems): Aligned intent, no hard dependency

