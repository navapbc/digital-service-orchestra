---
id: dso-n5dr
status: open
deps: []
links: []
created: 2026-03-17T23:48:37Z
type: bug
priority: 2
assignee: Joe Oakhart
---
# Pre-existing hook and script test failures in CI

Hook Tests and Script Tests have been failing in CI for all recent runs on main branch. Failing test files include: test-config-paths.sh (13 failures), test-flat-config-e2e.sh (2 failures), test-pre-commit-wrapper.sh (3 failures), test-read-config-flat.sh (2 failures), test-smoke-test-portable.sh (1 failure), and others. Total: 23 hook failures + 8 script failures. These are pre-existing and unrelated to current sprint work.

