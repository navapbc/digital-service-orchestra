---
id: dso-4clm
status: open
deps: [dso-bkqa]
links: []
created: 2026-03-18T23:14:04Z
type: task
priority: 0
assignee: Joe Oakhart
parent: dso-guxa
---
# Remove commands.test_plugin from validate-config.sh KNOWN_KEYS

Remove 'commands.test_plugin' from the KNOWN_KEYS array in plugins/dso/scripts/validate-config.sh.

TDD Requirement: Write failing test FIRST.
In tests/scripts/test-validate-config.sh (the existing validate-config.sh test file), add test_validate_config_does_not_know_test_plugin that greps KNOWN_KEYS in validate-config.sh for the absence of 'commands.test_plugin'. Run test to confirm RED (key still in KNOWN_KEYS). Then:

1. In plugins/dso/scripts/validate-config.sh, remove 'commands.test_plugin' from the KNOWN_KEYS array (~line 65)

After removal, run bash tests/run-all.sh to confirm GREEN.

Files: plugins/dso/scripts/validate-config.sh, tests/scripts/test-validate-config.sh

## ACCEPTANCE CRITERIA

- [ ] `bash tests/run-all.sh` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && bash tests/run-all.sh
- [ ] `ruff check` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff check plugins/dso/scripts/*.py tests/**/*.py
- [ ] `ruff format --check` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff format --check plugins/dso/scripts/*.py tests/**/*.py
- [ ] validate-config.sh KNOWN_KEYS does not contain commands.test_plugin
  Verify: ! grep -q 'commands.test_plugin' $(git rev-parse --show-toplevel)/plugins/dso/scripts/validate-config.sh
- [ ] New test_validate_config_does_not_know_test_plugin test exists in test-validate-config.sh
  Verify: grep -q 'test_validate_config_does_not_know_test_plugin' $(git rev-parse --show-toplevel)/tests/scripts/test-validate-config.sh
