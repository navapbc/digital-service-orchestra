# Config System: workflow-config.yaml and Stack Auto-Detection

- Status: accepted
- Deciders: @joeoakhart
- Date: 2026-02-28

Technical Story: lockpick-doc-to-logic-j46vp.2 (Phase 2: Config system and auto-inference)

## Context and Problem Statement

The lockpick-workflow plugin orchestrates dev workflow commands — test, lint, format, validate — across consuming projects. The original source repo hardcodes `make test`, `make lint`, `make format-check`, etc. directly in skill definitions and hook scripts. This works for Python/Make stacks but breaks immediately when the plugin is installed in a Rust, Go, or Node project where commands differ significantly (e.g., `cargo test`, `go test ./...`, `npm test`).

The plugin needs a way for consuming projects to declare their stack-specific commands once, centrally, and have all skills and hooks read those commands at activation time rather than embedding stack-specific strings in every skill definition.

Two sub-problems:
1. **Config declaration**: How does a consuming project specify its commands?
2. **Stack inference**: When a project does not explicitly declare its stack, how does the plugin determine sensible defaults?

## Decision Drivers

- Commands must be configurable without modifying plugin-owned files (skills, hooks).
- Config must be version-controllable and visible to both humans and agents inspecting the project.
- Config must be readable from any hook or skill at activation time with minimal boilerplate.
- YAML parsing must not introduce a new runtime dependency that consuming projects must install.
- Stack inference must be deterministic and predictable when multiple marker files coexist.
- The fallback behavior when no config is present must be safe: skills degrade gracefully rather than crashing.
- Ambiguous multi-stack situations where commands would differ must surface to the user rather than silently use wrong commands.

## Considered Options

- **Approach A**: `workflow-config.yaml` config file + stack auto-detection via `detect-stack.sh`
- **Approach B**: Environment variables (e.g., `LOCKPICK_TEST_CMD`, `LOCKPICK_LINT_CMD`) set in shell profile or `.claude/settings.json`
- **Approach C**: CLAUDE.md injection — embed command overrides in the consuming project's `CLAUDE.md`

## Decision Outcome

Chosen option: **Approach A — `workflow-config.yaml` config file + `detect-stack.sh`**, because it is the only option that satisfies all decision drivers simultaneously.

### Config File: `workflow-config.yaml`

Consuming projects place `workflow-config.yaml` in their project root (or `${CLAUDE_PLUGIN_ROOT}` directory). The file follows the schema at `lockpick-workflow/docs/workflow-config-schema.json`.

Minimal example:
```yaml
version: 1.0.0
commands:
  test: cargo test
  lint: cargo clippy
  format: cargo fmt
  format_check: cargo fmt --check
```

Optional `stack` field overrides auto-detection:
```yaml
version: 1.0.0
stack: rust-cargo
commands:
  test: cargo test
```

### Script: `read-config.sh`

All skills and hooks read config via `lockpick-workflow/scripts/read-config.sh`. The script accepts a dot-notation key (e.g., `commands.test`) and returns the value to stdout. Empty output means the key is absent and the caller should apply its fallback.

**Resolution order** (implemented in `read-config.sh`):
1. `${CLAUDE_PLUGIN_ROOT}/workflow-config.yaml` — explicit plugin-root config
2. `$(pwd)/workflow-config.yaml` — project-root config
3. If neither exists: output empty string and exit 0 (graceful skip)

Within a skill, the resolution order for a command is:
1. Explicit value in `workflow-config.yaml` under `commands.<key>`
2. Make-target convention fallback (e.g., `make test` if `test:` target exists in Makefile)
3. Skip with a warning logged to stderr

**YAML parser choice**: `read-config.sh` uses the **python3 built-in `yaml` module (PyYAML)** via an embedded Python heredoc. This avoids a dependency on `yq`, which is not universally installed and requires a separate install step on most systems. Python 3 with PyYAML is available in all target environments (the plugin already requires Python 3 for other scripts). The script probes `app/.venv/bin/python3`, `.venv/bin/python3`, and system `python3` in order, accepting the first that can `import yaml`.

### Script: `detect-stack.sh`

When `stack` is not declared in `workflow-config.yaml`, `detect-stack.sh` infers it from marker files in the project directory.

**Multi-marker priority** (first match wins):
1. `python-poetry` — `pyproject.toml` present (takes priority over `package.json` because many Python projects include frontend tooling)
2. `rust-cargo` — `Cargo.toml` present
3. `golang` — `go.mod` present
4. `node-npm` — `package.json` present
5. `convention-based` — `Makefile` with at least 2 of `test:`, `lint:`, `format:` targets
6. `unknown` — no recognized markers found

