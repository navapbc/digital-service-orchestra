# Contract: Recipe Engine Adapter

- Signal Name: Recipe Engine Adapter Output
- Status: accepted
- Scope: recipe-executor.sh → adapter scripts → sprint Phase 5 (epic 5108-39a1)
- Date: 2026-04-07

## Purpose

This document defines the shared interface between `recipe-executor.sh` (the orchestrating executor) and individual recipe engine adapters (e.g., ts-morph, scaffold-route, normalize-imports adapters). Each adapter script implements this protocol to receive recipe parameters, perform transforms, and report results in a structured format.

This contract must be agreed upon before any implementation begins to prevent implicit assumptions and ensure the executor and all adapter scripts stay in sync.

---

## Adapter Location Convention

All recipe engine adapter scripts are placed at:

```
plugins/dso/scripts/recipe-adapters/<engine-name>-adapter.sh  # shim-exempt: path in contract doc
```

For example: `plugins/dso/scripts/recipe-adapters/ts-morph-adapter.sh` # shim-exempt: path in contract doc

The executor discovers adapters by mapping `engine_name` from the recipe registry to the corresponding script at this path.

---

## Input Format

### RECIPE_PARAM_* Environment Variable Protocol

The executor passes all recipe parameters to the adapter via environment variables. Adapters MUST NOT accept positional shell arguments for recipe parameters.

**Naming convention**: Each recipe field named `<FIELD_NAME>` is exposed as `RECIPE_PARAM_<FIELD_NAME>` (uppercase). For example, a recipe field `target_file` is passed as `RECIPE_PARAM_TARGET_FILE`.

**Why no shell interpolation**: Shell argument passing requires quote-aware handling of special characters and whitespace. Environment variables avoid shell interpolation hazards — the value is passed as-is to the adapter subprocess without re-evaluation by the shell. This ensures that file paths containing spaces, glob characters, or quotes are transmitted safely.

### Standard Environment Variables

The following variables are set by the executor before invoking any adapter:

| Variable | Type | Description |
|---|---|---|
| `RECIPE_PARAM_*` | string | One variable per recipe field, uppercased (see naming convention above). |
| `RECIPE_TIMEOUT_SECONDS` | integer | Maximum seconds the adapter may run. Default: `600`. Adapter MUST self-terminate and emit a degraded result if this limit is exceeded. |
| `RECIPE_MIN_ENGINE_VERSION` | string | Minimum required engine version (semver string, e.g., `5.0.0`). Corresponds to the `min_engine_version` field in the recipe registry schema. Adapter MUST validate the installed engine version against this before executing transforms. If this variable is unset or empty, the adapter MUST skip version checking and proceed. |
| `RECIPE_DRY_RUN` | boolean (`true`/`false`) | When `true`, the adapter reports what would change without writing any files. |

### Working Directory Convention

The executor sets the working directory to the repository root before invoking the adapter. Adapters MUST treat all file paths as relative to the repository root.

---

## Version Check Protocol

Before executing any transforms, the adapter MUST:

1. Detect the installed engine binary (e.g., `node`, `ts-node`, custom binary).
2. Extract the engine's reported version string.
3. Compare the installed version against `RECIPE_MIN_ENGINE_VERSION` using semver comparison (major.minor.patch).

If `RECIPE_MIN_ENGINE_VERSION` is unset or empty, the adapter MUST skip version checking and proceed with the transform (treat as "any version accepted").

If the engine binary is absent or the installed version is below `RECIPE_MIN_ENGINE_VERSION`, the adapter MUST immediately emit the degraded JSON output (see Output Format below) with `exit_code: 2` and `degraded: true`, then exit. No transforms are attempted.

---

## Degraded Status Protocol

When the engine is unavailable or below minimum version:

- `degraded` field: `true`
- `exit_code`: `2`
- `timed_out` field: `false` (omitted or explicitly false; `true` is reserved for the timeout case — see Timeout Protocol)
- `files_changed`: empty array `[]`
- `transforms_applied`: `0`
- `errors`: array containing a human-readable description of why the engine is unavailable (e.g., `"ts-morph not found: install via npm install -g ts-morph"` or `"ts-morph version 4.2.0 is below minimum required 5.0.0"`)

Degraded exit (exit code 2) is distinct from failure (exit code 1). Degraded indicates engine infrastructure is absent; failure indicates the engine was present but a transform failed.

