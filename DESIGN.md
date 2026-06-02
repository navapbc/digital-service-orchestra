---
name: Design Notes
---

## ADR-001: Deterministic Transform Recipe Registry and Execution Engine

### Status
Accepted

### Context
DSO plugin users need to run deterministic code transforms (add-parameter, scaffold-route, normalize-imports) across Python, TypeScript, and Ruby projects. Transform operations must be consistent across invocations and safe to retry.

### Decision
**Registry schema**: `recipes/recipe-registry.yaml` declares available recipes; validated at load time against `recipes/schemas/recipe-registry-schema.json` (JSON Schema Draft 7). Validation is fail-fast — malformed registry prevents any recipe from running.

**Adapter pattern**: Each engine (rope, ts-morph, isort, scaffold) has a dedicated adapter script in `plugins/dso/scripts/recipe-adapters/`. Adapters conform to the contract in `plugins/dso/docs/contracts/recipe-engine-adapter.md`: accept params via RECIPE_PARAM_* env vars, emit JSON to stdout (fields: files_changed, transforms_applied, errors, exit_code, degraded, engine_name), exit 0 (success), 1 (error), or 2 (degraded).

**RECIPE_PARAM_* env var protocol**: All recipe parameters are passed via environment variables (e.g., RECIPE_PARAM_function_name=add_item), never shell string interpolation. This eliminates shell injection at the API boundary.

**Rollback protocol**: Transform recipes (default) use git stash rollback on failure — any partial changes are discarded. Generative recipes (recipe_type: generative in registry) track created files and delete them on failure rather than stashing.

**recipe_type field**: Optional enum in registry schema (transform | generative). Absent = transform. Introduced to support scaffold-route (Flask, NextJS) which creates new files rather than modifying existing ones.

### Consequences
- Adding a new engine requires: (1) adapter script in `recipe-adapters/`, (2) registry entry, (3) conformance tests in `tests/scripts/test-<engine>-adapter.sh`
- RECIPE_PARAM_* protocol requires callers to translate flags (--param key=value) to env var form before invoking adapters
- Integration test fixtures live in `tests/integration/fixtures/` — synthetic Python + TypeScript projects that must remain stable for tests to be deterministic
## ADR-002: Recipe Integration into Sprint Execution Pipeline

### Status
Accepted

### Context
Recipe tasks (planned by `/dso:implementation-plan` with `recipe:` task type) need to integrate with the sprint execution pipeline without disrupting the existing sub-agent dispatch flow.

### Decision
**Pre-flight engine check** (Phase C Step 1): Sprint scans all recipe: tasks for referenced engines before any task executes. Missing or outdated engines populate `MISSING_ENGINES_LIST`. Pre-flight is a no-op when the plan has no recipe: tasks and does not block epics with zero recipe tasks.

**Cleanup phase** (Phase F, post-sub-agent): Applicable cleanup recipes (e.g., normalize-imports) run after each sub-agent returns and before code review. This catches mechanical defects deterministically before the reviewer sees the diff. Sprint log records the post-cleanup state.

**LLM fallback** (graceful degradation): When an engine from `MISSING_ENGINES_LIST` is needed, `translate-recipe-to-llm-task.sh` converts the recipe task spec to a natural-language LLM sub-agent task. The intent comes from `capability_description` in the registry. A ticket comment (`RECIPE_FALLBACK:`) records the fallback with engine name and reason. The fallback task routes through the identical Phase F pipeline as any GREEN task.

### Consequences
- `translate-recipe-to-llm-task.sh` is the authoritative conversion layer; callers inject `RECIPE_REGISTRY_PATH` for test isolation
- Pre-flight version check uses the registry's `minimum_version` field, not just engine presence
- Cleanup recipes that produce no-op diffs (already clean) are skipped silently
## Follow-on Observability: Story-Branch Leakage Metrics

After the per-story PR pipeline (epic f61f-7e0a-36d3-4e7d) is fully deployed, instrument story-branch leakage: track how often `check-session-merge-only.sh` fires (session-worktree direct commit attempts), how often `check-sprint-trailer.sh` rejects a merge (missing `DSO-Story:` trailer), and whether story branches are created outside Phase E (branch naming violations). These signals indicate orchestrator discipline gaps and should feed back into sprint SKILL.md guidance.