**Escalation policy**: If the detected stack is `unknown` AND the skill needs a command that has no fallback, the skill surfaces the ambiguity to the user with an actionable message: "Stack could not be detected. Add `stack:` to `workflow-config.yaml` or create a Makefile with `test:`, `lint:`, `format:` targets."

### Positive Consequences

- A consuming project configures commands once in `workflow-config.yaml`; all skills pick them up automatically.
- The config file is checked into the consuming project's repository, making command choices visible in code review and auditable.
- `detect-stack.sh` gives zero-config experience for standard stacks (python-poetry, rust-cargo, golang, node-npm, convention-based/Make).
- No new runtime dependencies for consuming projects that already have Python 3 with PyYAML.
- Graceful degradation: missing config or missing key produces empty output, not an error; skills fall back to convention or skip.
- The schema file (`workflow-config-schema.json`) enables editor validation and serves as living documentation.

### Negative Consequences

- Consuming projects must create and maintain `workflow-config.yaml` if they deviate from stack defaults.
- The python3 probe adds a small startup cost on first invocation of `read-config.sh` in a session (mitigated by caching the resolved python path in a session-scoped env var if needed in future).
- Stack auto-detection has deterministic priority but cannot handle genuinely hybrid stacks (e.g., a Rust project that uses Node for frontend tests). These cases require explicit `workflow-config.yaml` config.

## Pros and Cons of the Options

### Approach A: workflow-config.yaml + detect-stack.sh

- Good, because the config is version-controllable and diff-able in PRs.
- Good, because it is visible to both human reviewers and agent context.
- Good, because `detect-stack.sh` gives zero-config for common stacks.
- Good, because python3 yaml is available everywhere without new dependencies.
- Good, because the resolution order (explicit → make fallback → skip) is predictable and documented.
- Bad, because consuming projects with non-standard command layouts must maintain a config file.

### Approach B: Environment variables

- Good, because no config file to maintain.
- Bad, because env vars are ephemeral — they are lost when a new shell session starts.
- Bad, because they must be re-exported in `.claude/settings.json`, shell profile, and CI separately.
- Bad, because they are invisible to agents reading the codebase context.
- Bad, because there is no schema validation; typos in variable names silently produce empty values.

### Approach C: CLAUDE.md injection

- Good, because the agent always reads CLAUDE.md at session start.
- Bad, because it couples plugin configuration to the consuming project's CLAUDE.md structure.
- Bad, because CLAUDE.md is a prose document, not a structured config format; parsing is fragile.
- Bad, because updating plugin config schema would require updating CLAUDE.md injection conventions in every consuming project.
- Bad, because it mixes project-level instructions with plugin-level parameterization.

## Amendment: Format Change from YAML to Flat KEY=VALUE (2026-03-14)

**Change**: The config file format has been migrated from `workflow-config.yaml` (YAML) to `dso-config.conf` (flat KEY=VALUE with dot-notation), placed at `.claude/dso-config.conf`. The original decision to use YAML (Approach A) remains valid in its reasoning about centralized config vs env vars vs CLAUDE.md injection. This amendment only changes the serialization format.

**Rationale**: YAML required a Python subprocess (~100ms) to parse from bash. A caching layer was added to mitigate this, but added complexity (cache generation, mtime validation, self-healing fallback). The flat format eliminates both the Python dependency and the caching layer, reducing `read-config.sh` from ~300 lines to ~15 lines of grep/cut. See `lockpick-workflow/docs/FLAT-CONFIG-MIGRATION.md` for the full tradeoff analysis.

**What changed**:
- Config file: `workflow-config.yaml` replaced by `.claude/dso-config.conf`
- Parser: Python/PyYAML replaced by grep/cut (bash-native)
- Cache infrastructure: removed (no longer needed)
- `read-config.sh` API: unchanged (same dot-notation keys, same `--list` flag)
- Resolution order: `.conf` preferred, `.yaml` fallback retained for migration

**What did NOT change**:
- The decision to use a config file (vs env vars or CLAUDE.md injection)
- The `read-config.sh` public API (callers are unaffected)
- The `detect-stack.sh` auto-detection mechanism
- The schema (logical key structure and types documented in `workflow-config-schema.json`)

## Links

- Builds on [adr-plugin-scaffold.md] (`${CLAUDE_PLUGIN_ROOT}` path resolution convention)
- Schema: `lockpick-workflow/docs/workflow-config-schema.json`
- Example config: `lockpick-workflow/docs/dso-config.example.conf`
- Enables Phase 3: hook parameterization (hooks read `commands.*` from `dso-config.conf`)
