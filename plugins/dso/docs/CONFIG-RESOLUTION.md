# Config Resolution

Skills load project commands via `read-config.sh` before executing any steps.

## Resolution Order

1. `workflow-config.conf` at `${CLAUDE_PLUGIN_ROOT}/workflow-config.conf` (plugin-level override)
2. `workflow-config.conf` at `$(pwd)/workflow-config.conf` (project root — most common)
3. Make target fallback: if config is absent or key is empty, fall back to `make <target>` convention (e.g., `make test`, `make lint`)
4. Skip with warning if neither config nor make target found

**Format**: Flat `KEY=VALUE` file with dot-notation for nesting and repeated keys for lists. Parsed by `grep`/`cut` in bash — no Python dependency required. See `${CLAUDE_PLUGIN_ROOT}/docs/dso-config.example.conf` for a complete example.

**Legacy fallback**: If `workflow-config.conf` is not found but `workflow-config.yaml` exists at the same location, `read-config.sh` falls back to the YAML file (requires Python with PyYAML). This fallback exists for migration compatibility and will be removed in a future version.

## Usage Pattern

Each skill declares which commands it needs:

```bash
PLUGIN_SCRIPTS="${CLAUDE_PLUGIN_ROOT}/scripts"
TEST_CMD=$(bash "$PLUGIN_SCRIPTS/read-config.sh" commands.test)
LINT_CMD=$(bash "$PLUGIN_SCRIPTS/read-config.sh" commands.lint)
# ... additional commands as needed per skill
```

Then references `$TEST_CMD`, `$LINT_CMD`, etc. throughout its steps instead of hardcoded `make` targets.
