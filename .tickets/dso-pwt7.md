---
id: dso-pwt7
status: open
deps: [dso-0ey5, dso-87p7]
links: []
created: 2026-03-22T15:46:06Z
type: task
priority: 2
assignee: Joe Oakhart
parent: w22-ond9
---
# Integration test: full discover → generate → validate → write workflow for new project


## Description

Write an integration test that exercises the complete workflow: project-detect.sh --suites → ci-generator.sh → YAML validation → written files.

Create tests/scripts/test-ci-generator-integration.sh

Test scenarios:
1. test_full_workflow_makefile_project: create a fixture project with a Makefile containing test-unit and test-e2e targets; run project-detect.sh --suites, pipe to ci-generator.sh; verify ci.yml and ci-slow.yml contain correct jobs
2. test_full_workflow_no_suites_fallback: project with no Makefile/test dirs; project-detect.sh --suites returns empty array; ci-generator.sh exits 0, writes no files
3. test_full_workflow_validation_blocks_write: manually inject malformed YAML into generator's temp path (testing the write guard); verify final output files are NOT written (simulated via mock; or test that the exit code and absence of final file is correct on invalid YAML injection)
4. test_job_ids_unique_per_suite: two suites with different names produce two distinct job IDs in the generated YAML; no job ID collision

File: tests/scripts/test-ci-generator-integration.sh
Sources: tests/lib/assert.sh
Uses fixtures in tests/fixtures/ (create minimal Makefile fixture if needed)

Integration exemption: this test exercises the boundary between project-detect.sh and ci-generator.sh — two scripts that must interoperate. It does not hit external services.

TDD REQUIREMENT: This task depends on dso-0ey5 and dso-87p7 being complete (generator + skill). The integration test documents end-to-end behavior; write it after both components are green. It may be written RED-first against the complete implementation (write test, verify it passes, no separate RED predecessor needed since the components are already tested by T1/T3).
Exemption: integration-exemption-1 — integration surface is covered by unit tests in test-ci-generator.sh from earlier tasks; this test adds end-to-end cross-component coverage that runs after implementation is complete.

test-exempt: integration-exemption-1 — the individual components are unit-tested in dso-oo92 and dso-9mvn; this integration test writes after-the-fact cross-component verification.

## ACCEPTANCE CRITERIA

- [ ] bash tests/run-all.sh passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && bash tests/run-all.sh
- [ ] ruff check passes (exit 0)
  Verify: ruff check plugins/dso/scripts/*.py tests/**/*.py
- [ ] ruff format --check passes (exit 0)
  Verify: ruff format --check plugins/dso/scripts/*.py tests/**/*.py
- [ ] Integration test file exists at tests/scripts/test-ci-generator-integration.sh
  Verify: test -f $(git rev-parse --show-toplevel)/tests/scripts/test-ci-generator-integration.sh
- [ ] Integration test file contains at least 4 test scenarios
  Verify: grep -c 'assert_eq\|assert_pass\|_snapshot_fail' $(git rev-parse --show-toplevel)/tests/scripts/test-ci-generator-integration.sh | awk '{exit ($1 < 4)}'
- [ ] Integration tests pass
  Verify: cd $(git rev-parse --show-toplevel) && bash tests/scripts/test-ci-generator-integration.sh; test $? -eq 0
- [ ] .test-index entry for ci-generator-integration test exists (if fuzzy match would miss it)
  Verify: grep -q 'ci-generator-integration' $(git rev-parse --show-toplevel)/.test-index || bash -c 'echo ci-generator-integrationsh | grep -q cigeneratorintegration && echo fuzzy-ok'
