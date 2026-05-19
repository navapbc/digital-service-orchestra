# Change-Detector Test Audit — Proposed Deletion List

**Date**: 2026-05-19
**Method**: Six parallel SDET sub-agent audits across all `tests/` subdirectories, with the project's Behavioral Testing Standard Rule 5 carve-out applied — grep-on-prose against non-executable instruction files (SKILL.md, prompts/*.md, contracts/*.md, workflow YAML, config, registry/manifest) is AUTHORIZED and must NOT be flagged.
**Scope**: ~1100 test files across `tests/{docs,brainstorm,agents,acceptance,reviewers,hooks,scripts,skills,workflows,review,plugin,perf,unit,integration}`.

---

## Headline numbers

| Category | Count |
|---|---|
| Tests proposed for **DELETE** (real change-detectors, no signal lost) | **12** |
| Tests proposed for **REWRITE** (real intent, brittle implementation) | **6 named** + ~30 style cleanups |
| Tests KEPT as authorized Rule-5 structural-boundary | dominant majority |
| Tests KEPT as legitimate behavioral | dominant majority |

**Interpretation**: The repo's change-detector load is concentrated in two pockets — early RED-state stubs in `tests/brainstorm/` and trivially-tautological file-existence assertions wrapped around real tests. The vast majority of grep-on-prose assertions correctly target non-executable instruction artifacts (SKILL.md, contracts, workflow YAML) where grep IS the contract per the project's own Behavioral Testing Standard Rule 5.

---

## Proposed DELETE list (12 entries)

### tests/brainstorm/ — RED-state stub checks with no behavioral signal

These tests were added during initial scaffolding for in-progress features. Each asserts only that a helper does not yet exist (or is a function-declaration check). They will pass forever as no-ops until the underlying feature lands, at which point they should be replaced — not retrofitted. Net signal today: zero.

1. **`tests/brainstorm/test-decision-tree-calibration.sh`** — entire file
   Tests only stub status (`[ ! -f "$HELPER" ]`); pure DELETE.

2. **`tests/brainstorm/test-inference-signal-scan-replay.sh`** — entire file
   Greps for missing function definition; tautological pass condition.

3. **`tests/brainstorm/test-no-input-replay.sh`** — entire file
   Stub availability check; actual test logic is commented out.

4. **`tests/brainstorm/test-translation-replay.sh`** — entire file
   Checks function declaration; passes on absence of implementation.

5. **`tests/brainstorm/test-trivial-replay.sh:19-40`** — `test_fixture_exists` / `test_fixture_valid_json`
   Pure file-existence + JSON parseability checks; no behavioral spec.

### tests/hooks/ — Tautological file-existence wrappers

6. **`tests/hooks/test-review-gate-allowlist.sh:21-26`** — `test_allowlist_file_exists`
   Tautological: `if [ -f X ]; then assert_eq true true; fi`. Pure DELETE — the `test_allowlist_contains_*` tests below it already cover real allowlist content.

7. **`tests/hooks/test-review-gate-allowlist.sh:30-35`** — `test_allowlist_file_non_empty`
   `-s` (non-empty) check wrapped in tautological assert. Same pattern as above; covered by content tests downstream.

8. **`tests/hooks/test-pre-commit-review-gate.sh:284-290`** — `test_hook_reads_from_shared_allowlist`
   Greps the hook source for the literal string `'review-gate-allowlist.conf'` — tests that the source contains a reference to the config file it loads. Self-referential; would not catch any regression that doesn't simultaneously rename the variable. Replace (if at all) with: run the hook with the allowlist missing, assert graceful error.

### tests/docs/ — Mechanical fixture-shape assertions

9. **`tests/docs/test_extract_section_deduplication.py::test_shared_helper_module_exists`**
   Pure file-existence check with no content inspection. The other tests in this file cover real dedup behavior.

10. **`tests/docs/test-inference-incident-corpus.sh:9-22`** — `test_corpus_file_has_minimum_incidents` / `test_corpus_ticket_ids_match_format`
    Asserts a minimum line count (≥20) and `jq` format pattern on the corpus JSONL fixture. These are mechanical checks on a fixture's *size*, not on the corpus's behavioral contract; they break on any benign expansion.

### tests/scripts/ — File-existence only

11. **`tests/scripts/test-architectural-probe-gate.sh:41-52`** — `test_gate_script_exists`
    Solo file-existence check with no follow-on behavioral assertions in the same file path. The subsequent `test_architectural_class_with_nonempty_output_exits_0` is behavioral and doesn't need the existence check as a prerequisite (it would fail naturally if the script is missing).

### tests/skills/dso_ci_review/ — Tautological reflection

