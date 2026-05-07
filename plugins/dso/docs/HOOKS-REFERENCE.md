# Hooks & Gates Reference

Self-enforcing pre-commit hooks, the test/review gates, the hook error handler, and the stack-agnostic gate pipeline. CLAUDE.md no longer enumerates these — agents learn the rules at error time. This file is the reference for plugin authors and for debugging hook failures.

## Pre-commit hooks (self-enforcing)

Each hook prints its own error and fix instructions. Suppression annotations are inline comments in the offending file.

| Hook | Purpose | Suppression |
|------|---------|-------------|
| `check-portability.sh` | Hardcoded paths in scripts | `# portability-ok` |
| `check-shim-refs.sh` | Direct plugin script refs in host-project files; use `.claude/scripts/dso <script-name>` shim instead | `# shim-exempt: <reason>` |
| `check-contract-schemas.sh` | Contract markdown structure | (none) |
| `check-referential-integrity.sh` | Dead path references in instruction files | (none) |
| `check-plugin-self-ref.sh` | Blocks literal plugin-root paths in plugin scripts; use `_PLUGIN_ROOT` / `_PLUGIN_GIT_PATH` | (no annotation — absolute) |
| `pre-commit-enforcement-boundary-check.sh` | Enforces that enforcement hooks do not source the hook-error-handler library | (none) |

## Review gate (two-layer)

- **Layer 1** — `pre-commit-review-gate.sh` (git hook) enforces `review-gate-allowlist.conf` allowlist + `review-status` + diff hash.
- **Layer 2** — `review-gate.sh` (PreToolUse hook) blocks `--no-verify`, `core.hooksPath=` overrides, and git plumbing bypasses.

Both layers handle MERGE_HEAD and REBASE_HEAD via `merge-state.sh`. `--no-verify` cannot bypass Layer 2 — it is a Claude Code tool-use hook, not a git hook.

**Exception**: when `enforcement.strategy=ci`, both layers emit `HOOK_GATE: skipped reason=enforcement.strategy=ci` and skip enforcement; CI enforces via the parity-uplifted llm-review job.

## Test gate

`pre-commit-test-gate.sh` verifies test status per staged file.

- Centrality-aware (`record-test-status.sh`): high fan-in files trigger full suite.
- Use `--restart` to clear stale status when stuck on a previous failed recording.
- Config: `test_gate.*` in `dso-config.conf`.
- `.test-index` maps source → tests.
- **RED marker format**: `tests/foo.sh [test_name]` (space before bracket required) tolerates intentionally failing RED tests at/after that boundary.

**Status values**: `passed`, `failed`, `timeout`, `resource_exhaustion` (distinct from `failed`; written by `record-test-status.sh` when exit 254 + EAGAIN stderr pattern is detected).

**Severity hierarchy**: `timeout > failed > resource_exhaustion > passed`.

## Test quality gate

`pre-commit-test-quality-gate.sh` detects anti-patterns in staged test files: source-file-grepping, tautological tests, change-detector tests, implementation-coupled assertions, existence-only assertions.

- Scoped to files matching `^tests/`.
- Config: `test_quality.enabled` (default `true`); `test_quality.tool` (`bash-grep` | `semgrep` | `disabled`, default `bash-grep`).
- When `semgrep` is selected, uses rules at `${CLAUDE_PLUGIN_ROOT}/hooks/semgrep-rules/test-anti-patterns.yaml`.
- Timeout budget: 15 seconds.

## Hook error handler

`${CLAUDE_PLUGIN_ROOT}/hooks/lib/hook-error-handler.sh` — shared ERR/EXIT trap library for **non-enforcement** hooks. Source with a fail-open guard, then call `_dso_register_hook_err_handler "hook-name.sh"`. Errors logged to `~/.claude/logs/dso-hook-errors.jsonl` (handler always exits 0, never blocks hook execution).

Enforcement hooks (annotated `# hook-boundary: enforcement`) MUST NOT source this library — `pre-commit-enforcement-boundary-check.sh` enforces this boundary at commit time.

## Stack-agnostic gate pipeline

`validate.sh`, `gate-2b`, `gate-2d`, and `auto-format.sh` read `commands.lint`, `commands.format`, and `commands.format_check` from config — replacing hardcoded Python/ruff calls. When a key is absent, each script emits `[DSO WARN]` and falls back gracefully (ruff for `.py`; skip for other extensions). Per-stack defaults: see `CONFIGURATION-REFERENCE.md`.

## GitHub CI Ruleset enforcement

`.github/required-checks.txt` lists required GitHub check-context names (must match workflow `name:` fields exactly). Provisioned during `/dso:onboarding` via `github-bootstrap.sh` (fail-open — never blocks setup). After editing workflow job names, run `bash ${CLAUDE_PLUGIN_ROOT}/scripts/onboarding/validate-required-checks.sh` to catch alignment drift before pushing.
