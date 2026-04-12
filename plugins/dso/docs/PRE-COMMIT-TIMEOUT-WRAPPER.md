# Pre-Commit Timeout Wrapper

Generic pre-commit hook wrapper that runs a command with timeout detection, logging, and optional auto-ticket creation. Lives at `scripts/pre-commit-wrapper.sh`. # shim-exempt: internal implementation path reference

## Interface

```
pre-commit-wrapper.sh <hook_name> <timeout_secs> <command_string>
```

| Argument | Description |
|----------|-------------|
| `hook_name` | Descriptive name for the hook (used in logs and ticket titles) |
| `timeout_secs` | Threshold in seconds; if the command takes longer, it is logged as slow |
| `command_string` | The full command to run via `bash -c` |

## Config Keys

The wrapper reads one key from `dso-config.conf` via `read-config.sh`:

| Key | Purpose | Default |
|-----|---------|---------|
| `session.artifact_prefix` | Prefix for `/tmp` artifact directories | `<repo-basename>-test-artifacts` |

Example config:

```conf
session.artifact_prefix=myproject-test-artifacts
```

## Timeout Detection

The wrapper detects timeouts in two ways:

1. **Slow completion** -- command finishes but takes longer than `timeout_secs`. Logs a `SLOW` entry.
2. **Signal kill** -- command is killed (exit codes 124, 137, 143). Logs a `KILLED` entry and exits with code 124.

## Exit Codes

The wrapper passes through the underlying command's exit code, with special handling for signal-related exits:

| Code | Meaning |
|------|---------|
| 124 | Timeout (command killed by `timeout`) |
| 137 | SIGKILL (128 + 9) |
| 143 | SIGTERM (128 + 15) |

## Log File Location

Timeout events are logged to:

```
/tmp/<artifact_prefix>-<worktree_name>/precommit-timeouts.log
```

Where:
- `<artifact_prefix>` comes from `session.artifact_prefix` (or defaults to `<repo-basename>-test-artifacts`)
- `<worktree_name>` is the basename of the git working tree root

Log format:

```
<timestamp> | SLOW | <hook_name> | <duration>s (limit: <timeout>s) | command: <command_string>
<timestamp> | KILLED | <hook_name> | timeout at <timeout>s | command: <command_string>
```

## Example `.pre-commit-config.yaml` Entries

Wire the wrapper into any project's `.pre-commit-config.yaml` using `system` hooks:

```yaml
repos:
  - repo: local
    hooks:
      - id: format-check
        name: Format check (with timeout)
        entry: scripts/pre-commit-wrapper.sh format-check 30 "ruff check src/"
        language: system
        pass_filenames: false
        always_run: true

      - id: lint-mypy
        name: MyPy type check (with timeout)
        entry: scripts/pre-commit-wrapper.sh lint-mypy 60 "make lint-mypy"
        language: system
        pass_filenames: false
        always_run: true

      - id: unit-tests
        name: Unit tests (with timeout)
        entry: scripts/pre-commit-wrapper.sh unit-tests 120 "make test-unit-only"
        language: system
        pass_filenames: false
        stages: [pre-push]
```

Note: The `entry` path points to the project-level exec wrapper at `scripts/pre-commit-wrapper.sh`, not the plugin script directly.

## Project-Level Exec Wrapper

Projects should create a thin exec wrapper at `scripts/pre-commit-wrapper.sh` that delegates to the plugin:

```bash
#!/usr/bin/env bash
# Thin exec wrapper -- canonical copy lives in ${CLAUDE_PLUGIN_ROOT}/scripts/pre-commit-wrapper.sh # shim-exempt: internal implementation path in comment
exec "${CLAUDE_PLUGIN_ROOT}/scripts/pre-commit-wrapper.sh" "$@" # shim-exempt: bootstrap exec wrapper template, delegates to plugin canonical path
```

This pattern keeps the canonical implementation in the plugin while allowing `.pre-commit-config.yaml` to reference a stable project-local path. See `SCRIPT-MIGRATION-PATTERNS.md` for the general exec wrapper pattern used across all migrated plugin scripts.
