---
id: w21-v1vi
status: closed
deps: []
links: []
created: 2026-03-19T20:20:33Z
type: bug
priority: 3
assignee: Joe Oakhart
---
# End-session worktree cleanup fails when tk has uncommitted changes

## Bug

/dso:end-session completed but the worktree worktree-20260318-181835 was not automatically removed. The _offer_worktree_cleanup guard requires git status --porcelain to be empty (is_clean), but the worktree had a dirty file.

## Worktree State at Discovery

- Branch: worktree-20260318-181835 at 380c367 (same as main — is_merged passes)
- Status: M plugins/dso/scripts/tk — one uncommitted modification
- Diff: In cmd_sync(), line 5146 changed local _read_config="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}/scripts/read-config.sh" to local _read_config="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/read-config.sh" — removing the CLAUDE_PLUGIN_ROOT env var fallback. This appears to be a debug artifact, not an intentional change.

## Root Cause Hypothesis

The tk script was modified during the session (likely during debugging or a fix attempt) but the change was never staged or committed. /dso:end-session committed all intentional work and merged to main, but this leftover modification made is_clean fail, blocking automatic worktree removal. The session ended without surfacing that the worktree could not be cleaned up.

## Expected Behavior

End-session should either:
1. Detect and warn about uncommitted changes that will block worktree cleanup, giving the user a chance to commit or discard them, OR
2. After merge to main succeeds, offer to discard remaining uncommitted changes so the worktree can be removed

## Acceptance Criteria

- End-session surfaces uncommitted-change blockers before declaring session complete
- User gets explicit choice to discard or commit remaining changes
- Worktree is not left orphaned after a successful end-session