Both "engine unavailable/below minimum version" and "timed out" use exit code 2 with `degraded: true`. To distinguish between these two cases, inspect the `timed_out` boolean field: `timed_out: true` means the adapter timed out; `timed_out: false` (or absent) means the engine was unavailable or below version. This distinction matters for retry logic: timeouts may succeed on retry or with a larger timeout value, while engine-unavailable requires installation action.

---

## Rollback Protocol

**Adapters MUST NOT commit, stash, or manage git state themselves.** The executor owns all rollback responsibility.

Before invoking the adapter, the executor stashes any uncommitted changes. On adapter completion:
- Exit code 0 (success): executor pops the stash (applies saved changes back).
- Exit code 1 (failure): executor drops the stash (reverts to pre-transform state).
- Exit code 2 (degraded): executor drops the stash (no transforms were applied).

**Stash pop conflict handling**: When popping the stash on success, the executor MUST handle `git stash pop` failures (merge conflicts). If `git stash pop` exits non-zero (indicating a merge conflict between the stashed changes and the adapter-modified working tree), the executor MUST abort the stash pop by running `git checkout -- .` followed by `git stash drop`, and synthesize a failure response with `exit_code: 1`, `files_changed: []`, `transforms_applied: 0`, `errors: ["git stash pop conflict: pre-existing uncommitted changes overlap with adapter-modified files; manual merge required"]`, `degraded: false`. This ensures the working tree is left in a clean state even when stash pop fails.

Adapters that attempt to `git stash`, `git commit`, or `git reset` on their own will cause double-stash errors and break the rollback guarantee. This is a hard constraint: adapters operate on the working tree only.

---

## Output Format

Adapters MUST print a single JSON object to stdout as their last output, followed by a newline. No other output may appear after the JSON object (earlier diagnostic lines to stderr are permitted).

### JSON Schema

```json
{
  "files_changed": ["path/to/file1.ts", "path/to/file2.ts"],
  "transforms_applied": 3,
  "errors": [],
  "exit_code": 0,
  "degraded": false,
  "engine_name": "ts-morph"
}
```

The `timed_out` field is optional and only present when `exit_code` is `2` and `degraded` is `true`. When a timeout occurs, the adapter MUST include `"timed_out": true` in the JSON payload (see Timeout Protocol).

### Field Definitions

| Field | Type | Required | Description |
|---|---|---|---|
| `files_changed` | array of strings | yes | Relative paths (from repo root, no leading `./`, forward-slash separated, no trailing slash) of all files written or modified by the adapter. Empty array on failure or degraded. |
| `transforms_applied` | integer | yes | Count of individual transform operations successfully applied. `0` on failure or degraded. |
| `errors` | array of strings | yes | Human-readable error messages. Empty array on success. At least one entry on failure or degraded. |
| `exit_code` | integer | yes | Exit code the adapter will use when it exits: `0` = success, `1` = error, `2` = degraded. Must match the actual process exit code. |
| `degraded` | boolean | yes | `true` when engine binary is absent, below minimum version, or timed out. `false` otherwise. |
| `timed_out` | boolean | no | Present and `true` only when the adapter timed out (exit_code 2). Absent or `false` for engine-unavailable/below-version degraded exits. Allows the executor to distinguish timeout (retry/tune) from missing engine (install action required). |
| `engine_name` | string | yes | Short identifier for the engine (e.g., `"ts-morph"`, `"scaffold-route"`, `"normalize-imports"`). Always present; used for diagnostics and logging by the executor. |

### Exit Code Definitions

| Exit Code | Meaning | `degraded` | `files_changed` |
|---|---|---|---|
| `0` | All transforms applied successfully | `false` | Populated |
| `1` | One or more transforms failed; partial results may apply | `false` | May be non-empty (partial success) |
| `2` | Engine unavailable, below minimum version, or timed out; no transforms attempted | `true` | Empty |

---

## Signal Format

The JSON output emitted to stdout constitutes the signal consumed by the executor. The executor parses the JSON after the adapter exits.

### Canonical parsing prefix

The executor MUST parse the adapter's stdout as JSON. The canonical pattern for detecting the output boundary is:

```
{
```

