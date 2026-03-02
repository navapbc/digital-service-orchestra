# Config Resolution

Skills load project commands via `read-config.sh` before executing any steps.

## Resolution Order

1. `workflow-config.yaml` at `${CLAUDE_PLUGIN_ROOT}/workflow-config.yaml` (plugin-level override)
2. `workflow-config.yaml` at `$(pwd)/workflow-config.yaml` (project root — most common)
3. Make target fallback: if config is absent or key is empty, fall back to `make <target>` convention (e.g., `make test`, `make lint`)
4. Skip with warning if neither config nor make target found

## Usage Pattern

Each skill declares which commands it needs:

```bash
PLUGIN_SCRIPTS="${CLAUDE_PLUGIN_ROOT:-$(git rev-parse --show-toplevel)/lockpick-workflow}/scripts"
TEST_CMD=$(bash "$PLUGIN_SCRIPTS/read-config.sh" commands.test)
LINT_CMD=$(bash "$PLUGIN_SCRIPTS/read-config.sh" commands.lint)
# ... additional commands as needed per skill
```

Then references `$TEST_CMD`, `$LINT_CMD`, etc. throughout its steps instead of hardcoded `make` targets.
