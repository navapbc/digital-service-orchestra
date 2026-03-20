---
id: dso-ul37
status: closed
deps: []
links: []
created: 2026-03-20T15:59:51Z
type: task
priority: 2
assignee: Joe Oakhart
parent: dso-bugk
---
# Update test fixtures and test scripts: replace workflow-config.conf with dso-config.conf

Update test fixture files and test script references that use the old config filename.

Part A — Test fixture files (rename):
These are actual fixture config files that tests create or reference. They may need to be moved to reflect the new .claude/ path structure, or the test scripts may need to create them at the new path.

Fixture files to rename/update:
- tests/fixtures/validate-work-portability/workflow-config.conf → dso-config.conf (or .claude/dso-config.conf depending on test structure)
- tests/fixtures/lockpick-snapshot/workflow-config.conf → update as needed
- tests/fixtures/minimal-plugin-consumer/workflow-config.conf → update as needed
- tests/fixtures/node-project/workflow-config.conf → update as needed
- tests/fixtures/go-project/workflow-config.conf → update as needed
- tests/fixtures/makefile-project/workflow-config.conf → update as needed
- tests/evals/fixtures/sample-workflow-config.conf → sample-dso-config.conf (or update header comments only)

Part B — Test script in-memory fixture creation:
These scripts create temporary workflow-config.conf files as test fixtures:
- tests/hooks/test-auto-format.sh (4 occurrences) — creates $_PLUGIN_ROOT/workflow-config.conf in tests
- tests/hooks/test-config-paths.sh (4 occurrences) — creates temp workflow-config.conf files
- tests/hooks/test-merge-to-main-portability.sh (9 occurrences) — creates workflow-config.conf in temp dirs
- tests/hooks/test-track-tool-errors.sh (8 occurrences) — creates workflow-config.conf fixtures
- tests/plugin/test-validate-work-portability.sh (3 occurrences) — references fixture files by name
- tests/scripts/test-project-detect.sh (8 occurrences) — creates and checks for workflow-config.conf

Steps:
1. Read each test file to understand context
2. Determine correct new path for each temp fixture (are they checking CLAUDE_PLUGIN_ROOT path or git-root/.claude/ path?)
3. Update fixture creation statements and assertion strings to use new path
4. For test-project-detect.sh: category 8 (files detection) and category 9 (port detection) — update to .claude/dso-config.conf paths
5. For validate-work-portability test: check if FIXTURES_DIR has a workflow-config.conf that must be renamed

NOTE: The story's done-definition grep only covers 'plugins/ CLAUDE.md' — tests/ is not in the grep check. However, for correctness of the test suite after dso-xdd8 changes validate-config.sh and project-detect.sh to look at new paths, test scripts must create fixtures at the new paths.

TDD Requirement: N/A — Unit test exemption applies:
1. No conditional logic added — updating fixture path strings to match new canonical location
2. Change-detector test only
3. Infrastructure-boundary-only — test setup/teardown code

## Acceptance Criteria

- [ ] Zero occurrences of 'workflow-config.conf' in tests/ fixture files and test scripts
  Verify: test $(grep -r 'workflow-config.conf' $(git rev-parse --show-toplevel)/tests/ 2>/dev/null | grep -v 'workflow-config.yaml\|workflow-config-no-staging\|workflow-config-partial\|workflow-config-schema' | wc -l) -eq 0
- [ ] Tests still pass after fixture path updates (run validate-config and project-detect tests)
  Verify: bash $(git rev-parse --show-toplevel)/tests/scripts/test-validate-config.sh 2>&1 | tail -5
- [ ] project-detect tests pass with new fixture paths
  Verify: bash $(git rev-parse --show-toplevel)/tests/scripts/test-project-detect.sh 2>&1 | tail -5


## Notes

<!-- note-id: sn3wlebs -->
<!-- timestamp: 2026-03-20T16:02:00Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 1/6: Task context loaded ✓. Found 50 matches across 10 files in tests/. Key files: test-auto-format.sh, test-auto-format-flat-config.sh, test-commit-tracker.sh, test-config-paths.sh, test-merge-to-main-portability.sh, test-track-tool-errors.sh, test-validate-work-portability.sh, test-merge-to-main-cleanliness.sh, test-verify-baseline-intent-integration.sh, and sample-workflow-config.conf fixture.

<!-- note-id: nr93a4oc -->
<!-- timestamp: 2026-03-20T16:05:50Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 2/6: Analysis complete. Plan: (A) Rename 6 physical fixture files + sample eval fixture. (B) Update 7 test scripts. test-project-detect.sh cat8/9 require project-detect.sh update for tests to pass. test-merge-to-main-portability.sh has pre-existing failures (CLAUDE_PLUGIN_ROOT). test-track-tool-errors.sh, test-commit-tracker.sh, test-merge-to-main-portability.sh, test-merge-to-main-cleanliness.sh, test-verify-baseline-intent-integration.sh use WORKFLOW_CONFIG_FILE env var — just rename temp files.

<!-- note-id: 7vrtt942 -->
<!-- timestamp: 2026-03-20T16:13:25Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 3/6: All workflow-config.conf references updated to dso-config.conf in tests/. Total scope was 39 files (much larger than task description indicated). Also updated project-detect.sh categories 8+9 to look for .claude/dso-config.conf. Physical fixture files renamed. Now running acceptance criteria tests.

<!-- note-id: ryunf95l -->
<!-- timestamp: 2026-03-20T16:13:43Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 4/6: All 3 acceptance criteria verified. test-validate-config.sh: 15/15 PASS. test-project-detect.sh: 77/77 PASS. Zero occurrences of workflow-config.conf in tests/.

<!-- note-id: i1m4xwfz -->
<!-- timestamp: 2026-03-20T16:15:09Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 5/6: All tests verified. test-validate-config.sh 15/15, test-project-detect.sh 77/77, test-read-config.sh 70/70, test-read-config-flat.sh 16/16, test-config-paths.sh 19/19, test-track-tool-errors.sh 21/21, test-auto-format-flat-config.sh 7/7, test-validate-work-portability.sh 54/54, cross-stack tests 4/4 each. All acceptance criteria met.

<!-- note-id: po3eofiq -->
<!-- timestamp: 2026-03-20T16:15:24Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 6/6: Complete. Discovered anti-pattern in plugins/dso/docs/ (CONFIGURATION-REFERENCE.md, MIGRATION-TO-PLUGIN.md, PRE-COMMIT-TIMEOUT-WRAPPER.md) — those are tracked by dso-4ap3 (separate story for plugins/ CLAUDE.md). Also updated project-detect.sh (needed for cat8/9 test correctness). No new bugs introduced — all affected tests pass. Zero workflow-config.conf occurrences in tests/.
