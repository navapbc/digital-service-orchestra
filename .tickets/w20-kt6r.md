---
id: w20-kt6r
status: open
deps: []
links: []
created: 2026-03-21T16:57:10Z
type: bug
priority: 2
assignee: Joe Oakhart
tags: [infrastructure, lock-management]
---
# Multiple [LOCK] tickets for debug-everything — no cleanup after session ends

## Bug
tk ready shows two separate tickets with [LOCK] debug-everything:
- dso-h04l [P0][in_progress] - [LOCK] debug-everything
- dso-udy1 [P0][in_progress] - [LOCK] debug-everything

This indicates that debug-everything sessions are creating lock tickets but not cleaning them up when the session ends (either normally or via interruption). Multiple stale locks pollute tk ready output and could interfere with future debug-everything runs.

## Expected Behavior
- Only one [LOCK] ticket should exist per active debug-everything session
- Lock tickets should be cleaned up (closed) when the session ends
- Stale locks from interrupted sessions should be detected and cleaned up

## Scope
Investigate the lock creation/cleanup lifecycle in debug-everything and ensure proper cleanup on both normal exit and interruption (SIGURG, context compaction).

