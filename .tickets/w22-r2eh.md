---
id: w22-r2eh
status: open
deps: []
links: []
created: 2026-03-22T17:44:57Z
type: task
parent: w21-nv42  # As a DSO practitioner, oversized diffs are rejected with actionable guidance
priority: 2
assignee: Joe Oakhart
---
# Write RED tests for classifier diff-size thresholds and merge-commit bypass

Write failing tests in tests/hooks/test-review-complexity-classifier.sh for the diff-size threshold features to be added to review-complexity-classifier.sh.

TDD Requirement: Tests must FAIL before T2 (classifier implementation) and PASS after.

Tests to add (append to end of test file):

1. test_300_line_diff_triggers_model_upgrade: Create synthetic diff with 300+ non-test, non-generated source lines. Assert JSON output contains model_override=opus.

2. test_599_line_diff_no_rejection: Create diff with 599 source lines. Assert size_rejection=false (or absent). Assert model_override=opus (upgrade at 300+).

3. test_600_line_diff_triggers_rejection: Create diff with 600+ source lines. Assert size_rejection=true and rejection_reason contains 'large-diff-splitting-guide'.

4. test_test_only_diff_bypasses_size_limits: Create diff with 600+ lines ALL in test files. Assert size_rejection=false.

5. test_generated_file_bypasses_size_limits: Create diff with 600+ lines in a generated file (migrations/, package-lock.json). Assert size_rejection=false.

6. test_merge_commit_bypasses_size_limits: Simulate MERGE_HEAD presence (env var or fake file). Create diff with 600+ source lines. Assert size_rejection=false.

7. test_rejection_flag_present_in_output: Verify classifier JSON always includes size_rejection and model_override fields regardless of diff size.

File: tests/hooks/test-review-complexity-classifier.sh (append to existing file). Use existing helpers: create_diff_fixture, run_classifier, json_field. RED marker must be added to .test-index for classifier file.


## ACCEPTANCE CRITERIA

- [ ] bash tests/run-all.sh passes (exit 0) after T2 implementation
  Verify: cd $(git rev-parse --show-toplevel) && bash tests/run-all.sh
- [ ] ruff check plugins/dso/scripts/*.py tests/**/*.py passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff check plugins/dso/scripts/*.py tests/**/*.py
- [ ] ruff format --check passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff format --check plugins/dso/scripts/*.py tests/**/*.py
- [ ] tests/hooks/test-review-complexity-classifier.sh contains test_300_line_diff_triggers_model_upgrade
  Verify: grep -q 'test_300_line_diff_triggers_model_upgrade' $(git rev-parse --show-toplevel)/tests/hooks/test-review-complexity-classifier.sh
- [ ] tests/hooks/test-review-complexity-classifier.sh contains test_600_line_diff_triggers_rejection
  Verify: grep -q 'test_600_line_diff_triggers_rejection' $(git rev-parse --show-toplevel)/tests/hooks/test-review-complexity-classifier.sh
- [ ] tests/hooks/test-review-complexity-classifier.sh contains test_merge_commit_bypasses_size_limits
  Verify: grep -q 'test_merge_commit_bypasses_size_limits' $(git rev-parse --show-toplevel)/tests/hooks/test-review-complexity-classifier.sh
- [ ] tests/hooks/test-review-complexity-classifier.sh contains test_test_only_diff_bypasses_size_limits
  Verify: grep -q 'test_test_only_diff_bypasses_size_limits' $(git rev-parse --show-toplevel)/tests/hooks/test-review-complexity-classifier.sh
- [ ] Running tests RED: bash tests/hooks/test-review-complexity-classifier.sh exits non-zero before T2
  Verify: bash $(git rev-parse --show-toplevel)/tests/hooks/test-review-complexity-classifier.sh; [ $? -ne 0 ]
- [ ] THIS TASK adds RED marker to .test-index for review-complexity-classifier.sh: entry must be added in this task before committing (not delegated to T6/w22-jyzk)
  Verify: grep -q 'review-complexity-classifier.sh.*test_300_line_diff_triggers_model_upgrade' $(git rev-parse --show-toplevel)/.test-index
- [ ] .test-index RED marker is present BEFORE committing T1 tests (bootstrap: test gate requires marker to tolerate RED tests)
  Verify: grep 'review-complexity-classifier.sh' $(git rev-parse --show-toplevel)/.test-index | grep -q '\[test_300_line_diff_triggers_model_upgrade\]'
