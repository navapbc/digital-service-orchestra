# Design Notes

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
