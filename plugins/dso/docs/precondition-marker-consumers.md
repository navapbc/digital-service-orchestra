# Precondition Marker Consumers

This document enumerates all files in the plugin that contain `EMIT-PRECONDITIONS`
landmark comments. Each landmark marks a graceful-degradation fallthrough site
where a skill silently degrades, skips a gate, or continues without blocking on failure.

**Generated from**: Story 3346-0c82, Task 54eb-6dde  
**Last updated**: 2026-05-11  
**Format**: `<!-- EMIT-PRECONDITIONS: gate_name=<name> degradation_type=<type> -->`

---

## Consumer Manifest

| File | gate_name | degradation_type | Cluster | Trigger Condition |
|------|-----------|-----------------|---------|-------------------|
| `${CLAUDE_PLUGIN_ROOT}/skills/sprint/SKILL.md` | `sprint_preconditions_entry` | `inferred_decision` | A | preconditions validator fail-open on missing upstream event |
| `${CLAUDE_PLUGIN_ROOT}/skills/sprint/SKILL.md` | `sprint_worktree_tracking` | `inferred_decision` | A | worktree tracking comment fails silently |
| `${CLAUDE_PLUGIN_ROOT}/skills/sprint/SKILL.md` | `sprint_ticket_clarity_check` | `inferred_decision` | B | ticket-clarity-check.sh unavailable — falls through to Layer 2 |
| `${CLAUDE_PLUGIN_ROOT}/skills/sprint/SKILL.md` | `sprint_complexity_evaluator` | `inferred_decision` | B | complexity-evaluator unavailable — falls through to Layer 3 |
| `${CLAUDE_PLUGIN_ROOT}/skills/sprint/SKILL.md` | `sprint_sc_haiku_gate` | `unresolved_question` | C | epic has 0 SCs — haiku gate skipped |
| `${CLAUDE_PLUGIN_ROOT}/skills/sprint/SKILL.md` | `sprint_sc_haiku_parse` | `inferred_decision` | C | SC coverage haiku gate parse failure — proceed to Phase B |
| `${CLAUDE_PLUGIN_ROOT}/skills/sprint/SKILL.md` | `sprint_sc_sonnet_parse` | `inferred_decision` | C | SC coverage sonnet gate parse failure — treat all as UNSURE |
| `${CLAUDE_PLUGIN_ROOT}/skills/sprint/SKILL.md` | `sprint_sc_opus_parse` | `inferred_decision` | C | SC coverage opus gate parse failure — treat all as MISSING |
| `${CLAUDE_PLUGIN_ROOT}/skills/sprint/prompts/auto-resume.md` | `sprint_auto_resume` | `inferred_decision` | A | no children found — fall through to Preplanning Gate |
| `${CLAUDE_PLUGIN_ROOT}/skills/sprint/prompts/test-failure-dispatch-protocol.md` | `sprint_test_failure_dispatch` | `inferred_decision` | A | revert task to open on attempt 2 / timeout / malformed result |
| `${CLAUDE_PLUGIN_ROOT}/skills/brainstorm/SKILL.md` | `brainstorm_ui_detector` | `inferred_decision` | E | UI classifier agent failure — treat result as non-ui |
| `${CLAUDE_PLUGIN_ROOT}/skills/brainstorm/SKILL.md` | `brainstorm_ux_probes` | `unresolved_question` | E | non-interactive path — UX probes deferred |
| `${CLAUDE_PLUGIN_ROOT}/skills/brainstorm/SKILL.md` | `brainstorm_external_dep_block` | `inferred_decision` | F | external-dep-block config gate not enabled — skip sub-step |
| `${CLAUDE_PLUGIN_ROOT}/skills/brainstorm/phases/approval-gate.md` | `brainstorm_web_research_skip` | `unresolved_question` | F | web research skipped via graceful degradation |
| `${CLAUDE_PLUGIN_ROOT}/skills/brainstorm/phases/approval-gate.md` | `brainstorm_scenario_analysis_skip` | `unresolved_question` | F | scenario analysis skipped (≤2 success criteria) |
| `${CLAUDE_PLUGIN_ROOT}/skills/preplanning/SKILL.md` | `preplanning_interaction_deferred_tag` | `inferred_decision` | G | ticket show fails for interaction:deferred check — treat tag as absent |
| `${CLAUDE_PLUGIN_ROOT}/skills/preplanning/SKILL.md` | `preplanning_ui_probes_tag` | `inferred_decision` | G | ticket show fails for ui_probes:deferred check — treat tag as absent |
| `${CLAUDE_PLUGIN_ROOT}/skills/preplanning/SKILL.md` | `preplanning_preconditions_validator` | `inferred_decision` | G | preconditions-validator.sh not found — fail-open |
| `${CLAUDE_PLUGIN_ROOT}/skills/preplanning/SKILL.md` | `preplanning_complexity_evaluator` | `inferred_decision` | G | complexity evaluator malformed JSON — fall through to full preplanning |
| `${CLAUDE_PLUGIN_ROOT}/skills/preplanning/SKILL.md` | `preplanning_integration_research` | `unresolved_question` | H | no external integration signals — integration research skipped |
| `${CLAUDE_PLUGIN_ROOT}/skills/preplanning/SKILL.md` | `preplanning_adversarial_review` | `unresolved_question` | H | fewer than 3 stories — adversarial review skipped |
| `${CLAUDE_PLUGIN_ROOT}/skills/preplanning/SKILL.md` | `preplanning_story_research` | `inferred_decision` | H | WebSearch/WebFetch unavailable — story research skipped |
| `${CLAUDE_PLUGIN_ROOT}/skills/preplanning/SKILL.md` | `preplanning_research_findings_merge` | `inferred_decision` | H | missing or corrupt RESEARCH_FINDINGS — treat as empty array |
| `${CLAUDE_PLUGIN_ROOT}/skills/implementation-plan/SKILL.md` | `implementation_plan_tag_guard` | `inferred_decision` | D | tag guard lookup failure (rc=2) — treat as OK |
| `${CLAUDE_PLUGIN_ROOT}/skills/implementation-plan/SKILL.md` | `implementation_plan_research_findings` | `inferred_decision` | D | researchFindings parse failed — treat as empty |
| `${CLAUDE_PLUGIN_ROOT}/skills/implementation-plan/SKILL.md` | `implementation_plan_gap_analysis` | `unresolved_question` | D | story classified TRIVIAL — gap analysis skipped |
| `${CLAUDE_PLUGIN_ROOT}/skills/implementation-plan/SKILL.md` | `implementation_plan_gap_analysis_failure` | `inferred_decision` | D | gap analysis failure non-blocking — log warning and continue |
| `${CLAUDE_PLUGIN_ROOT}/skills/debug-everything/SKILL.md` | `debug_everything_aws_infra` | `inferred_decision` | J | AWS auth not configured — infrastructure checks skipped |
| `${CLAUDE_PLUGIN_ROOT}/skills/debug-everything/SKILL.md` | `debug_everything_validate_sh` | `inferred_decision` | J | validate.sh || true — continue regardless of outcome |
| `${CLAUDE_PLUGIN_ROOT}/skills/debug-everything/SKILL.md` | `debug_everything_semantic_conflict` | `inferred_decision` | J | error field present — log warning, proceed with commit |
| `${CLAUDE_PLUGIN_ROOT}/skills/debug-everything/SKILL.md` | `debug_everything_discovery_propagation` | `inferred_decision` | J | collect-discoveries.sh fails — log warning and proceed |
| `${CLAUDE_PLUGIN_ROOT}/skills/fix-bug/SKILL.md` | `fix_bug_feature_request_gate` | `inferred_decision` | I | feature-request gate script failure — defaults to non-blocking |
| `${CLAUDE_PLUGIN_ROOT}/skills/fix-bug/SKILL.md` | `fix_bug_intent_search` | `inferred_decision` | I | intent-search agent dispatch fails — treat as ambiguous |
| `${CLAUDE_PLUGIN_ROOT}/skills/fix-bug/SKILL.md` | `fix_bug_feature_request_check` | `inferred_decision` | I | feature-request-check.py exits nonzero — treat as triggered:false |
| `${CLAUDE_PLUGIN_ROOT}/skills/fix-bug/SKILL.md` | `fix_bug_post_fix_gates` | `inferred_decision` | I | all post-fix gates fail-open on error |
| `${CLAUDE_PLUGIN_ROOT}/skills/validate-work/SKILL.md` | `validate_work_staging_config` | `inferred_decision` | — | staging URL absent — validation step skipped |
| `${CLAUDE_PLUGIN_ROOT}/skills/shared/workflows/epic-scrutiny-pipeline.md` | `scrutiny_pipeline_web_research` | `inferred_decision` | — | WebSearch/WebFetch fails in web research phase |

