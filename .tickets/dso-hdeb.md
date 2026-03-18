---
id: dso-hdeb
status: closed
deps: []
links: []
created: 2026-03-18T15:46:58Z
type: bug
priority: 2
assignee: Joe Oakhart
---
# pre-compact dedup lock defeated by HEAD change after checkpoint commit

The dedup guard in hooks/pre-compact-checkpoint.sh (lines 101-112) uses git rev-parse HEAD as part of the lockfile key. After the first invocation commits (changing HEAD), its EXIT trap deletes the lockfile. A second invocation then computes a different key (new HEAD), finds no lockfile, and runs again — bypassing the guard.

Root cause: _LOCK_KEY="${_LOCK_HEAD}-${_LOCK_PATH}" where _LOCK_HEAD changes during the hook's own execution due to the checkpoint commit.

Fix: drop HEAD from the key. Use CWD path only (or a constant per-session key) so the lockfile remains stable across the checkpoint commit.

Observed via telemetry: 'committed, committed, skipped' clusters 1 second apart per PreCompact event, caused by double-registration (local .claude-plugin/plugin.json + cached marketplace plugin both registering the same PreCompact handler).

