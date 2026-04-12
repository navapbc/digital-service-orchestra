# Test Status Convention

The test-failure commit guard (`hook_test_failure_guard`) blocks commits when test targets have failed in the current worktree session. This document describes the file convention that the guard reads.

## File Path Pattern

```
$ARTIFACTS_DIR/test-status/<target>.status
```

`$ARTIFACTS_DIR` is resolved by `get_artifacts_dir()` in `${CLAUDE_PLUGIN_ROOT}/hooks/lib/deps.sh` — a hash-based temp directory scoped to the repo root (e.g., `/tmp/workflow-plugin-<hash>/`).

## File Content Format

The first line of each `.status` file must be exactly one of:

| Value | Meaning |
|-------|---------|
| `PASSED` | Target succeeded — commit allowed |
| `FAILED` | Target failed — commit blocked |

Any other content (empty file, `ERROR`, partial strings) is silently allowed — the guard only blocks on exact `FAILED`.

## How It Works

1. Makefile test targets run the test suite
2. After completion (pass or fail), they call `write-test-status.sh <target> <exit-code>`
3. The script writes `PASSED` (exit 0) or `FAILED` (non-zero) to the status file
4. At commit time, `hook_test_failure_guard` scans all `*.status` files
5. If any file's first line is `FAILED`, the commit is blocked

## Exemptions

The guard does not fire on:
- Non-commit commands (only `git commit` is checked)
- WIP commits (`git commit -m "WIP: ..."`)
- Merge commits (`git merge ...`)

When no `.status` files exist (tests never run in this session), commits are allowed — CI catches regressions.

## Make-Based Project Example

Wire your Makefile test targets using `write-test-status.sh`:

```makefile
test-unit: ## Run unit tests
	@_exit=0; cd app && poetry run pytest tests/unit/ || _exit=$$?; \
	bash .claude/scripts/dso write-test-status.sh test-unit $$_exit 2>/dev/null || true; \
	exit $$_exit

test-e2e: ## Run end-to-end tests
	@_exit=0; cd app && poetry run pytest tests/e2e/ || _exit=$$?; \
	bash .claude/scripts/dso write-test-status.sh test-e2e $$_exit 2>/dev/null || true; \
	exit $$_exit
```

The pattern captures the exit code, writes the status, then re-exits with the original code so `make` still reports the correct failure.

## Script Reference

**Canonical**: `scripts/write-test-status.sh` # shim-exempt: canonical source path reference, not an invocation
**Wrapper**: `.claude/scripts/dso write-test-status.sh` (backward-compatible exec wrapper)

```
Usage: write-test-status.sh <target-name> <exit-code>
```
