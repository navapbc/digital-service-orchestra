---
id: dso-xrna
status: in_progress
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

