---
id: dso-5ewd
status: in_progress
deps: []
links: []
created: 2026-03-20T15:57:21Z
type: task
priority: 2
assignee: Joe Oakhart
parent: dso-bugk
---
# Update hooks files: replace workflow-config.conf references in pre-bash-functions.sh and review-gate-allowlist.conf

Replace references to 'workflow-config.conf' in hooks library files.

Files to update:

1. plugins/dso/hooks/lib/pre-bash-functions.sh (3 occurrences):
   - Line 155: comment 'prefer CLAUDE_PLUGIN_ROOT/workflow-config.conf' → update to '.claude/dso-config.conf'
   - Lines 158-159: functional path check (CRITICAL — this is hook config resolution):
       if [[ -n "${CLAUDE_PLUGIN_ROOT:-}" && -f "${CLAUDE_PLUGIN_ROOT}/workflow-config.conf" ]]; then
           _CT_CONFIG_FILE="${CLAUDE_PLUGIN_ROOT}/workflow-config.conf"
     
     Read context carefully. This may be checking a plugin root path (not git root .claude/) — the new path for hooks may be different. The hook resolves config via the plugin's CLAUDE_PLUGIN_ROOT env var context. Check what dso-uc2d updated for read-config.sh to understand the correct path resolution order, then update consistently.

2. plugins/dso/hooks/lib/review-gate-allowlist.conf (1 occurrence):
   - Line 9: comment reference to 'workflow-config.conf' → update to 'dso-config.conf'

NOTE: The pre-bash-functions.sh change at lines 158-159 is functionally sensitive — it changes where hooks look for config. Read the full context (lines 150-170) and the read-config.sh resolution chain before editing to ensure consistency with dso-uc2d's work.

TDD Requirement: N/A — Unit test exemption applies (all 3 criteria met):
1. No conditional logic added — updating path constants to match new canonical location
2. Any test would be a change-detector test
3. Infrastructure-boundary-only — hook config path wiring

## Acceptance Criteria

- [ ] Zero occurrences of 'workflow-config.conf' in pre-bash-functions.sh
  Verify: test $(grep -c 'workflow-config.conf' $(git rev-parse --show-toplevel)/plugins/dso/hooks/lib/pre-bash-functions.sh) -eq 0
- [ ] Zero occurrences of 'workflow-config.conf' in review-gate-allowlist.conf
  Verify: test $(grep -c 'workflow-config.conf' $(git rev-parse --show-toplevel)/plugins/dso/hooks/lib/review-gate-allowlist.conf) -eq 0
- [ ] pre-bash-functions.sh hook path uses .claude/dso-config.conf
  Verify: grep 'dso-config.conf' $(git rev-parse --show-toplevel)/plugins/dso/hooks/lib/pre-bash-functions.sh | grep -q 'dso-config'


## Notes

<!-- note-id: fwawe8sv -->
<!-- timestamp: 2026-03-20T16:02:33Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 1/6: Task context loaded ✓ — pre-bash-functions.sh has 3 occurrences of workflow-config.conf (lines 155, 158, 159); review-gate-allowlist.conf has 1 occurrence (line 9). read-config.sh uses WORKFLOW_CONFIG_FILE or git-root/.claude/dso-config.conf. auto-format.sh uses CLAUDE_PLUGIN_ROOT/.claude/dso-config.conf pattern.

<!-- note-id: zrn3r6g2 -->
<!-- timestamp: 2026-03-20T16:03:27Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 2/6: Files read — pre-bash-functions.sh and review-gate-allowlist.conf context understood. Resolution pattern follows auto-format.sh (CLAUDE_PLUGIN_ROOT/.claude/dso-config.conf).

<!-- note-id: uqwvi7x9 -->
<!-- timestamp: 2026-03-20T16:03:45Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 3/6: Edits applied ✓ — pre-bash-functions.sh lines 155/158/159 updated to .claude/dso-config.conf; review-gate-allowlist.conf line 9 updated to dso-config.conf. All 3 AC verified.

<!-- note-id: ntqxjef0 -->
<!-- timestamp: 2026-03-20T16:04:22Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 4/6: Tests run — test-config-paths.sh: 19/19 PASS, test-auto-format.sh: 12/12 PASS, test-commit-tracker.sh: 10/11 PASS (1 pre-existing RED-phase failure: test_commit_tracker_config_driven_issue_tracker_search_cmd — hardcoded 'bd search', not related to this task). No regressions introduced.

<!-- note-id: ozy3b6al -->
<!-- timestamp: 2026-03-20T16:04:39Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 5/6: Self-check complete ✓ — diff verified: 3 lines changed in pre-bash-functions.sh (comment + 2 functional lines), 1 line changed in review-gate-allowlist.conf (comment). Zero remaining workflow-config.conf references in both files. No discovered issues.

<!-- note-id: 88psn6zu -->
<!-- timestamp: 2026-03-20T16:04:43Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 6/6: Complete ✓ — All AC satisfied. Ready for commit via /dso:commit.
