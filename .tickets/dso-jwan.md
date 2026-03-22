---
id: dso-jwan
status: in_progress
deps: []
links: []
created: 2026-03-22T15:31:09Z
type: task
priority: 2
assignee: Joe Oakhart
---
# task bug ticket-reducer.py same-second LINK+UNLINK filename sort causes UNLINK to be ignored


## Notes

<!-- note-id: pc85klby -->
<!-- timestamp: 2026-03-22T15:31:18Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

Discovered as the same anti-pattern while fixing dso-2dxt. ticket-reducer.py sorts all event files lexicographically by filename (line 209: sorted(glob.glob(...))). When a LINK and its cancelling UNLINK share the same Unix-second timestamp but have different UUIDs, the UNLINK filename can sort before the LINK filename alphabetically. Since the reducer processes UNLINK first (link_uuid not yet in deps → noop), then LINK (adds dep), the dep appears active in compiled state when it should be cancelled. Fix: same as dso-2dxt — use sort key (timestamp_segment, event_type_order, full_name) so LINK always processes before UNLINK at same second. Note: reducer processes all event types (CREATE, STATUS, COMMENT, LINK, UNLINK) so the fix must be surgical — only applies when comparing same-timestamp LINK vs UNLINK files.
