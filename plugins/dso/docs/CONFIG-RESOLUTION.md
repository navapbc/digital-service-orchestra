# Config Resolution

Skills load project commands via `read-config.sh` before executing any steps.

## Resolution Order

`read-config.sh` resolves the config file in the following order when no explicit path is provided:

1. **`WORKFLOW_CONFIG_FILE` env var** (highest priority) — if set, the exact file path it points to is used. Intended for test isolation; overrides all other resolution.
2. **`git rev-parse --show-toplevel`** canonical path — resolves to `<git-root>/.claude/dso-config.conf` if that file exists. This is the standard location for host-project config.
3. **Graceful degradation** — if neither of the above yields a valid file, `read-config.sh` exits 0 with empty output (no error).

> **Note**: Resolution via `CLAUDE_PLUGIN_ROOT` was removed in a prior refactor, because that variable points to the plugin directory rather than the host project's git root.
> Host projects always place their config at `.claude/dso-config.conf` inside their own repository root, which `read-config.sh` discovers via `git rev-parse --show-toplevel`.

**Format**: Flat `KEY=VALUE` file with dot-notation for nesting and repeated keys for lists. Parsed by `grep`/`cut` in bash — no Python dependency required. YAML format (`.yaml`/`.yml`) is also supported and parsed with a pure-Python reader.

## Usage Pattern

Each skill declares which commands it needs:

```bash
TEST_CMD=$(.claude/scripts/dso read-config.sh commands.test)
LINT_CMD=$(.claude/scripts/dso read-config.sh commands.lint)
# ... additional commands as needed per skill
```

Then references `$TEST_CMD`, `$LINT_CMD`, etc. throughout its steps instead of hardcoded `make` targets.
