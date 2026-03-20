---
id: dso-7w58
status: closed
deps: []
links: []
created: 2026-03-20T17:15:31Z
type: bug
priority: 3
assignee: Joe Oakhart
---
# tk create silently ignores unsupported CLI flags, producing incomplete tickets

## Bug Description

`tk create` does not support `--type`, `--title`, `--priority`, or `--body` flags, but when passed these flags it exits with code 1 and the error message `Unknown option: --type=bug` — however by that point it has already generated and written a ticket file with placeholder content ("Untitled", type=task, priority=2).

## Observed Behavior

Running `tk create --type=bug --title="..." --priority=3 --body="..."` resulted in:
1. Exit code 1 with `Unknown option: --type=bug`
2. A ticket file (`dso-cc6a.md`) was created with default/placeholder values (title "Untitled", type "task", priority 2)
3. The index was updated with the placeholder entry

The caller (Claude) assumed the command failed entirely and then manually wrote the ticket file with correct content, but the index retained the stale placeholder data.

## Expected Behavior

Either:
- `tk create` should support `--type`, `--title`, `--priority`, `--body` flags, OR
- `tk create` should validate flags before creating any files — fail fast without side effects

## Root Cause

`tk create` appears to write the ticket file and index entry before parsing/validating all CLI arguments. The error occurs after the file is already created.

## Impact

Tickets created with unsupported flags end up with incorrect metadata. The index gets out of sync with the actual ticket file content if the caller corrects the file manually.