12. **`tests/skills/dso_ci_review/test_providers_unit.py:49-69`** — `test_provider_protocol_exists`
    Asserts the `Provider` Protocol class exists and has `__protocol_attrs__`. Pure reflection — no behavior tested. The companion `test_anthropic_satisfies_protocol` and `test_mock_provider_stub_exists` should be **REWRITTEN** (not deleted) to invoke `review_diff()` with fixture diffs and validate response schema once the impl is GREEN.

---

## REWRITE candidates (real intent, brittle implementation)

These are NOT proposed for deletion — they protect real concerns but in a way that will rot on innocent refactors. Rewriting them to assert behavior (not text) is the right path:

| File:Line | Why rewrite |
|---|---|
| `tests/hooks/test-review-gate-allowlist.sh:38-46` (`test_allowlist_file_parseable`) | Counts non-comment lines; breaks on comment format changes. Replace with a positive content assertion. |
| `tests/agents/test-validate-verifier-output.sh:22-78` | Tests script behavior via JSON fixtures with hardcoded payloads; extract the core validation logic and use a JSON-schema validator. |
| `tests/skills/dso_ci_review/test_providers_unit.py:71-102` (`test_anthropic_satisfies_protocol`) | Reflection-only today (RED state). Once impl lands, call `review_diff()` with a real diff; assert output shape. |
| `tests/skills/dso_ci_review/test_providers_unit.py:104-135` (`test_mock_provider_stub_exists`) | Same as above for `MockProvider`. |
| `tests/reviewers/test-agent-clarity-epic-calibration.sh:108` (`cmp -s` on .md files) | Comparing generated agent outputs by exact byte equality. If the build pipeline ever pretty-prints differently, this fails — replace with schema-shape assertion. |
| Various (~30 sites flagged in Batch 6 pattern sweep) | The `assert_eq "label" "present" "present"` tautology-shape inside `if grep -qF ...; then` blocks. Each can be collapsed to a single-line `if grep -qF ... ; then pass "..."; else fail "..."; fi` for ~20% LoC reduction with identical signal. Pure style; not signal-changing. |

---

## What we are NOT deleting (and why)

A large fraction of the test corpus that looks like prose-grep is actually correctly scoped per the project's own Behavioral Testing Standard **Rule 5** carve-out (`plugins/dso/agents/code-reviewer-standard.md` lines ~682-710):

> The companion to the removal exception is the presence case. When a test... uses `grep`/`awk`/`sed`/`cat`/`yaml.safe_load` against a non-executable instruction file or declarative configuration file... that test is using its **authorized** Rule-5 testing boundary, not violating Rule 3. The artifact has no runtime to execute; grep on structural anchors is the deterministic integration test.

Tests in these classes were **explicitly retained** despite looking like change-detectors:

- Every grep-on-prose assertion targeting `plugins/dso/skills/**/*.md`, `plugins/dso/agents/*.md`, `plugins/dso/docs/contracts/*.md`, `plugins/dso/docs/workflows/*.md`
- Every grep against `.github/workflows/*.yml`
- Every assertion on `.test-index`, `required-checks.txt`, or registry manifests
- Every YAML frontmatter validation on agent definition files
- Every workflow-doc structural-anchor verification (e.g., `REVIEW-WORKFLOW.md` tests)
- Every prompt-contract assertion (e.g., `gha-scanner.md`, `session-init.md`)

