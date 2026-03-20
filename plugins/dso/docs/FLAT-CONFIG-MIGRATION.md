# Flat Config Migration Plan

Migration from `workflow-config.yaml` (YAML, requires Python to parse) to a flat key=value `.conf` file that bash reads natively via `grep`/`cut`.

**Status**: Completed (2026-03-14). The flat `dso-config.conf` format is now the primary config format. `read-config.sh` reads `.conf` files directly via `grep`/`cut` with no Python dependency. YAML fallback is retained for migration compatibility but `.conf` takes precedence when both files exist. The YAML cache infrastructure has been removed.

## Why Consider This

`workflow-config.yaml` is consumed exclusively by bash scripts and Claude Code hooks. YAML requires a Python subprocess (~100ms) to parse from bash. The caching layer reduces this to ~3ms on cache hits, but the cache adds complexity (generation, mtime validation, self-healing fallback). A flat file would eliminate both the Python dependency and the caching layer.

### Current architecture (with cache)

```
workflow-config.yaml (YAML, human-edited)
    ↓ --generate-cache (Python, ~100ms, runs once per session)
config-cache (flat key=value, machine-generated)
    ↓ grep/cut (~3ms per read)
caller gets value
    ↓ (on cache miss/stale)
Python fallback (~100ms, self-healing)
```

### Proposed architecture (flat file)

```
workflow-config.env (flat key=value, human-edited)
    ↓ grep/cut (~1-2ms per read)
caller gets value
```

One file, one code path, no caching layer, no Python dependency.

## Research: Claude Code Plugin Conventions

Claude Code plugins use **JSON** for all plugin config files (`plugin.json`, `hooks.json`, `settings.json`). These files are schema-locked — plugins cannot add custom configuration keys.

`workflow-config.yaml` is **project-level runtime config**, not a plugin config file. Claude Code has no convention or opinion about its format. The format decision is entirely about what best serves the consumers (bash scripts).

JSON was considered but requires `jq` to parse from bash — better than Python but still a subprocess.

## Flat File Format Design

### Example

```env
# workflow-config.env — project configuration for Digital Service Orchestra plugin
# Format: key=value (dot-notation for nesting, repeated keys for lists)
# Read by: read-config.sh via grep/cut (no Python required)

version=1.0.0
stack=python-poetry

# Paths
paths.app_dir=app
paths.src_dir=src
paths.test_dir=tests
paths.test_unit_dir=tests/unit

# Commands
commands.test=make test
commands.lint=make lint
commands.format=make format
commands.validate=./scripts/validate.sh --ci
commands.test_unit=make test-unit-only
commands.test_e2e=make test-e2e

# Format hook config (repeated keys = list)
format.extensions=.py
format.source_dirs=app/src
format.source_dirs=app/tests

# Database
database.base_port=5432
database.ensure_cmd=make db-start && make db-status

# Infrastructure (repeated keys = list)
infrastructure.compose_files=app/docker-compose.yml
infrastructure.compose_files=app/docker-compose.db.yml
infrastructure.compose_project=lockpick-db-

# Tickets
tickets.prefix=lockpick-doc-to-logic
tickets.directory=.tickets
tickets.sync.jira_project_key=DTL
tickets.sync.bidirectional_comments=true
```

### Read operations

```bash
# Scalar: grep + head + cut (~1-2ms)
VAL=$(grep "^commands.validate=" config.env | head -1 | cut -d= -f2-)

# List: grep + cut (all matching lines, ~1-2ms)
grep "^format.source_dirs=" config.env | cut -d= -f2-

# Missing key: grep returns empty, exit 0 (same as current behavior)
```

### `read-config.sh` replacement (~15 lines)

```bash
#!/usr/bin/env bash
set -uo pipefail

list_mode=""
[[ "${1:-}" == "--list" ]] && { list_mode=1; shift; }
key="${1:?Usage: read-config.sh [--list] <key> [config-file]}"
config_file="${2:-}"

# Resolution (same order as current)
if [[ -z "$config_file" ]]; then
    if [[ -n "${CLAUDE_PLUGIN_ROOT}" ]] && [[ -f "${CLAUDE_PLUGIN_ROOT}/workflow-config.env" ]]; then
        config_file="${CLAUDE_PLUGIN_ROOT}/workflow-config.env"
    elif [[ -f "$(pwd)/workflow-config.env" ]]; then
        config_file="$(pwd)/workflow-config.env"
    else
        exit 0
    fi
fi
[[ ! -f "$config_file" ]] && exit 0

if [[ -n "$list_mode" ]]; then
    results=$(grep "^${key}=" "$config_file" | cut -d= -f2-)
    [[ -z "$results" ]] && exit 1
    echo "$results"
else
    grep "^${key}=" "$config_file" | head -1 | cut -d= -f2- | tr -d '\n'
fi
```

## Tradeoffs: YAML + Cache vs Flat File

