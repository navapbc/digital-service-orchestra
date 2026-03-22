---
id: dso-2dxt
status: in_progress
deps: []
links: []
created: 2026-03-21T20:32:23Z
type: task
priority: 2
assignee: Joe Oakhart
parent: w22-ns6l
---
# bug LINK/UNLINK same-second timestamp ordering causes unlink to be ignored


## Notes

<!-- note-id: 25ajfem2 -->
<!-- timestamp: 2026-03-21T20:32:35Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

Discovered in test-ticket-dependency-e2e.sh (dso-ofdp). When ticket-graph.py writes a LINK event and ticket-link.sh writes an UNLINK event in the same Unix second (int(time.time())), the filename sort order is {timestamp}-{uuid}-LINK.json vs {timestamp}-{uuid}-UNLINK.json. Since UUIDs are random, the UNLINK can sort before the LINK alphabetically, causing the event replay in _is_duplicate_link and _find_direct_blockers to treat the link as still active. Fix: use millisecond timestamps or add a tie-breaker suffix to guarantee UNLINK always sorts after LINK in the same second.

**2026-03-22T00:35:13Z**

Classification: behavioral, Score: 2 (BASIC). Root cause: event filename sort key used only the full basename, so when LINK and UNLINK events share the same Unix-second timestamp but have different random UUID segments, alphabetical UUID sort could place UNLINK before LINK. Fix: changed sort key to (timestamp_only, event_type_order, full_name) in both _is_duplicate_link and _get_link_info — ensures LINK always replays before UNLINK at same second. Added Test 9 to test-ticket-link.sh to reproduce the bug deterministically using crafted filenames with controlled UUID ordering.
