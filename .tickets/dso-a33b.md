---
id: dso-a33b
status: open
deps: []
links: []
created: 2026-03-17T20:21:06Z
type: task
priority: 0
assignee: Joe Oakhart
parent: dso-awoz
---
# Write failing tests for dso shim template (RED)

## TDD Requirement (RED phase)

Create tests/scripts/test-shim-smoke.sh with failing tests that verify the dso shim template behavior defined in story dso-awoz.

## Implementation Steps

1. Create tests/scripts/test-shim-smoke.sh following the project's assert.sh test pattern (see tests/scripts/test-generate-claude-md.sh for reference)
2. Source $PLUGIN_ROOT/tests/lib/assert.sh for assertions
3. Write the following test functions that will FAIL until the shim template is implemented:

### Tests to write:

**test_shim_template_file_exists**
- Assert: test -f $PLUGIN_ROOT/templates/host-project/dso

**test_shim_is_executable**
- Assert: test -x $PLUGIN_ROOT/templates/host-project/dso

**test_shim_no_nonposix_constructs**
- Assert: grep -qvE 'readlink -f|realpath' $PLUGIN_ROOT/templates/host-project/dso
- Verifies the POSIX-only constraint (no readlink -f, realpath, or GNU coreutils extensions)

**test_shim_exits_0_with_valid_dso_root**
- Set CLAUDE_PLUGIN_ROOT to the plugin root
- Run shim with 'tk --help' argument
- Assert exit code is 0

**test_shim_exits_127_for_missing_script**
- Set CLAUDE_PLUGIN_ROOT to the plugin root
- Run shim with 'nonexistent' argument
- Assert exit code is 127
- Assert stderr output contains the name of the missing script

**test_shim_error_names_missing_script**
- Set CLAUDE_PLUGIN_ROOT to the plugin root
- Capture stderr from 'dso nonexistent'
- Assert error message contains 'nonexistent' (names the missing script)

**test_shim_resolves_dso_root_from_config**
- Create a temp dir with a minimal workflow-config.conf containing dso.plugin_root=$PLUGIN_ROOT
- Run shim with CLAUDE_PLUGIN_ROOT unset, using git repo with the config
- Assert exit code is 0 when valid script is invoked (e.g., tk --help)

**test_shim_error_names_config_key_when_no_dso_root**
- Run shim with CLAUDE_PLUGIN_ROOT unset and no workflow-config.conf
- Capture stderr
- Assert output contains 'dso.plugin_root' (names the config key)
- Assert exit code is non-zero

## File to Create
- tests/scripts/test-shim-smoke.sh

## Notes
- Use mktemp -d for temporary directories; register for cleanup via trap
- Tests must run in isolation (no side effects on the real repo)
- All tests are expected to FAIL (RED) until templates/host-project/dso is created in the next task
- Script must be executable: chmod +x tests/scripts/test-shim-smoke.sh

