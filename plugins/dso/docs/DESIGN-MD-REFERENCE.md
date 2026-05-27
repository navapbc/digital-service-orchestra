# DESIGN-MD Reference

Reference documentation for `@google/design.md` CLI usage in DSO workflows.

## Pinned CLI Version

**Pinned version: `0.2.0`**

The version is pinned in `design-lint.sh` and `design-md-lint.sh` as the environment variable default:

```bash
DESIGN_MD_VERSION="${DESIGN_MD_VERSION:-0.2.0}"
```

Override for testing:
```bash
DESIGN_MD_VERSION=0.3.0 dso design-lint --report
```

The pinned version was validated in the spike at `${CLAUDE_PLUGIN_ROOT}/docs/spikes/design-md-cli-validation.md`. Version `0.2.0` is the latest stable release as of the spike date (2026-05-26) and runs successfully under Node.js v20 with non-fatal engine warnings.

## Audit Command Usage

The `design-lint` command runs a full-file lint against the project's DESIGN.md. This is distinct from the diff-scoped `design-md-lint.sh` pre-commit hook.

```bash
# Emit per-violation-class counts to stdout
dso design-lint --report

# Passthrough to underlying linter (raw JSON output)
dso design-lint

# Usage information
dso design-lint --help
```

### `--report` Output Format

```
errors: N
warnings: N
infos: N
```

Each line is a violation class and its count. A clean file produces:

```
errors: 0
warnings: 0
infos: 0
```

### Exit Codes

| Scenario | Exit Code |
|----------|-----------|
| Lint ran successfully (with or without findings) | `0` |
| DESIGN.md absent (fail-open) | `0` |
| npx unavailable (fail-open) | `0` |
| npx invocation failed (network error, etc.) | `0` (fail-open) |

**Note**: `@google/design.md lint` always exits `0` regardless of findings. To gate on quality, use `--report` and parse the output counts.

## Expected Behavior When DESIGN.md Is Absent

When the design file is not found at the configured path, `design-lint.sh` exits `0` with an informative message to stderr:

```
INFO: Design notes file not found at '<path>' — skipping design-lint (fail-open).
```

This fail-open behavior ensures that projects without a DESIGN.md are not blocked by the linter.

## File Path Configuration

The design file path is resolved from:

1. `DESIGN_MD_NOTES_PATH` environment variable (highest priority — useful for testing)
2. `design.design_notes_path` key in `.claude/dso-config.conf` (via `read-config.sh`)
3. Default: `DESIGN.md`

Example `.claude/dso-config.conf` entry:
```
design.design_notes_path=DESIGN.md
```

## Cold-Start Latency Advisory

The `@google/design.md` CLI is distributed via npx. Latency characteristics:

| Scenario | Approximate Time |
|----------|-----------------|
| Cold start (first download) | ~3s |
| Warm cache (subsequent invocations) | ~1s |
| Warm cache (sub-second lint itself) | <1s |

Cold start occurs once per machine (or after `npm cache clean`). For CI environments with ephemeral runners, consider:

```bash
npm install -g @google/design.md@0.2.0
```

in a CI setup step to eliminate cold-start variance.

## Node.js Compatibility

- **Node.js >=22**: Clean operation (recommended for CI).
- **Node.js 20**: Works with non-fatal `EBADENGINE` warnings from transitive dependencies (`ink@7`, `cli-truncate@6`, `slice-ansi@9`). Suppress with `2>/dev/null` in hook scripts.

## Known CLI Limitations (v0.2.0)

- `spec` subcommand is broken — `spec.md` was not bundled in the distribution.
- `lint -` (stdin mode) is advertised but rejected as `Missing required positional argument: FILE`. Use file path arguments only.
- The `lint` subcommand does not support per-line or per-range scoping. Use the `diff` subcommand for regression-scoped checks.

See `${CLAUDE_PLUGIN_ROOT}/docs/spikes/design-md-cli-validation.md` for full validation findings.
