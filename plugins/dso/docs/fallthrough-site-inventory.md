<!-- FROZEN: 2026-05-11T00:00:00Z -->
<!-- This document is a static snapshot. Do not edit inline fallthrough sites without updating this inventory. -->

# Fallthrough Site Inventory

**Status**: FROZEN  
**Frozen at**: 2026-05-11  
**Parent story**: 3346-0c82  
**Task**: bd40-8066-9721-40c0

This document catalogues graceful-degradation prose fallthrough decision points across 11 target skill files. Each row identifies where a skill silently degrades, skips a gate, or continues without blocking on failure.

---

## EMIT-PRECONDITIONS Landmark Format

Every fallthrough site identified below should eventually be instrumented with the following landmark block inserted immediately before the degradation prose:

```markdown
<!-- EMIT-PRECONDITIONS: gate_name=<name> degradation_type=<type> -->
```

Followed by a bash block:

```bash
bash "$PLUGIN_SCRIPTS/preconditions-record.sh" --ticket-id "$STORY_ID" --gate-name <name> \  # shim-exempt: doc example only — not an actual invocation
  --session-id "$SESSION_ID" --worktree-id "$WORKTREE_ID" --tier minimal \
  --degradation --degradation-type <type> --data '{}' 2>/dev/null || true
```

### `degradation_type` values (per e959-9703 DD1)

| Value | When to use |
|-------|-------------|
| `inferred_decision` | Fallthrough where the skill makes a judgment call (e.g., "proceed without sub-agent results if timeout") |
| `unresolved_question` | Fallthrough where ambiguity or missing information causes the skip (e.g., "skip if story has no parent epic") |

---

## Inventory Table

