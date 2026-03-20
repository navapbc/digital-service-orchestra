---
id: dso-5jqq
status: open
deps: [dso-opue, dso-6trc, dso-tuz0, dso-2vwl]
links: []
created: 2026-03-20T03:33:47Z
type: task
priority: 1
assignee: Joe Oakhart
parent: dso-uc2d
---
# Integration test: full read-config.sh resolution chain end-to-end

## Integration Test (post-implementation)

Write an integration test in tests/scripts/test-flat-config-e2e.sh (or a new test-dso-config-path-e2e.sh) that exercises the full resolution chain end-to-end after all implementation tasks are complete.

### Test scenarios to cover:

test_e2e_resolution_from_dot_claude_dso_config — Given a minimal temp git repo with .claude/dso-config.conf, a script that calls read-config.sh (no explicit config arg) returns correct values.

test_e2e_config_paths_reads_from_dot_claude — Given a temp git repo with .claude/dso-config.conf containing paths.app_dir=myapp, sourcing config-paths.sh produces CFG_APP_DIR=myapp.

test_e2e_shim_resolves_plugin_root — Given a temp git repo with .claude/dso-config.conf containing dso.plugin_root=/some/path, running the shim (via source --lib) sets DSO_ROOT=/some/path.

test_e2e_validate_sh_reads_commands — Given a temp git repo with .claude/dso-config.conf containing commands.test=echo test, validate.sh reads that value correctly (integration with CONFIG_FILE env var for test isolation).

### Constraints
- This is NOT a RED test task — it can be written after implementation tasks complete
- Use isolated temp git repos for each scenario
- WORKFLOW_CONFIG_FILE env var for scripts that support it; explicit CONFIG_FILE env var for validate.sh

