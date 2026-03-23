---
id: dso-1dws
status: closed
deps: [dso-oo92]
links: []
created: 2026-03-22T15:43:45Z
type: task
priority: 2
assignee: Joe Oakhart
parent: w22-ond9
---
# Implement ci-generator.sh: core YAML generation from discovered suites


## Description

Create plugins/dso/scripts/ci-generator.sh that accepts a project-detect.sh --suites JSON array and generates GitHub Actions workflow YAML.

Implementation steps:
1. Accept arguments: --suites-json=<file_or_stdin> --output-dir=<dir> [--non-interactive]
2. Parse the JSON array (using python3 -c or jq-free approach via python3)
3. For each suite:
   - fast suites → ci.yml (on: pull_request)
   - slow suites → ci-slow.yml (on: push to main)
   - unknown suites → if non-interactive: ci-slow.yml; if interactive: prompt user (fast/slow/skip, default slow)
4. Job template per suite:
   - job ID: 'test-' + suite name (e.g., 'unit' → 'test-unit'; sanitize: lowercase, replace non-alphanumeric with '-')
   - steps: checkout (actions/checkout@v4) → run suite command
   - runs-on: ubuntu-latest
5. Command sanitization: strip shell metacharacters from suite commands before embedding in YAML (allowlist: alphanumeric, space, '-', '_', '/', '.', ':', '=')
6. Write to temp path first (validated in Task 4 before final write)
7. Handle edge cases: empty suite list (no files written), all-unknown in non-interactive mode

File: plugins/dso/scripts/ci-generator.sh
Exit codes: 0 success, 1 argument error, 2 YAML validation failure

TDD REQUIREMENT: Depends on dso-oo92 RED tests. All tests in tests/scripts/test-ci-generator.sh must pass GREEN after this task.

## ACCEPTANCE CRITERIA

- [ ] bash tests/run-all.sh passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && bash tests/run-all.sh
- [ ] ruff check passes (exit 0)
  Verify: ruff check plugins/dso/scripts/*.py tests/**/*.py
- [ ] ruff format --check passes (exit 0)
  Verify: ruff format --check plugins/dso/scripts/*.py tests/**/*.py
- [ ] ci-generator.sh exists and is executable
  Verify: test -x $(git rev-parse --show-toplevel)/plugins/dso/scripts/ci-generator.sh
- [ ] Script handles missing arguments (non-zero exit)
  Verify: { $(git rev-parse --show-toplevel)/plugins/dso/scripts/ci-generator.sh 2>/dev/null; test $? -ne 0; }
- [ ] test_generates_ci_yml_for_fast_suites passes
  Verify: cd $(git rev-parse --show-toplevel) && bash tests/scripts/test-ci-generator.sh 2>&1 | grep -q 'PASS.*test_generates_ci_yml_for_fast_suites'
- [ ] test_job_id_derived_from_suite_name passes
  Verify: cd $(git rev-parse --show-toplevel) && bash tests/scripts/test-ci-generator.sh 2>&1 | grep -q 'PASS.*test_job_id_derived_from_suite_name'
- [ ] ci-generator.sh writes final output to --output-dir (temp path is internal; callers see only the final file)
  Verify: OUTPUT=$(mktemp -d) && echo '[{"name":"unit","command":"make test-unit","speed_class":"fast","runner":"make"}]' > /tmp/s.json && bash $(git rev-parse --show-toplevel)/plugins/dso/scripts/ci-generator.sh --suites-json=/tmp/s.json --output-dir=$OUTPUT --non-interactive && test -f $OUTPUT/ci.yml
- [ ] test_empty_suite_list_produces_no_files passes
  Verify: cd $(git rev-parse --show-toplevel) && bash tests/scripts/test-ci-generator.sh 2>&1 | grep -q 'PASS.*test_empty_suite_list'

## Notes

**2026-03-22T16:31:32Z**

CHECKPOINT 1/6: Task context loaded ✓

**2026-03-22T16:31:36Z**

CHECKPOINT 2/6: Code patterns understood ✓

**2026-03-22T16:31:41Z**

CHECKPOINT 3/6: Tests written (RED tests pre-exist) ✓

**2026-03-22T16:32:41Z**

CHECKPOINT 4/6: Implementation complete ✓

**2026-03-22T16:32:53Z**

CHECKPOINT 5/6: Validation passed ✓ — 16 assertions PASSED, 0 FAILED

**2026-03-22T16:37:53Z**

CHECKPOINT 6/6: Done ✓ — All 9 tests PASS, 16 assertions passed. AC verified: executable, missing-args exits non-zero, generates ci.yml/ci-slow.yml correctly, job IDs derived from suite names, empty list produces no files, unknown speed_class defaults to slow in non-interactive mode.

**2026-03-22T16:43:45Z**

CHECKPOINT 6/6: Done ✓ — Files: plugins/dso/scripts/ci-generator.sh. Tests: 16 GREEN.
