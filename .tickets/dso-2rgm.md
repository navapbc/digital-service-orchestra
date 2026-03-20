---
id: dso-2rgm
status: open
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

