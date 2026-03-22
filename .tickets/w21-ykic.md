---
id: w21-ykic
status: in_progress
deps: []
links: []
created: 2026-03-20T23:48:51Z
type: epic
priority: 1
assignee: Joe Oakhart
---
# Tiered Review Architecture


## Notes

**2026-03-20T23:49:43Z**


## Context

Autonomous agents commit code through a review gate that is the final safeguard for codebase quality in a critical system where reliability is a requirement. Today, a single-reviewer architecture applies the same level of scrutiny to every change — from a one-line import removal to a cross-cutting refactor touching shared infrastructure. This wastes resources on trivial changes and under-scrutinizes complex ones. Agents also frequently attempt to bypass scrutiny by characterizing behavioral file edits (skills, CLAUDE.md, hooks) as doc-only changes — these files are executable agent instructions and must receive the same scrutiny as source code. This epic builds the routing infrastructure that directs changes to the appropriate level of review scrutiny.

## Success Criteria

### Complexity Classifier
- A deterministic shell script (plugins/dso/scripts/review-complexity-classifier.sh) accepts a diff as input and outputs a JSON object containing: per-factor scores (blast_radius, critical_path, anti_shortcut, staleness, cross_cutting, diff_lines, change_volume — each an integer), computed_total (integer), and selected_tier (light|standard|deep). The script exits 0 on success.
- Scoring factors: blast_radius = max import/usage count across changed source files (0-3 pts); critical_path = touches persistence, auth, security, or request handling paths (0-3 pts); anti_shortcut = count of noqa, type:ignore, pytest.mark.skip, tolerance-change patterns in diff (0-3 pts); staleness = max days since last substantive modification across changed files (0-2 pts); cross_cutting = distinct top-level directories touched (0-2 pts); diff_lines = non-test, non-ticket lines added+modified (0-1 pt); change_volume = count of source + behavioral files changed (0-1 pt).
- Floor rules override computed score: any anti-shortcut signal → minimum score 3 (Standard); any critical-path file touched → minimum score 3; any safeguard file (CLAUDE.md rule #20 list, plus the classifier script itself) touched → minimum score 3; test file deletion without corresponding source deletion → minimum score 3; exception handler broadening (catch Exception, bare except) → minimum score 3.
- Diff size thresholds: 300+ lines of non-test, non-generated code → model upgrade to opus at current tier's checklist scope. 600+ lines → review rejected with structured message referencing plugins/dso/docs/prompts/large-diff-splitting-guide.md. Exceptions: generated code (migrations, lock files) and test-only diffs bypass size limits at Standard tier. Merge commits bypass size limits entirely; review scope limited to conflicted files plus session-modified files.
- Every classification decision appends one JSON object to $ARTIFACTS_DIR/classifier-telemetry.jsonl containing all factor scores, computed_total, selected_tier, and staged file paths.
- If the classifier exits non-zero, times out, or is killed (exit 144), the review pipeline defaults to Standard tier. The classifier never skips or downgrades review.
- The classifier script is added to the safeguard files list in CLAUDE.md rule #20.

### Behavioral File Classification
- Behavioral file path patterns stored in .claude/dso-config.conf under review.behavioral_patterns key (semicolon-delimited glob list). Default: plugins/dso/skills/**;plugins/dso/hooks/**;plugins/dso/docs/workflows/**;plugins/dso/docs/prompts/**;plugins/dso/commands/**;plugins/dso/scripts/**;CLAUDE.md;.claude/**. Classifier reads this at runtime.
- Files matching behavioral patterns receive full scoring weight. Files matching review-gate-allowlist.conf are exempt (score 0, no review). All other files scored normally.

### Tier Routing
- Score 0-2: Light tier — single haiku reviewer, reduced checklist (highest-signal checks from each dimension only).
- Score 3-6: Standard tier — single sonnet reviewer, full checklist across all 5 dimensions.
- Score 7+: Deep tier — three parallel sonnet reviewers (Sonnet A: correctness; Sonnet B: verification; Sonnet C: hygiene + design + maintainability), followed sequentially by an opus architectural reviewer. Each sonnet writes to $ARTIFACTS_DIR/reviewer-findings-{a,b,c}.json. Opus receives all three plus full diff, writes final reviewer-findings.json. Single-writer invariant preserved.

### Schema Revision
- Review output schema updated from 5 dimension keys to 5 renamed keys: correctness (replaces functionality), verification (replaces testing_coverage), hygiene (replaces build_lint), design (replaces object_oriented_design), maintainability (replaces readability).
- All consumers updated: record-review.sh, write-reviewer-findings.sh, code-review-dispatch.md, and any orchestrator code reading dimension keys.
- Dimension concern mapping: correctness = bugs, fragility, performance, security, error handling, tolerance changes; verification = test coverage, test quality, skipped tests, test-code correspondence; hygiene = dead code, lint compliance, type checking, inline suppressions; design = duplication/reuse, abstractions, component structure, patterns; maintainability = readability, codebase consistency, naming, conventions.

### Validation Signal (post-deployment monitoring, not pre-launch gate)
- After 30 commits: compute tier distribution. Expected healthy baseline ~50-60% Light, 30-40% Standard, 5-15% Deep. Single tier >80% = miscalibrated.
- Light-tier reviews producing critical/important findings >10% = insufficient floor rules. Response: add triggering pattern to floor rules, re-validate against 30-commit sample.
- Track post-merge CI failure rate by tier for first 30 commits. Light tier higher failure rate than Standard/Deep = under-classification. Response: lower Light/Standard threshold or add floor rules.
- Compare overall post-merge CI failure rate against 30 commits preceding deployment. Sustained increase = routing gap.
- Breach response: create P1 bug ticket, adjust classifier, re-validate against same sample.

## Approach
Tiered review routing with deterministic complexity classification. Changes are scored on 7 weighted factors and routed to Light (haiku), Standard (sonnet), or Deep (3 sonnets + opus) review tiers. Floor rules ensure sensitive changes always receive adequate scrutiny. Schema revised to 5 renamed dimensions that better encompass expanded review concerns.

## Referenced Artifacts
- review-gate-allowlist.conf (plugins/dso/hooks/lib/) — glob patterns for exempt files — no changes
- REVIEW-WORKFLOW.md (plugins/dso/docs/workflows/) — tier dispatch logic — modified
- code-review-dispatch.md (plugins/dso/docs/workflows/prompts/) — reviewer prompt — modified
- record-review.sh (plugins/dso/hooks/lib/) — dimension key rename — modified
- write-reviewer-findings.sh (plugins/dso/hooks/lib/) — dimension key rename — modified
- .claude/dso-config.conf — add review.behavioral_patterns, review.max_cycles — modified
- large-diff-splitting-guide.md (plugins/dso/docs/prompts/) — new file
- review-complexity-classifier.sh (plugins/dso/scripts/) — new file

## Dependencies
- dso-ppwp (soft overlap on anti-shortcut floor rules)


**2026-03-21T00:11:33Z**

Version-only changes to plugin.json (e.g., patch bump) should be exempt from review. This is a common friction point that the tiered review classifier should handle by routing trivial JSON changes to Light tier. Consider adding plugin.json version-only changes to the allowlist or classifier floor rules.

**2026-03-21T00:16:09Z**

User request: As long as the version is the only line changed in plugin.json, this change should be exempt from review. This is a common use case (patch bump on every commit). The classifier should detect single-field JSON changes and route to exempt or Light tier. Alternatively, add a conditional allowlist entry for plugin.json when only the version field changes.

<!-- note-id: jw7lt4qg -->
<!-- timestamp: 2026-03-21T18:14:27Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->


## Update: Review agent build process added (dso-9ltc)

New foundational story dso-9ltc creates 6 dedicated code-reviewer agents built from shared source fragments via build-review-agents.sh. This is now the root of the dependency chain.

Updated dependency graph:
  dso-9ltc (new: agent build process) — no blockers
    → w21-zp4d (schema rename — scope reduced to non-agent consumers)
      → w21-jtkr (classifier + routing — dispatches to named agents)
        → w21-txt8 (Deep tier — dispatches to named deep agents)
        → w21-nv42 (diff size thresholds — unchanged)
          → w21-0kt1 (telemetry — unchanged)
            → w21-epz2 (docs — unchanged)

Additional referenced artifacts:
- plugins/dso/agents/code-reviewer-*.md (6 generated agent files)
- plugins/dso/docs/workflows/prompts/reviewer-base.md (base fragment)
- plugins/dso/docs/workflows/prompts/reviewer-delta-*.md (per-agent deltas)
- plugins/dso/scripts/build-review-agents.sh (build script)


<!-- note-id: sn46liow -->
<!-- timestamp: 2026-03-22T13:11:59Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

Schema Compliance Baseline (pre-tiered-agents):
| Diff | Size | First-attempt pass | Notes |
|------|------|-------------------|-------|
| ec78680 | 255 lines | yes | Actual pipeline run (staleness enforcement commit); telemetry shows hash_match=true, outcome=pass at 2026-03-22T13:08:42Z; reviewer-findings.json written successfully |
| ab509f8 | 1994 lines | yes | Large diff (6 generated agent files + build-review-agents.sh); write-reviewer-findings.sh validated on first attempt; schema-hash=6c0b61af0ff149ee |
| 1b84ac9 | 1257 lines | yes | Medium diff (reviewer source fragments: base + 6 deltas); write-reviewer-findings.sh validated on first attempt; schema-hash=6c0b61af0ff149ee |

All 3 diffs pass schema validation on first attempt. The existing code-review-dispatch prompt and write-reviewer-findings.sh schema enforcement are functioning correctly pre-integration of generated agents. This baseline confirms a 100% first-attempt pass rate to compare against after w21-jtkr integrates the tiered agents.
