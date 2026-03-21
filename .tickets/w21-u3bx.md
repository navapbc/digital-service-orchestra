---
id: w21-u3bx
status: open
deps: []
links: []
created: 2026-03-21T03:11:42Z
type: bug
priority: 2
assignee: Joe Oakhart
parent: dso-9xnr
---
# Bug: bump-version.sh should sync from main before bumping to avoid version conflicts

bump-version.sh increments the version file without first pulling the latest version from main. In a worktree workflow, another session may have already bumped the version on main. Without syncing first, the next merge will produce a conflict on the version file, or worse, regress the version number. Fix: add a git fetch + read of the version file on main before incrementing. If main's version is higher than the local version, use main's as the base for the increment.