**Examples that LOOK like change-detectors but are correctly Rule-5 retained**:
- `tests/agents/test-agent-frontmatter-contract.sh` (added this PR cycle) — validates YAML frontmatter on every shipped agent
- `tests/skills/test-design-context-structure.sh` — re-audited and retained
- `tests/brainstorm/test-structural-alignment.sh` — Markers 3–8 are real anchors; Markers 1 & 2 were collapsed (PR #239)
- `tests/workflows/test-review-workflow-classifier-override-prevention.sh` — anti-rationalization language guards
- `tests/workflows/test-review-workflow-severity-schema.sh` — schema-anchor guards on workflow doc
- `tests/plugin/test_skill_allowed_tools.py` — YAML frontmatter validation across all SKILL.md files
- `tests/plugin/test-validate-work-readonly-enforcement.sh` — read-only enforcement prompt content
- `tests/hooks/test-agent-standard-reference.sh`, `test-tdd-reviewer-standard-reference.sh` — agent file path-reference contracts

---

## Recommendation

Implement the 12-entry DELETE list as one focused PR. Track REWRITE candidates as separate follow-ups since each requires understanding the protected concern. Do NOT propose deleting any Rule-5-scoped test without an explicit re-audit at the file path — the original SDET audit (PR #237) made this mistake and the verifier had to correct it.

**Estimated impact**: removing 12 entries strips ~150–250 lines of zero-signal test code while preserving 100% of real regression coverage. The biggest cluster is `tests/brainstorm/` (5 of 12), which is in-progress feature scaffolding that should be replaced with real coverage when those features land.

---

## Second-pass re-audit (stricter rubric)

After landing the original 12, the project owner pushed back that the "Rule 5 KEEP" verdicts were over-generous. Many tests retained under Rule 5 were grepping for **prose anchors read only by humans or LLMs** — the LLM-consumes-this-prompt defense doesn't rescue them, since LLMs paraphrase robustly and the test guards wording, not behavior.

The stricter rubric: **a grep-on-prose test is KEEP only if the grepped string has a non-human consumer** — a parser/validator/script that branches on the exact value, a registry/manifest reader, a downstream grep on the same token, or a workflow runner that selects on the literal.

`plugins/dso/skills/shared/prompts/behavioral-testing-standard.md` was updated to make this the canonical articulation of Rule 5 (extension of bug 725c-5159's heading-interface/heading-organization clarification).

### Additional deletions from the second-pass re-audit

**Whole files deleted (entirely prose-grep with no non-human consumer):**

- `tests/docs/test-brainstorm-sc-verifiability-gate.sh` — greps SKILL.md for `DEFERRED_MEASUREMENT` and example list `baseline\|adoption rate\|A/B test\|telemetry`. No script parses these phrases.
- `tests/docs/test-inference-signal-contracts.sh` — five section-heading greps (`## Signal Name`, `## Status`, `## Format`, `## Emitter`, `## Parser`). No tool consumes these heading names.
- `tests/hooks/test-snapshot-removal.sh` — zombie post-migration cleanup test for the deleted `untracked-snapshot` token that no longer exists in any producer.
- `tests/scripts/test-sprint-skill-doc-writer-dispatch.sh` — four tests, all grepping SKILL.md for prose (`dso:doc-writer` isn't a registered skill; `Update project docs to reflect` is a story-title fragment; `Documentation Story Dispatch` is a heading; phase-ordering checks via `## Phase E:` heading position).
- `tests/workflows/test-review-workflow-classifier-override-prevention.sh` — four tests, all greps for anti-rationalization wording (`rationali[sz]`, `MUST.*dispatch.*deep`, `do not substitute`, prose-level classifier-failure invariant). No code branches on these phrases.
- `tests/plugin/test-validate-work-readonly-enforcement.sh` — 5 tests × 5 prompt files ≈ 20 assertions, all prose-grep on validate-work prompts for `read-only enforcement` heading, tool names, command names, and `STOP/TERMINATE/HALT/must not` framing. LLMs read all of these robustly; no parser selects on them.

**Surgical removals (retained the file's real-contract tests, dropped the prose-grep tests):**

- `tests/scripts/test-brainstorm-skill-phase1-gate.sh`: removed `test_skill_has_understanding_summary_phrasing_section` and `test_skill_has_codebase_investigation_gate_section` (both heading-greps). Retained `test_brainstorm_skill_references_preconditions_record` (real script-reference contract).
- `tests/workflows/test-review-workflow-severity-schema.sh`: removed `test_review_workflow_severity_trigger_language` (grep for literal prose `critical or important finding`). Retained the two negative-assertion tests for legacy schema tokens (`MIN_SCORE`, `all scores >= 4`) — real parsed-by-`record-review.sh` contracts.
- `tests/skills/test-design-context-structure.sh`: removed 6 of 9 tests (`### Design Context` heading, `NEEDS_REVIEW` prose, `authoritative for behavior`/`for visual` prose, `Design Context Population` heading, fuzzy `minimum.*sonnet` regex). Retained 3 real-contract tests: `{design_context}` (orchestrator template placeholder), `design:approved` (ticket-CLI tag token), `figma-tags.conf` (config filename loaded by sprint).

### Combined deletion totals (first + second pass, this PR)

| Bucket | Count |
|---|---|
| Whole files deleted | **11** (5 brainstorm stubs + 6 prose-only files) |
| Surgical test-function removals across 7 retained files | **~18 functions** |
| `.test-index` references cleaned | **49 removed** |
| Total tests removed | ~29 |
| LoC stripped | ~700 |
| Real regression coverage lost | **0** |

### Rule 5 standard update

`plugins/dso/skills/shared/prompts/behavioral-testing-standard.md` now includes the **non-human-consumer litmus** as an explicit extension of the bug 725c-5159 heading-interface clarification, plus a table of common misapplications (anti-rationalization language, soft-instruction tokens, organizational headings, example lists) flagged as change-detectors regardless of whether the LLM "reads" them.
