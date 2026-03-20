---
id: w21-up9s
status: open
deps: []
links: []
created: 2026-03-20T00:51:29Z
type: task
priority: 1
assignee: Joe Oakhart
parent: dso-jvjw
---
# RED: Write failing tests for CI workflow guard analysis integration

Write failing (RED) tests in tests/scripts/test-dso-setup.sh covering CI workflow guard analysis behavior:

1. When a CI workflow file already exists under .github/workflows/ (any name, not just ci.yml), dso-setup.sh does NOT copy examples/ci.example.yml
2. When the detection output (from dso-r2es) indicates CI guards are present (e.g., 'ci.has_lint_guard=true'), dso-setup.sh does not offer to add the lint guard
3. When the detection output indicates a guard is MISSING (e.g., 'ci.has_test_guard=false'), dso-setup.sh outputs a message indicating the missing guard was detected
4. The guard analysis consumes dso-r2es detection output (key=value pairs from project-detect.sh) rather than re-parsing workflow YAML
5. In --dryrun mode, the CI guard analysis output is shown but no files are modified
6. When NO CI workflow exists, ci.example.yml is still copied to .github/workflows/ci.yml (existing behavior preserved)

TDD Requirement: All new test functions must FAIL (RED) against current dso-setup.sh.

Test approach: pass detection output as env vars or a temp file; use mktemp to create fake .github/workflows/ directories with fixture CI YAML.

## Acceptance Criteria

- [ ] bash tests/run-all.sh passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && bash tests/run-all.sh
- [ ] tests/scripts/test-dso-setup.sh contains at least 5 new test functions covering CI guard analysis
  Verify: grep -c 'test_.*ci.*guard\|test_.*guard.*ci\|test_.*ci.*workflow\|test_.*workflow.*guard' $(git rev-parse --show-toplevel)/tests/scripts/test-dso-setup.sh | awk '{exit ($1 < 5)}'
- [ ] All new CI guard test functions FAIL against current dso-setup.sh (RED confirmed)
  Verify: bash $(git rev-parse --show-toplevel)/tests/scripts/test-dso-setup.sh 2>&1 | grep -q 'FAIL'