| File | Line Range | Trigger Phrase | gate_name | degradation_type | Cluster |
|------|-----------|----------------|-----------|-----------------|---------|
| ${CLAUDE_PLUGIN_ROOT}/skills/sprint/SKILL.md | 52–56 | "fail-open: `\|\| true` prevents blocking when no upstream implementation-plan event exists yet" | sprint_preconditions_entry | inferred_decision | A |
| ${CLAUDE_PLUGIN_ROOT}/skills/sprint/SKILL.md | 126–130 | "fail silently if ticket store unavailable" | sprint_worktree_tracking | inferred_decision | A | <!-- tickets-boundary-ok -->
| ${CLAUDE_PLUGIN_ROOT}/skills/sprint/SKILL.md | 244–246 | "ticket-clarity-check.sh unavailable — falling through to Layer 2" | sprint_ticket_clarity_check | inferred_decision | B |
| ${CLAUDE_PLUGIN_ROOT}/skills/sprint/SKILL.md | 267 | "complexity-evaluator unavailable — falling through to Layer 3" | sprint_complexity_evaluator | inferred_decision | B |
| ${CLAUDE_PLUGIN_ROOT}/skills/sprint/SKILL.md | 350 | "0-SC epic: skipping SC coverage haiku gate — no SCs to validate" | sprint_sc_haiku_gate | unresolved_question | C |
| ${CLAUDE_PLUGIN_ROOT}/skills/sprint/SKILL.md | 373–375 | "SC coverage haiku gate: parse failure — skipping gate, proceeding to Phase B" | sprint_sc_haiku_parse | inferred_decision | C |
| ${CLAUDE_PLUGIN_ROOT}/skills/sprint/SKILL.md | 431 | "SC coverage sonnet gate: parse failure — treating all sonnet SCs as UNSURE" | sprint_sc_sonnet_parse | inferred_decision | C |
| ${CLAUDE_PLUGIN_ROOT}/skills/sprint/SKILL.md | 488 | "SC coverage opus gate: parse failure — treating all unparseable SCs as MISSING (conservative fail-open)" | sprint_sc_opus_parse | inferred_decision | C |
| ${CLAUDE_PLUGIN_ROOT}/skills/implementation-plan/SKILL.md | 66–74 | "rc=2 → lookup failure, treat as OK (fail-open)" | implementation_plan_tag_guard | inferred_decision | D |
| ${CLAUDE_PLUGIN_ROOT}/skills/implementation-plan/SKILL.md | 178–180 | "researchFindings parse failed on epic — treating as empty" | implementation_plan_research_findings | inferred_decision | D |
| ${CLAUDE_PLUGIN_ROOT}/skills/implementation-plan/SKILL.md | 857 | "Skipping gap analysis — story classified as TRIVIAL" | implementation_plan_gap_analysis | unresolved_question | D |
| ${CLAUDE_PLUGIN_ROOT}/skills/implementation-plan/SKILL.md | 914 | "Gap analysis failure is non-blocking — log warning and continue" | implementation_plan_gap_analysis_failure | inferred_decision | D |
| ${CLAUDE_PLUGIN_ROOT}/skills/brainstorm/SKILL.md | 225 | "On any failure (agent unavailable, MAX_AGENTS=0, timeout, malformed output): treat result as `non-ui`, and continue" | brainstorm_ui_detector | inferred_decision | E |
| ${CLAUDE_PLUGIN_ROOT}/skills/brainstorm/SKILL.md | 226 | "Non-interactive path: emit INTERACTIVITY_DEFERRED, tag epic `ui_probes:deferred`, and skip all probes" | brainstorm_ux_probes | unresolved_question | E |
| ${CLAUDE_PLUGIN_ROOT}/skills/brainstorm/SKILL.md | 279 | "If the function returns exit 1, skip this sub-step and proceed to Phase 2" | brainstorm_external_dep_block | inferred_decision | F |
| ${CLAUDE_PLUGIN_ROOT}/skills/preplanning/SKILL.md | 91 | "If ticket show fails, treat the tag as absent and proceed (fail-open)" (interaction:deferred check) | preplanning_interaction_deferred_tag | inferred_decision | G |
| ${CLAUDE_PLUGIN_ROOT}/skills/preplanning/SKILL.md | 105 | "If ticket show fails, treat the tag as absent and proceed (fail-open)" (ui_probes:deferred check) | preplanning_ui_probes_tag | inferred_decision | G |
| ${CLAUDE_PLUGIN_ROOT}/skills/preplanning/SKILL.md | 115–118 | "fail-open if script not found" (preconditions-validator.sh) | preplanning_preconditions_validator | inferred_decision | G |
| ${CLAUDE_PLUGIN_ROOT}/skills/preplanning/SKILL.md | 164 | "If the agent fails or returns malformed JSON, log a warning and fall through to full preplanning" | preplanning_complexity_evaluator | inferred_decision | G |
| ${CLAUDE_PLUGIN_ROOT}/skills/preplanning/SKILL.md | 391 | "No stories with external integration signals — skipping integration research" | preplanning_integration_research | unresolved_question | H |
| ${CLAUDE_PLUGIN_ROOT}/skills/preplanning/SKILL.md | 397 | "Adversarial review skipped: fewer than 3 stories" | preplanning_adversarial_review | unresolved_question | H |
| ${CLAUDE_PLUGIN_ROOT}/skills/preplanning/SKILL.md | 512 | "Story-level research skipped for <story-id>: WebSearch/WebFetch unavailable" | preplanning_story_research | inferred_decision | H |
| ${CLAUDE_PLUGIN_ROOT}/skills/preplanning/SKILL.md | 817 | "Treat a missing or corrupt RESEARCH_FINDINGS: comment as an empty array (fail-open)" | preplanning_research_findings_merge | inferred_decision | H |
| ${CLAUDE_PLUGIN_ROOT}/skills/fix-bug/SKILL.md | 14 | "On script failure, the gate defaults to non-blocking to prevent investigation blockage" (Feature-Request Gate) | fix_bug_feature_request_gate | inferred_decision | I |
| ${CLAUDE_PLUGIN_ROOT}/skills/fix-bug/SKILL.md | 377 | "If the intent-search agent dispatch fails, treat the result as ambiguous and fall through to Feature-Request Gate" | fix_bug_intent_search | inferred_decision | I |
| ${CLAUDE_PLUGIN_ROOT}/skills/fix-bug/SKILL.md | 427 | "If feature-request-check.py exits nonzero … treat the result as triggered: false and proceed to Phase C Step 1" | fix_bug_feature_request_check | inferred_decision | I |
| ${CLAUDE_PLUGIN_ROOT}/skills/fix-bug/SKILL.md | 854 | "All gates fail-open on error: nonzero exit, empty stdout, or JSON parse failure → construct fallback {triggered:false}" | fix_bug_post_fix_gates | inferred_decision | I |
| ${CLAUDE_PLUGIN_ROOT}/skills/debug-everything/SKILL.md | 35 | "If AWS auth is not configured, infrastructure checks are skipped gracefully" | debug_everything_aws_infra | inferred_decision | J |
| ${CLAUDE_PLUGIN_ROOT}/skills/debug-everything/SKILL.md | 113–118 | "`\|\| true` ensures we continue regardless of outcome" (validate.sh --ci) | debug_everything_validate_sh | inferred_decision | J |
| ${CLAUDE_PLUGIN_ROOT}/skills/debug-everything/SKILL.md | 772 | "`error` field present — log warning, proceed with commit (graceful degradation)" (semantic conflict check) | debug_everything_semantic_conflict | inferred_decision | J |
| ${CLAUDE_PLUGIN_ROOT}/skills/debug-everything/SKILL.md | 796 | "If collect-discoveries.sh fails, log a warning and proceed without discovery propagation (graceful degradation)" | debug_everything_discovery_propagation | inferred_decision | J |
| ${CLAUDE_PLUGIN_ROOT}/skills/commit/SKILL.md | — | file not found | commit_placeholder | inferred_decision | K |
| ${CLAUDE_PLUGIN_ROOT}/skills/review/SKILL.md | — | file not found | review_placeholder | inferred_decision | K |
| ${CLAUDE_PLUGIN_ROOT}/skills/end-session/SKILL.md | 48 | "`child_status: no_children` — skip silently" | end_session_child_status | unresolved_question | L |
| ${CLAUDE_PLUGIN_ROOT}/skills/end-session/SKILL.md | 64 | "If not found or belongs to another worktree: skip silently" | end_session_worktree_check | unresolved_question | L |
| ${CLAUDE_PLUGIN_ROOT}/skills/end-session/SKILL.md | 154 | "If no learnings qualify, skip silently" | end_session_learnings | unresolved_question | L |
| ${CLAUDE_PLUGIN_ROOT}/skills/end-session/SKILL.md | 178 | "if empty, skip this step (no visual config)" (baseline dir check) | end_session_visual_baseline | unresolved_question | L |
| ${CLAUDE_PLUGIN_ROOT}/skills/end-session/SKILL.md | 241 | "If fetch fails (no network), this elif is skipped — conservative fail-safe" | end_session_fetch | inferred_decision | L |
| ${CLAUDE_PLUGIN_ROOT}/skills/update-docs/SKILL.md | 57–61 | "No changes found in commit range … And stop — do not dispatch the agent" | update_docs_empty_diff | unresolved_question | M |
| ${CLAUDE_PLUGIN_ROOT}/skills/update-docs/SKILL.md | 142–144 | "If the agent failed or returned malformed output: Report the error and suggest narrowing the commit range" | update_docs_agent_failure | inferred_decision | M |
| ${CLAUDE_PLUGIN_ROOT}/skills/create-bug/SKILL.md | 66–72 | "CLI_user-tagged bugs skip the intent-search gate in /dso:fix-bug Phase B Step 1" | create_bug_cli_user_intent_skip | inferred_decision | N |

---

## Cluster Legend

| Cluster | Scope |
|---------|-------|
| A | Sprint entry-gate and worktree-tracking fail-silents |
| B | Sprint clarity and complexity routing fallthrough |
| C | Sprint SC coverage gate parse-failure fail-opens |
| D | Implementation-plan tag guard, research-findings, and gap analysis fallthrough |
| E | Brainstorm UI detector and UX probe deferral |
| F | Brainstorm external-dependency-block config gate |
| G | Preplanning tag checks, preconditions validator, and complexity evaluator fail-open |
| H | Preplanning integration research, adversarial review, and research-findings merge |
| I | Fix-bug intent gate and feature-request gate graceful degradation |
| J | Debug-everything infrastructure and tooling fail-open |
| K | Commit and Review skills (files not found — placeholder rows) |
| L | End-session silently-skipped checks and fail-safes |
| M | Update-docs empty-diff stop and agent failure degradation |
| N | Create-bug CLI_user intent-search skip |
