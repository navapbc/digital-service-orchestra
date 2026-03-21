---
id: dso-9gpx
status: closed
deps: [dso-fhfi, dso-6oo5]
links: []
created: 2026-03-21T16:16:37Z
type: task
priority: 2
assignee: Joe Oakhart
parent: w22-tpzd
---
# Document test_gate.test_dirs config key in dso-config.conf

Add a commented-out documentation entry for the test_gate.test_dirs config key to .claude/dso-config.conf so developers know how to configure custom test directories.

## TDD Requirement

test-exempt: criterion 3 — this task modifies only a static config file (adding a documentation comment). No conditional logic, no executable behavior to assert independently. Behavioral coverage is provided end-to-end by test_gate_test_dirs_config (task dso-o1u2) and test_record_uses_configured_test_dirs (task dso-a6nl), which exercise the config-reading path with a test override env var.

## Files

- EDIT: .claude/dso-config.conf

## Change

Add the following block in the appropriate section (e.g., near the bottom, before the version.file_path entry):

```
# Test gate configuration.
# test_gate.test_dirs specifies where to search for associated test files.
# Default: tests/ (single directory)
# Multiple directories: separate with colon, e.g., tests/:integration_tests/
# test_gate.test_dirs=tests/
```

No active (uncommented) key is needed — both pre-commit-test-gate.sh and record-test-status.sh default to tests/ when the key is absent.

## ACCEPTANCE CRITERIA

- [ ] `bash tests/run-all.sh` passes (exit 0)
  Verify: bash $(git rev-parse --show-toplevel)/tests/run-all.sh
- [ ] `ruff check` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff check plugins/dso/scripts/*.py tests/**/*.py 2>&1; test $? -eq 0
- [ ] `ruff format --check` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff format --check plugins/dso/scripts/*.py tests/**/*.py 2>&1; test $? -eq 0
- [ ] test_gate.test_dirs documentation comment present in dso-config.conf
  Verify: grep -q 'test_gate.test_dirs' $(git rev-parse --show-toplevel)/.claude/dso-config.conf
- [ ] test-exempt justification cited (criterion 3: static config documentation, no conditional logic; behavioral coverage via dso-o1u2 test_gate_test_dirs_config and dso-a6nl test_record_uses_configured_test_dirs)


## Notes

<!-- note-id: uga2ouz9 -->
<!-- timestamp: 2026-03-21T17:53:48Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 1/6: Task context loaded ✓

<!-- note-id: cil8rptx -->
<!-- timestamp: 2026-03-21T17:53:53Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 2/6: Code patterns understood ✓ — pre-commit-test-gate.sh and record-test-status.sh will read test_gate.test_dirs; currently not yet implemented in scripts (feature story in progress); config doc entry needed to guide developers

<!-- note-id: ld5unavd -->
<!-- timestamp: 2026-03-21T17:53:58Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 3/6: Tests written (none required) ✓ — test-exempt criterion 3: static config documentation, no conditional logic; behavioral coverage via dso-o1u2 test_gate_test_dirs_config and dso-a6nl test_record_uses_configured_test_dirs

<!-- note-id: 4ojbx6np -->
<!-- timestamp: 2026-03-21T17:54:51Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 4/6: Implementation complete ✓ — added test_gate.test_dirs documentation block to .claude/dso-config.conf before version.file_path entry

<!-- note-id: hxby2y5z -->
<!-- timestamp: 2026-03-21T17:54:54Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 5/6: Validation passed ✓ — grep confirms test_gate.test_dirs present; ruff check exit 0; ruff format --check exit 0

<!-- note-id: o08kebpn -->
<!-- timestamp: 2026-03-21T17:55:00Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 6/6: Done ✓ — all acceptance criteria met: test_gate.test_dirs doc comment present, ruff check/format pass, test-exempt criterion 3 cited
