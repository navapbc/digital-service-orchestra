---
id: dso-xrna
status: closed
deps: []
links: []
created: 2026-03-22T21:45:07Z
type: bug
priority: 1
assignee: Joe Oakhart
parent: w22-ns6l
---
# ci-generator tests fail in CI but pass locally (36 failures)

All 36 failures are in ci-generator test files (test-ci-generator.sh, test-ci-generator-integration.sh, test-ci-generator-dogfooding.sh). Tests pass locally (2550/2550) but fail in CI (2488 pass, 36 fail). Likely environment difference - actionlint or yaml validation tool availability on CI runner.


## Notes

<!-- note-id: fwnrnmxr -->
<!-- timestamp: 2026-03-22T22:19:06Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

Fixed: validate_yaml() graceful degradation + pyyaml in CI deps

<!-- note-id: 70ydb96f -->
<!-- timestamp: 2026-03-22T22:19:06Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CLOSE REASON: Fixed: ci-generator.sh validate_yaml graceful degradation when no validator available
