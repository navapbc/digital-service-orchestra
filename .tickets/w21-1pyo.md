---
id: w21-1pyo
status: in_progress
deps: []
links: []
created: 2026-03-21T22:02:33Z
type: bug
priority: 4
assignee: Joe Oakhart
parent: w22-ns6l
---
# Bug: test-design-skills-cross-stack.sh arithmetic error from grep -c fallback pattern

grep -c outputs '0' and exits non-zero when no matches. The || echo '0' fallback adds a second '0', causing arithmetic syntax error. Fixed by replacing || echo '0' with || true on all grep -c lines. Pre-existing in 4 locations.


## Notes

**2026-03-22T07:51:12Z**

Tier 7: assigned for Project Health Restoration epic w22-ns6l triage.

<!-- note-id: tpnfzeyn -->
<!-- timestamp: 2026-03-22T15:27:50Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

Investigation: The || echo '0' pattern does not appear in the current tests/skills/test-design-skills-cross-stack.sh. The file uses a different pattern: grep -c ... 2>/dev/null; true) inside subshells, with hardcoded_flask_count=${hardcoded_flask_count:-0} for fallback. All 35 tests pass currently. The current pattern (using ; true inside the subshell + :-0 default) is correct and does not produce arithmetic errors. The bug appears to have been fixed already (never introduced), or the pattern described differs from what's in the file. The file ownership note references tests/scripts/test-design-skills-cross-stack.sh but the file is at tests/skills/. No code changes needed.

<!-- note-id: fcqgq0ex -->
<!-- timestamp: 2026-03-22T15:28:26Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

ESCALATED TO USER: No code change possible — the bug pattern (|| echo '0') does not exist in the codebase. tests/skills/test-design-skills-cross-stack.sh uses the correct pattern (grep -c ... 2>/dev/null; true inside subshell + ${var:-0} fallback) and all 35 tests pass. This ticket was likely created based on an anticipated defect that was never introduced. Recommend closing with reason: 'Ticket describes a defect that was never present in the codebase — the correct pattern was used from initial commit. No fix needed.'

**2026-03-22T15:42:12Z**

Escalated to user: code path is correct — grep -c pattern uses (; true) and ${var:-0}, not the || echo 0 anti-pattern described in the ticket. All 35 tests pass. No fix needed.
