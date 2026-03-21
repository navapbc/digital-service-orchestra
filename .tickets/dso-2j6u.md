---
id: dso-2j6u
status: in_progress
deps: []
links: []
created: 2026-03-21T18:33:23Z
type: epic
priority: 2
assignee: Joe Oakhart
---
# Extract complexity evaluator and conflict analyzer into dedicated plugin agents


## Notes

<!-- note-id: okiam9x7 -->
<!-- timestamp: 2026-03-21T18:33:40Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->


## Context

DSO practitioners experience classification delays when complexity evaluator sub-agents return malformed JSON — missing the classification field, using wrong field names, or returning prose instead of structured output. These failures force re-dispatch cycles that delay the planning and fix workflows gated on the classification result. Today, classification logic is loaded into generic general-purpose agents via the task prompt (a per-invocation instruction that competes for model attention with other context). Promoting classification logic to dedicated agent definitions — where it becomes the agent's system prompt and core identity — improves output format compliance. The complexity evaluator serves 4 skills; the conflict analyzer serves 1. Each is a single agent with no tier variants, created as a standalone .md file in plugins/dso/agents/ with YAML frontmatter (name, model, tools) and a markdown body containing the classification procedure and output schema.

## Success Criteria

1. Practitioners invoking /dso:brainstorm, /dso:sprint, or /dso:fix-bug receive complexity classifications from dso:complexity-evaluator (haiku) with output conforming to the existing rubric schema (required fields: classification in {TRIVIAL, MODERATE, COMPLEX}, confidence, scope_certainty, files_estimated, layers_touched, interfaces_affected, reasoning)
2. Practitioners invoking /dso:resolve-conflicts receive conflict classifications from dso:conflict-analyzer (sonnet) with per-file output containing: file path, classification in {TRIVIAL, SEMANTIC, AMBIGUOUS}, proposed resolution, explanation, and confidence
3. Each caller's context-specific routing logic (e.g., sprint escalates MODERATE to COMPLEX, debug-everything downgrades MODERATE to TRIVIAL) remains in the calling skill — only the classification itself moves to the agent definition
4. After deployment, invoke each of the 4 complexity evaluator callers and the conflict analyzer caller at least once using realistic inputs (not stubs). Record whether the agent response is valid JSON matching the schema in criteria 1 and 2 respectively. Record results in the epic notes. Epic passes when all 5 callers produce schema-valid output on first attempt

## Approach

Create two agent definitions in plugins/dso/agents/ — one for each sub-agent. The shared rubric / inline prompt becomes the agent's system prompt (tier 1). Callers are updated to dispatch via named subagent_type instead of general-purpose with prompt loading. Context-specific routing stays in the callers.

## Dependencies

None. Independent of dso-9ltc — both use the standard Claude Code agent definition format (.md file with YAML frontmatter in plugins/dso/agents/) but share no infrastructure or sequencing. Resolves descriptive naming for these two agents; a carve-out note will be added to dso-s12s to exclude them from that epic's scope.


<!-- note-id: rsl0cchq -->
<!-- timestamp: 2026-03-21T18:35:49Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->


## Done Definitions

- When this epic is complete, plugins/dso/agents/complexity-evaluator.md exists with YAML frontmatter (name: complexity-evaluator, model: haiku, tools: Bash, Read, Glob, Grep) and a markdown body containing the 5-dimension rubric, classification rules, output schema, and promotion rules — but NOT context-specific routing tables
  <- Satisfies: SC1 (complexity evaluator agent)
- When this epic is complete, plugins/dso/agents/conflict-analyzer.md exists with YAML frontmatter (name: conflict-analyzer, model: sonnet, tools: Bash, Read, Glob, Grep) and a markdown body containing conflict classification criteria (TRIVIAL/SEMANTIC/AMBIGUOUS), per-file output format, and confidence scoring
  <- Satisfies: SC2 (conflict analyzer agent)
- When this epic is complete, /dso:brainstorm, /dso:sprint (epic + story evaluation), /dso:fix-bug, and /dso:debug-everything dispatch complexity classification via subagent_type: dso:complexity-evaluator instead of loading the shared rubric into a general-purpose task prompt
  <- Satisfies: SC1 and SC3 (named agent dispatch + routing stays in callers)
- When this epic is complete, /dso:resolve-conflicts dispatches conflict analysis via subagent_type: dso:conflict-analyzer instead of embedding the prompt inline in SKILL.md
  <- Satisfies: SC2 (conflict analyzer dispatch)
- When this epic is complete, context-specific routing logic (sprint MODERATE->COMPLEX, debug-everything MODERATE->TRIVIAL, brainstorm routing table, fix-bug escalation) remains in each calling skill file, NOT in the agent definition
  <- Satisfies: SC3 (routing stays in callers)
- When this epic is complete, each of the 5 callers has been invoked with realistic input and produced schema-valid JSON output on first attempt, recorded in epic notes
  <- Satisfies: SC4 (validation signal)
- Unit tests written and passing for all new or modified logic

## Scope

- IN: Two agent definition files, updates to 5-6 caller skills, removal of context-specific routing from agent definition, validation smoke test
- OUT: Build script (not needed — single agents, not tiered variants), review agent extraction (dso-9ltc), agent routing config changes (agents are dispatched directly by subagent_type)

## Considerations

- [Testing] Caller skill files need updated dispatch logic verified — ensure each skill's dispatch section correctly references the named agent and passes per-invocation context only
- [Reliability] If the named agent fails to load (missing file, plugin not registered), callers should have documented fallback behavior (e.g., fall back to general-purpose with prompt loading)
- [Maintainability] The shared rubric (skills/shared/prompts/complexity-evaluator.md) contains context-specific routing tables (lines 112-124) that must NOT be copied into the agent definition — they belong in each caller. Verify routing tables exist in each caller after extraction


**2026-03-21T22:53:39Z**

VALIDATION_RESULTS: SC4 smoke test complete.
1. Sprint epic evaluator (dso:complexity-evaluator): pass — agent def has SIMPLE tier schema, output schema valid (classification, confidence, files_estimated, layers_touched, interfaces_affected, scope_certainty, reasoning all present)
2. Sprint story evaluator (dso:complexity-evaluator): pass — agent def has TRIVIAL tier schema, output schema valid; sprint/SKILL.md Step 1 dispatches via subagent_type with tier_schema=TRIVIAL
3. Brainstorm (dso:complexity-evaluator): pass — brainstorm/SKILL.md Step 4a dispatches via subagent_type, agent def schema valid
4. Fix-bug (dso:complexity-evaluator): pass — fix-bug/SKILL.md Step 4.5 reads agent def inline from plugins/dso/agents/complexity-evaluator.md, schema valid
5. Resolve-conflicts (dso:conflict-analyzer): pass — resolve-conflicts/SKILL.md Step 2 dispatches via subagent_type, per-file output schema valid (FILE, CLASSIFICATION, PROPOSED_RESOLUTION, EXPLANATION, CONFIDENCE all present)
Test file: tests/skills/test_agent_dispatch_validation.py — 25 tests, 25 passed, 0 failed
