---
id: dso-guxa
status: open
deps: []
links: []
created: 2026-03-18T22:58:40Z
type: story
priority: 0
assignee: Joe Oakhart
parent: dso-p2d3
---
# As a developer, the separate plugin test check is removed from validate.sh and its configuration


## What
Remove the `plugin` check step from validate.sh and all its supporting configuration/documentation.

## Why
Plugin testing was incorporated as a separate step during plugin development. Now that the plugin has been migrated to a standalone project, the separate `plugin` check is vestigial — it runs `true` (a no-op) via `commands.test_plugin=true` in workflow-config.conf. This step should be removed cleanly.

## Scope

IN:
- `plugins/dso/scripts/validate.sh`: Remove `CMD_TEST_PLUGIN`, `TIMEOUT_PLUGIN`, `VALIDATE_TIMEOUT_PLUGIN` docs/env var, `run_check "plugin"`, `report_check "plugin"`, `tally_check "plugin"`, remove `"plugin"` from `LAUNCHED_CHECKS`, clean `--help` output
- `workflow-config.conf`: Remove `commands.test_plugin=true`
- `plugins/dso/scripts/validate-config.sh`: Remove `commands.test_plugin` from `KNOWN_KEYS` array
- `plugins/dso/docs/workflows/COMMIT-WORKFLOW.md`: Remove Step 1.75 (Plugin Tests) and its entire "Test Failure Delegation (Step 1.75)" section
- `tests/scripts/test-validate-config-driven.sh`: Remove all `commands.test_plugin` references — specifically:
  - The fixture block line `commands.test_plugin=make test-plugin` (~line 32)
  - `commands.test_plugin` from both `for key in ...` loop iterations (~lines 68, 113)
  - The `test_plugin=$(grep ...)` assignment (~line 82)
  - The `assert_eq "commands.test_plugin value" ...` assertion (~line 89)
- `plugins/dso/hooks/lib/session-misc-functions.sh`: Remove dead `test-plugin` pattern from nohup orphan process cleanup (~line 50)
- `tests/hooks/test-nohup-cleanup.sh`: Replace `command=timeout 300 make test-plugin` fixture (~line 172) with a different representative command (e.g., `make test-e2e`) so the orphan cleanup test doesn't reference a dead command — test is kept, fixture value is updated
- `tests/scripts/test-check-plugin-test-needed.sh`: Update `test_commit_workflow_has_plugin_test_step` to assert Step 1.75 is absent from COMMIT-WORKFLOW.md (flip the assertion to verify the intentional removal) — test is kept, assertion is updated

OUT: Deleting any test files or scripts (all tests are kept), updating `commands.test_unit` (separate story dso-wglr), updating documentation/examples (story dso-baje)

Note: `tests/scripts/test-check-plugin-test-needed.sh` has a test (`test_commit_workflow_has_plugin_test_step`) that asserts `make test-plugin` is in COMMIT-WORKFLOW.md. This assertion must be updated (not the test deleted) — the test should instead assert Step 1.75 is absent from COMMIT-WORKFLOW.md, verifying the removal is intentional. The `check-plugin-test-needed.sh` script itself is kept as-is.

## Done Definitions

- When this story is complete, running `validate.sh --ci` shows no `plugin:` line in the output
  ← Satisfies: "Remove plugin testing as a separate step"
- When this story is complete, `workflow-config.conf` contains no `commands.test_plugin` key
  ← Satisfies: "This project's configuration file should be configured to run this project's tests"
- When this story is complete, `COMMIT-WORKFLOW.md` contains no Step 1.75
  ← Satisfies: "Remove plugin testing as a separate step"
- When this story is complete, `bash tests/run-all.sh` passes (test-validate-config-driven.sh updated)
  ← Satisfies: "Remove plugin testing as a separate step"

## Considerations
- [Maintainability] Remove TIMEOUT_PLUGIN and VALIDATE_TIMEOUT_PLUGIN env var from validate.sh --help output and header docs to avoid misleading future contributors
- [Maintainability] Remove dead nohup orphan cleanup pattern for `test-plugin` in session-misc-functions.sh

## Notes

<!-- note-id: unu0sh2t -->
<!-- timestamp: 2026-03-18T23:11:05Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

COMPLEXITY_CLASSIFICATION: COMPLEX
