---
id: dso-gifa
status: open
deps: []
links: []
created: 2026-03-22T22:30:14Z
type: task
priority: 2
assignee: Joe Oakhart
parent: w21-0kt1
---
# RED tests: classifier telemetry writes valid JSONL entry to ARTIFACTS_DIR

Write failing tests for the classifier telemetry behavior in tests/hooks/test-review-complexity-classifier.sh. TDD: tests must be added before any implementation fix; they verify the existing implementation and would fail if the telemetry code were removed. 6 tests to add: (1) test_classifier_telemetry_file_created, (2) test_classifier_telemetry_entry_is_valid_json, (3) test_classifier_telemetry_contains_required_fields (ALL 13 fields: blast_radius, critical_path, anti_shortcut, staleness, cross_cutting, diff_lines, change_volume, computed_total, selected_tier, files, diff_size_lines, size_action, is_merge_commit — the impl already writes all 13), (4) test_classifier_telemetry_factor_scores_match_stdout, (5) test_classifier_telemetry_files_array, (6) test_classifier_no_telemetry_without_artifacts_dir. Append functions to test file; call them in execution section with RED marker comment. .test-index note: test file fuzzy-matches source — no new entry needed.

## ACCEPTANCE CRITERIA

- [ ] tests/hooks/test-review-complexity-classifier.sh contains test_classifier_telemetry_file_created function
  Verify: grep -q 'test_classifier_telemetry_file_created' $(git rev-parse --show-toplevel)/tests/hooks/test-review-complexity-classifier.sh
- [ ] tests/hooks/test-review-complexity-classifier.sh contains test_classifier_telemetry_entry_is_valid_json function
  Verify: grep -q 'test_classifier_telemetry_entry_is_valid_json' $(git rev-parse --show-toplevel)/tests/hooks/test-review-complexity-classifier.sh
- [ ] tests/hooks/test-review-complexity-classifier.sh contains test_classifier_telemetry_contains_required_fields function (verifies ALL 13 fields: blast_radius, critical_path, anti_shortcut, staleness, cross_cutting, diff_lines, change_volume, computed_total, selected_tier, files, diff_size_lines, size_action, is_merge_commit)
  Verify: grep -q 'test_classifier_telemetry_contains_required_fields' $(git rev-parse --show-toplevel)/tests/hooks/test-review-complexity-classifier.sh
- [ ] tests/hooks/test-review-complexity-classifier.sh contains test_classifier_telemetry_factor_scores_match_stdout function
  Verify: grep -q 'test_classifier_telemetry_factor_scores_match_stdout' $(git rev-parse --show-toplevel)/tests/hooks/test-review-complexity-classifier.sh
- [ ] tests/hooks/test-review-complexity-classifier.sh contains test_classifier_telemetry_files_array function
  Verify: grep -q 'test_classifier_telemetry_files_array' $(git rev-parse --show-toplevel)/tests/hooks/test-review-complexity-classifier.sh
- [ ] tests/hooks/test-review-complexity-classifier.sh contains test_classifier_no_telemetry_without_artifacts_dir function
  Verify: grep -q 'test_classifier_no_telemetry_without_artifacts_dir' $(git rev-parse --show-toplevel)/tests/hooks/test-review-complexity-classifier.sh
- [ ] All 6 new telemetry test functions are called in the execution section of the test file
  Verify: grep -c 'test_classifier_telemetry\|test_classifier_no_telemetry_without' $(git rev-parse --show-toplevel)/tests/hooks/test-review-complexity-classifier.sh | awk '{exit ($1 < 12)}'
- [ ] RED marker comment present: '# Telemetry tests (RED — w21-0kt1)'
  Verify: grep -q 'Telemetry tests.*RED.*w21-0kt1' $(git rev-parse --show-toplevel)/tests/hooks/test-review-complexity-classifier.sh
- [ ] bash tests/run-all.sh passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && bash tests/run-all.sh
- [ ] ruff check passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff check plugins/dso/scripts/*.py tests/**/*.py
- [ ] ruff format --check passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff format --check plugins/dso/scripts/*.py tests/**/*.py