| Dimension | YAML + Cache (current) | Flat File |
|---|---|---|
| **Read speed** | ~3ms (cache hit), ~100ms (miss) | ~1-2ms (always) |
| **Moving parts** | 3 (YAML parser, cache generator, cache reader) | 1 (grep/cut) |
| **Python dependency** | Required (cache generation, fallback) | Eliminated |
| **Schema validation** | 504-line JSON schema with types, patterns, defaults, descriptions | No standard equivalent — would need custom bash validator or be dropped |
| **Human readability** | YAML sections with indentation, inline comments, clear scalar/list distinction | Dot-notation keys with `#` comments — less visual grouping, list representation less obvious |
| **List representation** | YAML arrays: `['.py', '.ts']` — clear, typed | Repeated keys — functional but no syntactic distinction from "scalar that appears twice" |
| **Onboarding** | YAML is universally familiar | Flat dotfiles less discoverable for new adopters of the plugin |
| **Failure mode** | Cache miss → Python fallback (self-healing) | Grep miss → empty string (same as YAML missing-key) |
| **Stale data risk** | Mtime check on every read prevents it | N/A — reads source directly |
| **Migration cost** | Already implemented | Convert config file, schema, example file, docs, ~10 test fixtures |
| **`auto-format.sh` inline Python** | Still present (reads lists via inline Python, not `read-config.sh`) | Eliminated — lists readable via grep |
| **Total code** | ~300 lines (`read-config.sh` with cache + Python) | ~20 lines (`read-config.sh` grep-only) |

### What YAML provides that flat file loses

1. **JSON Schema validation** (`workflow-config-schema.json`, 504 lines): Type checking (`integer`, `string`, `boolean`, `array`), enum validation (`stack` field), pattern matching (version semver), min-length constraints, default values, and per-key descriptions. This schema is used in tests and serves as documentation. A flat file format has no standard schema mechanism.

2. **Hierarchical grouping**: YAML sections (`commands:`, `format:`, `database:`) provide visual structure. In a flat file, `commands.validate` and `commands.test` are only near each other by convention — there's no syntactic grouping.

3. **Clear list syntax**: `extensions: ['.py', '.ts']` is unambiguous. Repeated keys (`format.extensions=.py` / `format.extensions=.ts`) work but callers must know which keys are lists.

4. **Comment co-location**: YAML comments sit inside their section's indentation block. Flat file comments are freeform — they work but lose structural association.

### What flat file provides that YAML + cache doesn't

1. **Root cause elimination**: No Python, no cache, no mtime checking, no fallback paths. The format IS the fast format.

2. **Dramatically simpler `read-config.sh`**: ~15 lines of grep/cut vs ~300 lines of Python + cache infrastructure.

3. **`auto-format.sh` simplification**: Currently spawns 2 inline Python subprocesses to read list keys (`format.extensions`, `format.source_dirs`). With a flat file, these become `grep` calls.

4. **One fewer dependency**: PyYAML no longer required for config reads (still needed for other Python code, but not on the hook hot path).

## Migration Steps (if/when pursued)

### Phase 1: Convert format

1. Create `workflow-config.env` from `workflow-config.yaml` using the flat format above
2. Update `read-config.sh` to read `.env` format (grep-based, ~15 lines)
3. Remove cache infrastructure from `read-config.sh` (no longer needed)
4. Update config file resolution: look for `workflow-config.env` instead of `.yaml`
5. Update `CONFIG-RESOLUTION.md`

### Phase 2: Update consumers

6. Update `auto-format.sh`: replace inline Python list reads with `read-config.sh --list`
7. Update `workflow-config.example.yaml` → `workflow-config.example.env`
8. Update `INSTALL.md`, `MIGRATION-TO-PLUGIN.md`, and other docs referencing the YAML file
9. Update test fixtures that create YAML config files

### Phase 3: Schema

10. Decide on validation approach:
    - **Option A**: Drop schema validation (simplest, accept looser guarantees)
    - **Option B**: Write a bash validator that checks key existence, types, and patterns
    - **Option C**: Keep JSON schema but validate against the flat file via a conversion script
11. Update or remove `workflow-config-schema.json`

### Phase 4: Cleanup

12. Remove Python YAML parsing code from `read-config.sh`
13. Remove `--generate-cache` mode
14. Remove cache-related tests
15. Update `CLAUDE.md` references

### Estimated scope

- ~10 files to modify (read-config.sh, auto-format.sh, docs, test fixtures)
- ~70 callers — no changes needed if `read-config.sh` API stays the same
- Schema decision is the main design question

## Decision Criteria

Migrate to flat file when any of these are true:

- The caching layer becomes a maintenance burden (bugs, edge cases, test complexity)
- A second project adopts the plugin and finds YAML config onboarding friction
- `auto-format.sh` inline Python needs to be eliminated for performance
- The JSON schema stops providing value (no bugs caught by validation)

Do NOT migrate if:

- The caching layer works reliably and needs no maintenance
- Schema validation is catching real config errors
- YAML readability is important for the team