Adapters MUST emit exactly one JSON object to stdout. The executor treats the entire stdout content as a single JSON object. Adapters MUST NOT emit any non-JSON output to stdout — all diagnostic output, progress messages, and log lines MUST be written to stderr. This is a strict requirement: stdout is reserved exclusively for the single JSON result object.

Parsers must not attempt line-by-line parsing of the JSON — the full object may span multiple lines. The executor MUST use a JSON parser (e.g., `python3 -c "import json, sys; print(json.load(sys.stdin))"` or equivalent) rather than text-matching individual fields.

---

## Failure Contract

If the adapter:

- exits without printing valid JSON to stdout,
- prints JSON missing required fields,
- or exits with an unexpected exit code (not 0, 1, or 2),

the executor MUST treat the result as `exit_code: 1` (error) with `files_changed: []`, `transforms_applied: 0`, `errors: ["adapter produced no parseable output"]`, `degraded: false`, and `engine_name: "<adapter-script-name>"`. The executor MUST log the raw stdout for diagnostics.

---

## Timeout Protocol

The adapter MUST respect `RECIPE_TIMEOUT_SECONDS`. Adapters SHOULD use a self-imposed timeout (e.g., `timeout $RECIPE_TIMEOUT_SECONDS <command>`) around the engine invocation. If the timeout fires:

- Emit the standard degraded JSON output with `exit_code: 2`, `degraded: true`, `timed_out: true`, and an error string indicating timeout (e.g., `"transform timed out after 600 seconds"`).
- Exit with code `2`.

Including `"timed_out": true` in the payload allows the executor to distinguish a timeout (which may succeed on retry or with a larger timeout budget) from an engine-unavailable degraded exit (which requires installation action).

If an adapter does not self-enforce the timeout, the executor will SIGKILL the adapter after `RECIPE_TIMEOUT_SECONDS + 10` seconds as a hard backstop.

---

## Example Payloads

**Successful run:**
```json
{
  "files_changed": ["src/components/Button.tsx", "src/components/Input.tsx"],
  "transforms_applied": 4,
  "errors": [],
  "exit_code": 0,
  "degraded": false,
  "engine_name": "ts-morph"
}
```

**Engine missing (degraded):**
```json
{
  "files_changed": [],
  "transforms_applied": 0,
  "errors": ["ts-morph not found: run 'npm install ts-morph' to install"],
  "exit_code": 2,
  "degraded": true,
  "engine_name": "ts-morph"
}
```

**Partial failure:**
```json
{
  "files_changed": ["src/routes/index.ts"],
  "transforms_applied": 1,
  "errors": ["failed to resolve import in src/routes/admin.ts: module 'shared/auth' not found"],
  "exit_code": 1,
  "degraded": false,
  "engine_name": "scaffold-route"
}
```

---

## Consumers

The following components implement or consume this contract:

| Component | Role | Notes |
|---|---|---|
| `plugins/dso/scripts/recipe-executor.sh` | Executor / Consumer | Sets RECIPE_PARAM_* env vars; parses JSON output; owns rollback # shim-exempt: path in contract doc |
| `plugins/dso/scripts/recipe-adapters/ts-morph-adapter.sh` | Emitter | Implements ts-morph transforms # shim-exempt: path in contract doc |
| `plugins/dso/scripts/recipe-adapters/scaffold-route-adapter.sh` | Emitter | Implements scaffold-route transforms # shim-exempt: path in contract doc |
| `plugins/dso/scripts/recipe-adapters/normalize-imports-adapter.sh` | Emitter | Implements normalize-imports transforms # shim-exempt: path in contract doc |

All implementors must read this contract before writing their adapter or executor. Changes to the JSON output format, exit code definitions, or RECIPE_PARAM_* protocol require updating all conforming adapters and this document atomically in the same commit.

---

## Versioning

This contract is versioned. Breaking changes (field removal, exit code redefinition, env var protocol changes) require updating all conforming emitters and consumers and this document atomically in the same commit. Additive changes (new optional fields, new RECIPE_PARAM_* variables with documented defaults) are backward-compatible.

### Change Log

- **2026-04-07**: Initial version — defines recipe engine adapter interface for recipe-executor.sh and all engine adapter scripts (ts-morph, scaffold-route, normalize-imports). Specifies RECIPE_PARAM_* env var protocol, JSON output format, exit codes, rollback constraints, degraded status protocol, and timeout handling.