---

## Future Consumers (not yet implemented)

The following components are planned to consume `EMIT-PRECONDITIONS` landmarks
as part of the preconditions-record.sh integration (see epic 736d-b957):

| Component | Planned Usage |
|-----------|---------------|
| `hooks/pre-commit-check-precondition-emit.sh` | SC3: pre-commit hook detecting landmark presence and triggering preconditions-record.sh calls |
| `preconditions-ack` CLI subcommand | SC2: reading ACK events to verify graceful-degradation decisions are acknowledged before story closure |

---

## Cluster Legend

| Cluster | Scope |
|---------|-------|
| A | Sprint entry-gate, worktree-tracking, and auto-resume fail-silents |
| B | Sprint clarity and complexity routing fallthrough |
| C | Sprint SC coverage gate parse-failure fail-opens |
| D | Implementation-plan tag guard, research-findings, and gap analysis |
| E | Brainstorm UI detector and UX probe deferral |
| F | Brainstorm external-dependency-block config gate and approval-gate degradations |
| G | Preplanning tag checks, preconditions validator, and complexity evaluator |
| H | Preplanning integration research, adversarial review, and research-findings merge |
| I | Fix-bug intent gate and feature-request gate graceful degradation |
| J | Debug-everything infrastructure and tooling fail-open |
