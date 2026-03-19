---
id: dso-4clm
status: closed
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

## Notes

<!-- note-id: q56vje2f -->
<!-- timestamp: 2026-03-19T00:01:28Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 1/6: Task context loaded ✓

<!-- note-id: j6oxu3rx -->
<!-- timestamp: 2026-03-19T00:01:32Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 2/6: Code patterns understood ✓

<!-- note-id: y0k9y5pg -->
<!-- timestamp: 2026-03-19T00:01:49Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 3/6: Tests written ✓

<!-- note-id: z1iafeo4 -->
<!-- timestamp: 2026-03-19T00:01:58Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 4/6: Implementation complete ✓

<!-- note-id: 99ke4okh -->
<!-- timestamp: 2026-03-19T00:04:05Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 5/6: Validation passed ✓

<!-- note-id: 1beiseov -->
<!-- timestamp: 2026-03-19T00:04:05Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 6/6: Done ✓

<!-- note-id: 1wd1e2ng -->
<!-- timestamp: 2026-03-19T00:05:30Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 6/6: Done ✓ — Files: validate-config.sh, test-validate-config.sh. Tests: 2620 pass.

<!-- note-id: ry66a16z -->
<!-- timestamp: 2026-03-19T00:05:30Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CLOSE REASON: Fixed: removed commands.test_plugin from validate-config.sh KNOWN_KEYS; added regression test
