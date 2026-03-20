---
id: dso-2rgm
status: closed
deps: []
links: []
created: 2026-03-20T18:09:20Z
type: task
priority: 1
assignee: Joe Oakhart
parent: dso-zu4o
---
# RED: Write test asserting CONFIG-RESOLUTION.md matches actual read-config.sh resolution logic

TDD RED phase for dso-zu4o.

Write a new test file tests/scripts/test-config-resolution-doc-accuracy.sh that verifies CONFIG-RESOLUTION.md accurately documents the actual read-config.sh resolution logic.

The test must check that CONFIG-RESOLUTION.md does NOT document a resolution path via ${CLAUDE_PLUGIN_ROOT}/.claude/dso-config.conf (step 1), because read-config.sh removed CLAUDE_PLUGIN_ROOT-based resolution (see comment in scripts/read-config.sh: 'CLAUDE_PLUGIN_ROOT-based resolution removed').

TDD requirement: Write test_config_resolution_doc_no_claude_plugin_root_path that greps CONFIG-RESOLUTION.md and asserts the pattern 'CLAUDE_PLUGIN_ROOT.*dso-config.conf' does NOT appear as a resolution step. Must FAIL (RED) before the doc is corrected.

Follow style of existing tests in tests/scripts/ (test-docs-config-refs.sh, test-doc-migration.sh).

## ACCEPTANCE CRITERIA

- [ ] File `tests/scripts/test-config-resolution-doc-accuracy.sh` exists
  Verify: `test -f tests/scripts/test-config-resolution-doc-accuracy.sh`
- [ ] Test function `test_config_resolution_doc_no_claude_plugin_root_path` is defined
  Verify: `grep -q "test_config_resolution_doc_no_claude_plugin_root_path" tests/scripts/test-config-resolution-doc-accuracy.sh`
- [ ] Test FAILS (RED) when run against current CONFIG-RESOLUTION.md
  Verify: `bash tests/scripts/test-config-resolution-doc-accuracy.sh 2>&1 | grep -q "FAILED: [1-9]"`
- [ ] Test follows existing test style conventions (uses test harness functions)
  Verify: `grep -q "source.*test-harness\|source.*test_helpers\|PASS\|FAIL" tests/scripts/test-config-resolution-doc-accuracy.sh`

## File Impact

### Files to create
- `tests/scripts/test-config-resolution-doc-accuracy.sh`

### Files to read (reference only)
- `plugins/dso/docs/CONFIG-RESOLUTION.md`
- `plugins/dso/scripts/read-config.sh`
- `tests/scripts/test-docs-config-refs.sh` (style reference)

## Notes

**2026-03-20T18:17:47Z**

CHECKPOINT 1/6: Task context loaded ✓

**2026-03-20T18:18:07Z**

CHECKPOINT 2/6: Code patterns understood ✓

**2026-03-20T18:18:31Z**

CHECKPOINT 3/6: Tests written ✓

**2026-03-20T18:18:45Z**

CHECKPOINT 4/6: Implementation complete ✓

**2026-03-20T18:18:58Z**

CHECKPOINT 5/6: Validation passed ✓

**2026-03-20T18:18:58Z**

CHECKPOINT 6/6: Done ✓
