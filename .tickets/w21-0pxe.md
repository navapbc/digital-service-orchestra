---
id: w21-0pxe
status: in_progress
deps: []
links: []
created: 2026-03-21T00:15:37Z
type: bug
priority: 1
assignee: Joe Oakhart
parent: w22-ns6l
---
# Bug: end-session merge blindly accepts worktree ticket changes over main without diff comparison


## Notes

**2026-03-21T00:15:53Z**

During end-session merge, the agent encountered a conflict in .tickets/dso-dywv.md between main and the worktree. Rather than comparing the two versions to determine which had better content, the agent ASSUMED its own version was correct and used git merge -X ours. From the session log: "The working tree is clean — the merge attempt fails during git merge but is cleaned up. The issue is that main has a different version of dso-dywv.md (likely without our description additions). Let me resolve this by accepting our version."

This is dangerous because: (1) main may have received updates from another worktree that the current session does not know about, (2) the agent should have compared both versions and presented the conflict to the user for resolution, (3) using -X ours for ticket files discards any content added on main by other sessions.

Expected behavior: When ticket merge conflicts occur during end-session, the agent should show the diff between both versions and ask the user which to keep, or present a merged version for approval. The agent should never assume its own ticket changes are authoritative without comparison.
