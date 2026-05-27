# Spike Report: @google/design.md CLI Validation Semantics

**Ticket**: e579-0014-c813-40ca  
**Date**: 2026-05-26  
**Author**: Test  
**Status**: Complete

## Summary

This spike validates the `@google/design.md` CLI for use as a structural linter for DESIGN.md files in the DSO workflow. All tests were run on macOS Darwin 25.5.0 with Node.js v20.20.2 and npx 10.8.2.

## Pinned Version

**Pinned version: `0.2.0`**

The version was determined by running:
```
npx --yes @google/design.md@latest --version
# Output: 0.2.0
```

`@google/design.md@0.2.0` is the latest stable release as of the spike date. The package runs successfully under Node.js v20 despite engine warnings requiring Node.js >=22 (from transitive dependencies `ink`, `cli-truncate`, `slice-ansi`). These are non-fatal `EBADENGINE` warnings — the CLI functions correctly.

**Node.js compatibility note**: The official engine requirement is Node >=22. On Node 20, the CLI works but emits deprecation and engine warnings to stderr. CI environments should prefer Node 22+. In DSO hook scripts, `npx` invocations should redirect or suppress stderr to avoid noise in pre-commit output.

**Recommended pinned invocation**:
```bash
npx --yes @google/design.md@0.2.0 lint <FILE>
```

## Exit Code Mapping

| Scenario | Exit Code | Output |
|----------|-----------|--------|
| Valid DESIGN.md (no findings) | `0` | `{"findings":[],"summary":{"errors":0,"warnings":0,"infos":0}}` |
| File with warnings only | `0` | JSON with findings array, summary.warnings > 0 |
| File with errors only | `0` | JSON with findings array, summary.errors > 0 |
| Missing/nonexistent file | `1` | JSON error object + stderr stack trace |
| Bad CLI invocation (missing FILE arg) | `1` | Usage help + ERROR message to stderr |
| `diff` with regression (after worse than before) | `1` | JSON with `"regression": true` |
| `diff` with no regression (same or better) | `0` | JSON with `"regression": false` |
| `diff` with improvement (after better than before) | `0` | JSON with `"regression": false`, negative delta |

**Key observation**: The `lint` subcommand always exits `0` regardless of warnings or errors in the DESIGN.md content. Exit code `1` only occurs on I/O errors (file not found) or invalid CLI invocations. **To gate on lint quality, callers must parse the JSON output** — exit code alone is not sufficient for pass/fail determination.

**Recommended gate logic** for lint validation:
```bash
OUTPUT=$(npx --yes @google/design.md@0.2.0 lint "$FILE" 2>/dev/null)
EXIT_CODE=$?
if [[ $EXIT_CODE -ne 0 ]]; then
  echo "CLI error (file I/O or invocation failure)" >&2
  exit 1
fi
ERROR_COUNT=$(echo "$OUTPUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['summary']['errors'])")
if [[ "$ERROR_COUNT" -gt 0 ]]; then
  echo "FAIL: $ERROR_COUNT errors found" >&2
  exit 1
fi
```

**Recommended gate logic** for diff-based regression check:
```bash
OUTPUT=$(npx --yes @google/design.md@0.2.0 diff "$BEFORE" "$AFTER" 2>/dev/null)
REGRESSION=$(echo "$OUTPUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['regression'])")
if [[ "$REGRESSION" == "True" ]]; then
  echo "FAIL: DESIGN.md diff introduces regression" >&2
  exit 1
fi
# diff exits 1 when regression=true, 0 when regression=false
```

## Latency Measurements

Environment: macOS Darwin 25.5.0, Node.js v20.20.2, npx 10.8.2, M-series chip. File: minimal DESIGN.md (~200 bytes).

| Invocation | Time | Notes |
|------------|------|-------|
| Cold start (first-ever `npx --yes @google/design.md@latest --version`) | ~3s | Includes npm package download, extraction |
| `lint` after version command (npx cache warm, process startup) | ~1s | Package already in npx cache |
| `lint` warm cache (second consecutive call) | <1s | Sub-second; cached in npx cache at `~/.npm/_npx/` |
| Version pinned invocation (`@0.2.0`) warm cache | ~1s | Same cache entry as `@latest` when version matches |

