---
id: w22-g4ao
status: closed
deps: []
links: []
created: 2026-03-22T07:50:28Z
type: bug
priority: 2
assignee: Joe Oakhart
parent: w22-ns6l
---
# Bug: test-check-script-writes.sh flakes in full suite (shfmt availability race)

test-check-script-writes.sh fails 2 out of 5 times in the full suite (tests/run-all.sh parallel execution) but passes individually (5/0 with skips). Root cause candidate: shfmt availability race during parallel test execution.


## Notes

**2026-03-22T07:51:12Z**

Tier 7: assigned for Project Health Restoration epic w22-ns6l triage.

<!-- note-id: 0ioybppm -->
<!-- timestamp: 2026-03-22T22:21:36Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

Classification: behavioral, Score: 4 (medium severity + moderate complexity + 2 for parallel race). Root cause: test_no_shfmt_skips_gracefully references ${CLAUDE_PLUGIN_ROOT} with set -uo pipefail active, but CLAUDE_PLUGIN_ROOT is set by parent runners and not always available in parallel execution (e.g., direct invocation or race). Fix: replace ${CLAUDE_PLUGIN_ROOT} with $DSO_PLUGIN_DIR which is computed locally from SCRIPT_DIR and is always available.

<!-- note-id: c9nteb70 -->
<!-- timestamp: 2026-03-22T22:34:10Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CLOSE REASON: Fixed: replaced ${CLAUDE_PLUGIN_ROOT} with $DSO_PLUGIN_DIR in test_no_shfmt_skips_gracefully (tests/scripts/test-check-script-writes.sh line 59)

<!-- note-id: dwzy3tst -->
<!-- timestamp: 2026-03-22T22:36:47Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

Fixed: replaced CLAUDE_PLUGIN_ROOT with DSO_PLUGIN_DIR in test

<!-- note-id: 2owfakre -->
<!-- timestamp: 2026-03-22T22:36:48Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CLOSE REASON: Fixed: replaced unbound CLAUDE_PLUGIN_ROOT with local DSO_PLUGIN_DIR
