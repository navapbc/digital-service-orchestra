---
id: dso-uc2d
status: closed
deps: []
links: []
created: 2026-03-20T00:09:30Z
type: story
priority: 1
assignee: Joe Oakhart
parent: dso-kknz
---
# As a DSO developer, config resolves from .claude/dso-config.conf

## Description

**What**: Update all config resolution paths (read-config.sh, config-paths.sh, shim, and all runtime scripts that hardcode the config path) to use `.claude/dso-config.conf`. Move this repo's config file.
**Why**: Establishes the new canonical config path that all other stories depend on — the walking skeleton for the migration.
**Scope**:
- IN: `read-config.sh` resolution chain, `config-paths.sh`, shim template, all scripts that construct config paths directly (validate.sh, validate-phase.sh, sprint-next-batch.sh, auto-format.sh, pre-bash-functions.sh, etc.), move `workflow-config.conf` → `.claude/dso-config.conf`, config resolution tests
- OUT: `dso-setup.sh` changes (separate story), docs/example file updates (separate story), test fixtures that only contain the old path as data (separate story)

## Done Definitions

- When this story is complete, `read-config.sh` resolves config exclusively from `.claude/dso-config.conf` (relative to git root) with no fallback to the old path
  ← Satisfies: "read-config.sh resolves config exclusively from .claude/dso-config.conf"
- When this story is complete, no runtime script constructs a config path using a hardcoded filename — all config resolution goes through `read-config.sh` or uses the path it returns
  ← Satisfies: "read-config.sh resolves config exclusively from .claude/dso-config.conf" (ensures all callers use the new resolution)
- When this story is complete, the `.claude/scripts/dso` shim reads `dso.plugin_root` from `.claude/dso-config.conf`
  ← Satisfies: "The shim reads dso.plugin_root from .claude/dso-config.conf"
- When this story is complete, this repo's config lives at `.claude/dso-config.conf` with no `workflow-config.conf` at root
  ← Satisfies: "This repo's own config lives at .claude/dso-config.conf"
- When this story is complete, unit tests written and passing for all new or modified config resolution logic

## Considerations

- [Reliability] Config resolution is critical path — all DSO scripts fail if config not found at new path. Ensure tests cover both presence and absence scenarios.
- [Testing] Existing tests use WORKFLOW_CONFIG_FILE env var for isolation — verify env var override still works after the path change.
- [Implicit shared state] The shim uses raw grep to read dso.plugin_root (chicken-and-egg with read-config.sh) — this is a separate code path that needs explicit attention.
- [Conflicting assumptions] CLAUDE_PLUGIN_ROOT-based resolution must change from plugin-dir lookup to git-root/.claude/ lookup — this is a semantic change in directory resolution, not just a filename rename.
- [Scope boundary] Config resolution tests are owned by this story. Test fixtures that contain the old path as data only (not resolution logic) are owned by Story 3.

