---
id: dso-2dxt
status: open
deps: []
links: []
created: 2026-03-21T20:32:23Z
type: task
priority: 2
assignee: Joe Oakhart
---
# bug LINK/UNLINK same-second timestamp ordering causes unlink to be ignored


## Notes

<!-- note-id: 25ajfem2 -->
<!-- timestamp: 2026-03-21T20:32:35Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

Discovered in test-ticket-dependency-e2e.sh (dso-ofdp). When ticket-graph.py writes a LINK event and ticket-link.sh writes an UNLINK event in the same Unix second (int(time.time())), the filename sort order is {timestamp}-{uuid}-LINK.json vs {timestamp}-{uuid}-UNLINK.json. Since UUIDs are random, the UNLINK can sort before the LINK alphabetically, causing the event replay in _is_duplicate_link and _find_direct_blockers to treat the link as still active. Fix: use millisecond timestamps or add a tie-breaker suffix to guarantee UNLINK always sorts after LINK in the same second.
