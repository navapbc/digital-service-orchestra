---
id: dso-l24u
status: closed
deps: [dso-guxa]
links: []
created: 2026-03-18T22:59:00Z
type: story
priority: 1
assignee: Joe Oakhart
parent: dso-p2d3
---
# As a developer, the plugin test detection script and its test suite are retired


## What
Delete `check-plugin-test-needed.sh` (the script that detects whether plugin tests should run) and delete its entire test file `test-check-plugin-test-needed.sh` (which tests both the script and asserts COMMIT-WORKFLOW.md has Step 1.75 — both of which are removed by story dso-guxa).

## Why
With Step 1.75 removed from COMMIT-WORKFLOW.md and the plugin test infrastructure gone, `check-plugin-test-needed.sh` has no purpose. Its test file `test-check-plugin-test-needed.sh` tests a deleted script and checks for a now-absent COMMIT-WORKFLOW.md step — leaving it causes test failures.

## Scope

IN:
- Delete `plugins/dso/scripts/check-plugin-test-needed.sh`
- Delete `tests/scripts/test-check-plugin-test-needed.sh` (entire file — not just one test)

OUT: validate.sh changes (dso-guxa), updating commands.test_unit (S3 story), documentation (SD story)

## Done Definitions

- When this story is complete, `check-plugin-test-needed.sh` no longer exists in `plugins/dso/scripts/`
  ← Satisfies: "Remove plugin testing as a separate step"
- When this story is complete, `test-check-plugin-test-needed.sh` no longer exists in `tests/scripts/`
  ← Satisfies: "Remove plugin testing as a separate step"
- When this story is complete, `bash tests/run-all.sh` passes (no broken test file for deleted script)
  ← Satisfies: "Remove plugin testing as a separate step"

## Considerations
- [Maintainability] The entire test file should be deleted — not surgically edited — because all tests reference the deleted script or Step 1.75

## Notes

<!-- note-id: 0gnd3286 -->
<!-- timestamp: 2026-03-18T23:08:10Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CLOSE REASON: Scope removed: user direction is to keep all test files; test updates folded into dso-guxa