**Interpretation**:
- Cold start (first download) takes ~3 seconds — occurs only once per machine or after `npm cache clean`.
- Subsequent invocations are ~1s due to Node.js startup overhead (not download overhead). The npx cache stores the package at `~/.npm/_npx/<hash>/node_modules/@google/design.md/`.
- Warm cache is sub-second for the actual lint operation itself; the ~1s is largely Node.js runtime startup.
- For CI environments with ephemeral runners, cold start will occur each run unless the npx cache directory is persisted. Consider `npm install -g @google/design.md@0.2.0` in a CI setup step to eliminate cold-start variance.

**Hook latency impact**: In a pre-commit hook context, each `npx` invocation adds ~1s overhead. For DESIGN.md files which are typically one file per repo, this is acceptable. If multiple files need linting, batch them in a single script to minimize hook latency.

## Diff-Touched-Line Scoping

**Finding: The CLI does not support per-line or per-range linting — it operates at the file level only.**

The `lint` subcommand takes a single `<FILE>` argument with no `--line`, `--range`, `--from-line`, or `--to-line` options:
```
USAGE design.md lint [OPTIONS] <FILE>

OPTIONS:
  --format="json"    Output format: json or text
```

The `diff` subcommand compares two complete DESIGN.md files and reports which token categories changed (colors, typography, rounded, spacing, components), along with an aggregate finding count delta and a `regression` boolean:
```
USAGE design.md diff [OPTIONS] <BEFORE> <AFTER>
```

**Finding structure**: The `lint` JSON output contains findings with `severity` and `message` fields only. Line/column numbers appear embedded in message text when relevant (e.g., `"...at line 2, column 33:\n..."`) but are not structured fields — callers cannot filter findings by line range programmatically without parsing message strings.

**Implication for diff-touched-line scoping**: Diff-touched-line scoping (only flagging issues introduced by changed lines) is **not natively supported**. Options:

1. **`diff` subcommand approach** (recommended): Run `diff` between the `HEAD~1` and current version of DESIGN.md. The `regression` field indicates if the change introduced new issues. This is structurally equivalent to "did your diff introduce new violations?" without per-line precision. Exit code `1` = regression detected.

2. **Manual scope workaround**: Extract git diff hunks, construct a trimmed DESIGN.md containing only changed sections, lint it. This is fragile for DESIGN.md since the file has interdependent sections.

3. **File-level enforcement** (simplest): Always lint the entire file; treat any pre-existing warnings as baseline noise to be tracked separately.

**Recommendation**: Use the `diff` subcommand with `git show HEAD~1:DESIGN.md` as `BEFORE` and the working-copy as `AFTER` to detect regressions introduced by the current diff. This is the closest available approximation to diff-touched-line scoping.

## Additional Findings

- **`spec` subcommand is broken** in the 0.2.0 npx bundle: `ERROR  Failed to load spec.md.` — the spec.md file was not bundled into `dist/`. This is a packaging bug in the upstream package; it does not affect lint or diff functionality.
- **`export` subcommand** converts DESIGN.md tokens to CSS-Tailwind, JSON-Tailwind, and W3C DTCG formats — useful for design token extraction but out of scope for lint gating.
- **stdin mode** (`lint -`) is advertised in help text but rejected as `Missing required positional argument: FILE` in v0.2.0 — a CLI bug. Use file path arguments only.
- **Engine warnings**: `npm warn EBADENGINE` for `ink@7.0.4`, `cli-truncate@6.0.0`, `slice-ansi@9.0.0` require Node >=22. Suppress with `2>/dev/null` in hook scripts if these warnings are noise.
- **Deprecated package warning**: `npm warn deprecated mdast@3.0.0: mdast was renamed to remark` — upstream issue, non-blocking.

## Conclusion

`@google/design.md@0.2.0` is viable for DESIGN.md structural linting with the following constraints:
1. Gate on JSON output `summary.errors` count, not exit code, for lint quality checks.
2. Use the `diff` subcommand for regression-scoped checks aligned with git diffs.
3. Plan for ~1s per-invocation overhead in hook scripts.
4. Require Node 22+ in CI for clean operation; Node 20 works with warnings.
