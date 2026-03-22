---
id: dso-qxyd
status: in_progress
deps: [dso-ofdr]
links: []
created: 2026-03-22T15:15:54Z
type: task
priority: 1
assignee: Joe Oakhart
parent: w21-jtkr
---
# RED: Write failing unit tests for review-complexity-classifier.sh

Write all failing unit tests for review-complexity-classifier.sh BEFORE implementation. Every test must be RED (failing) when this task is complete.

## TDD Requirement

Write failing tests first. The classifier script does not exist yet — tests will exit non-zero or produce wrong output, confirming RED state. Run the test file after writing and confirm FAIL output.

## Test File

Create: tests/hooks/test-review-complexity-classifier.sh

Test file basename normalized: 'testreviewcomplexityclassifiersh'
Source basename normalized: 'reviewcomplexityclassifiersh'
Fuzzy match: 'reviewcomplexityclassifiersh' is a substring of 'testreviewcomplexityclassifiersh' ✓ (auto-detected by test gate)

## Test Cases to Write (all RED initially)

### Output schema
- test_classifier_outputs_json_object — run classifier on empty diff, verify output is valid JSON with all required keys
- test_classifier_exits_zero_on_success — verify exit code is 0 on normal operation
- test_classifier_outputs_all_seven_factor_keys — verify JSON contains: blast_radius, critical_path, anti_shortcut, staleness, cross_cutting, diff_lines, change_volume
- test_classifier_outputs_computed_total — verify JSON contains computed_total field (integer)
- test_classifier_outputs_selected_tier — verify JSON contains selected_tier field (light|standard|deep)

### Tier thresholds
- test_classifier_tier_light_score_0_2 — total 0-2 → selected_tier=light
- test_classifier_tier_standard_score_3_6 — total 3-6 → selected_tier=standard
- test_classifier_tier_deep_score_7_plus — total 7+ → selected_tier=deep

### Floor rules (all must test OVERRIDE behavior)
- test_floor_rule_anti_shortcut_forces_standard — diff with noqa comment → minimum selected_tier=standard
- test_floor_rule_critical_path_forces_standard — diff touching auth/security file → minimum selected_tier=standard
- test_floor_rule_safeguard_file_forces_standard — diff touching CLAUDE.md → minimum selected_tier=standard
- test_floor_rule_test_deletion_forces_standard — diff deleting test file without source deletion → minimum selected_tier=standard
- test_floor_rule_exception_broadening_forces_standard — diff with 'catch Exception' → minimum selected_tier=standard

### Behavioral file detection
- test_behavioral_file_gets_full_scoring_weight — behavioral file (e.g., plugins/dso/skills/foo.md) scores same as source code
- test_allowlist_file_exempt_from_scoring — file matching review-gate-allowlist.conf pattern scores 0

### Performance
- test_classifier_completes_in_under_2s — measure wall-clock time, assert <2 seconds

### Exit 144 / failure handling
- test_classifier_stdout_parseable_on_success — stdout is valid JSON on exit 0

## Implementation Notes

- Use REPO_ROOT for all script paths
- Source tests/lib/assert.sh for assert_eq/assert_ne/assert_contains/print_summary
- Use temp directories for test fixtures (diff content)
- Clean up temp dirs in test teardown

## Acceptance Criteria

- [ ] `bash tests/run-all.sh` passes overall (exit 0) — but this specific test file FAILS (RED tests present)
  Verify: REPO_ROOT=$(git rev-parse --show-toplevel) && bash "$REPO_ROOT/plugins/dso/scripts/test-batched.sh" --timeout=50 "bash $REPO_ROOT/tests/hooks/test-review-complexity-classifier.sh 2>&1 | grep -q FAIL"
- [ ] Test file exists and is executable
  Verify: test -x $(git rev-parse --show-toplevel)/tests/hooks/test-review-complexity-classifier.sh
- [ ] All 18+ test cases are present in the file
  Verify: grep -c 'test_classifier\|test_floor_rule\|test_behavioral\|test_allowlist\|test_tier' $(git rev-parse --show-toplevel)/tests/hooks/test-review-complexity-classifier.sh | awk '{exit ($1 >= 18) ? 0 : 1}'
- [ ] Tests fail with expected output (FAIL messages present) when run against missing classifier
  Verify: REPO_ROOT=$(git rev-parse --show-toplevel) && bash "$REPO_ROOT/tests/hooks/test-review-complexity-classifier.sh" 2>&1 | grep -q 'FAIL'


## Notes

**2026-03-22T15:33:29Z**

CHECKPOINT 1/6: Task context loaded ✓

**2026-03-22T15:33:51Z**

CHECKPOINT 2/6: Code patterns understood ✓

**2026-03-22T15:36:13Z**

CHECKPOINT 3/6: Tests written ✓

**2026-03-22T15:36:14Z**

CHECKPOINT 4/6: Implementation complete ✓ (RED tests only)

**2026-03-22T15:36:24Z**

CHECKPOINT 5/6: Validation passed ✓

**2026-03-22T15:36:39Z**

CHECKPOINT 6/6: Done ✓
