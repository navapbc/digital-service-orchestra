---
id: dso-kexc
status: open
deps: [dso-bkqa]
links: []
created: 2026-03-18T23:14:16Z
type: task
priority: 0
assignee: Joe Oakhart
parent: dso-guxa
---
# Remove plugin check from validate.sh (CMD_TEST_PLUGIN, TIMEOUT_PLUGIN, run_check, report_check, tally_check, LAUNCHED_CHECKS, --help)

Remove all plugin check infrastructure from plugins/dso/scripts/validate.sh.

TDD Requirement: Write failing test FIRST.
Note: test-validate-config-driven.sh will have already been modified by dso-bkqa (fixture/for-loop cleanup). Add new test_validate_sh_no_cmd_test_plugin AFTER the existing tests, appending to the file without touching the sections already modified by dso-bkqa.
In tests/scripts/test-validate-config-driven.sh, add test_validate_sh_no_cmd_test_plugin that asserts CMD_TEST_PLUGIN does NOT appear in validate.sh. Run test to confirm RED. Then:

Removals in plugins/dso/scripts/validate.sh:
1. Line 113: Remove 'CMD_TEST_PLUGIN=$(_cfg "commands.test_plugin" "make test-plugin")'
2. Lines 156-157: Remove 'TIMEOUT_PLUGIN="${VALIDATE_TIMEOUT_PLUGIN:-300}"' 
3. Lines 53-54 (header comment): Remove 'Plugin/hook tests (120s): make test-plugin (from repo root)' timeout comment
4. Line 64-65 (env vars docs): Remove 'VALIDATE_TIMEOUT_PLUGIN - Plugin/hook test suite timeout' from header comment
5. Lines 308-309 (--help): Remove 'plugin: $TIMEOUT_PLUGIN' from Timeouts output
6. Line 621: Remove 'plugin' from LAUNCHED_CHECKS string
7. Line 637: Remove the entire '(cd "$REPO_ROOT" && run_check "plugin" ...) &' line
8. Lines 763-764 (report_check section): Remove 'report_check "plugin" ...' line
9. Lines 773-774 (tally_check section): Remove 'tally_check "plugin" "plugin"' line

After removals, run bash tests/run-all.sh to confirm GREEN (no plugin: line in output, all tests pass).

Files: plugins/dso/scripts/validate.sh, tests/scripts/test-validate-config-driven.sh

## ACCEPTANCE CRITERIA

- [ ] `bash tests/run-all.sh` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && bash tests/run-all.sh
- [ ] `ruff check` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff check plugins/dso/scripts/*.py tests/**/*.py
- [ ] `ruff format --check` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff format --check plugins/dso/scripts/*.py tests/**/*.py
- [ ] validate.sh does not contain CMD_TEST_PLUGIN variable
  Verify: ! grep -q 'CMD_TEST_PLUGIN' $(git rev-parse --show-toplevel)/plugins/dso/scripts/validate.sh
- [ ] validate.sh does not contain TIMEOUT_PLUGIN variable
  Verify: ! grep -q 'TIMEOUT_PLUGIN' $(git rev-parse --show-toplevel)/plugins/dso/scripts/validate.sh
- [ ] validate.sh LAUNCHED_CHECKS does not include 'plugin'
  Verify: ! grep 'LAUNCHED_CHECKS=' $(git rev-parse --show-toplevel)/plugins/dso/scripts/validate.sh | grep -q '"plugin"'
- [ ] Running validate.sh --ci produces no 'plugin:' line in output
  Verify: bash $(git rev-parse --show-toplevel)/plugins/dso/scripts/validate.sh --help 2>&1 | ! grep -q 'plugin:'
- [ ] New test_validate_sh_no_cmd_test_plugin test exists in test-validate-config-driven.sh
  Verify: grep -q 'test_validate_sh_no_cmd_test_plugin' $(git rev-parse --show-toplevel)/tests/scripts/test-validate-config-driven.sh
