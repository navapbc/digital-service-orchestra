---
id: dso-bkqa
status: open
deps: []
links: []
created: 2026-03-18T23:13:57Z
type: task
priority: 0
assignee: Joe Oakhart
parent: dso-guxa
---
# Remove commands.test_plugin from workflow-config.conf and update test-validate-config-driven.sh

Remove the vestigial commands.test_plugin=true key from workflow-config.conf and update test-validate-config-driven.sh to match.

TDD Requirement: Write failing test FIRST.
In tests/scripts/test-validate-config-driven.sh, add test_no_test_plugin_in_config that asserts commands.test_plugin is NOT present in the real workflow-config.conf. Run the test to confirm RED (key still exists). Then:

1. Remove 'commands.test_plugin=true' and its comment from workflow-config.conf
2. In test-validate-config-driven.sh fixture block (~line 33), remove: commands.test_plugin=make test-plugin
3. In for-loop ~line 68, remove 'commands.test_plugin' from the key list
4. In for-loop ~line 113 (test_workflow_config_has_all_validate_keys), remove 'commands.test_plugin' from the key list
5. Remove test_plugin=$(grep ...) assignment at ~line 83
6. Remove assert_eq 'commands.test_plugin value' assertion at ~line 88

Files: workflow-config.conf, tests/scripts/test-validate-config-driven.sh

## ACCEPTANCE CRITERIA

- [ ] `bash tests/run-all.sh` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && bash tests/run-all.sh
- [ ] `ruff check` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff check plugins/dso/scripts/*.py tests/**/*.py
- [ ] `ruff format --check` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff format --check plugins/dso/scripts/*.py tests/**/*.py
- [ ] workflow-config.conf does not contain commands.test_plugin key
  Verify: ! grep -q '^commands.test_plugin=' $(git rev-parse --show-toplevel)/workflow-config.conf
- [ ] test-validate-config-driven.sh has no remaining test_plugin references
  Verify: ! grep -q 'test_plugin' $(git rev-parse --show-toplevel)/tests/scripts/test-validate-config-driven.sh
- [ ] New test_no_test_plugin_in_config test exists in test-validate-config-driven.sh
  Verify: grep -q 'test_no_test_plugin_in_config' $(git rev-parse --show-toplevel)/tests/scripts/test-validate-config-driven.sh

## File Impact
- `workflow-config.conf` - Remove the `commands.test_plugin=true` key and its associated comment
- `tests/scripts/test-validate-config-driven.sh` - Add new test `test_no_test_plugin_in_config`, remove fixture definition, remove `test_plugin` from key validation loops, and remove related assertions and variable assignments
