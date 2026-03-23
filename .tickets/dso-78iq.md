---
id: dso-78iq
status: closed
deps: [w21-wbqz]
links: []
created: 2026-03-22T16:05:49Z
type: story
priority: 1
assignee: Joe Oakhart
parent: w21-24kl
---
# As a developer, commits to reviewable files require a valid v3 ticket reference

See ticket notes for full story body.


## Notes

<!-- note-id: 75b8bqal -->
<!-- timestamp: 2026-03-22T16:06:00Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

## Description

**What**: A commit-msg stage pre-commit hook (pre-commit-ticket-gate.sh) that blocks commits lacking a valid v3 ticket ID in the commit message.
**Why**: Completes the v3 migration by enforcing that all future reviewable commits are traceable through the new ticket system. Without this gate, the migration is technically complete but practically unenforced.
**Scope**:
- IN: commit-msg hook implementation, v3 format regex (XXXX-XXXX hex), directory + CREATE event existence check, review-gate-allowlist.conf loading (skip when all staged files match), merge commit exemption (MERGE_HEAD), error output with format hint and ticket creation pointer, pre-commit-config.example.yaml entry, dso-setup.sh hook registration, project-setup skill registration, graceful degradation if v3 tracker not mounted
- OUT: Modifications to shared gate infrastructure (allowlist, sentinel, wrapper), old-format ID support (v3 only)

## Done Definitions

- When this story is complete, a commit touching any file not in the review-gate-allowlist is blocked unless the commit message contains at least one valid v3 ticket ID (XXXX-XXXX hex format, confirmed to exist via directory + CREATE event check). Satisfies SC9.
- When this story is complete, commits where all staged files match review-gate-allowlist.conf exit 0 without blocking. Satisfies SC9.
- When this story is complete, merge commits (MERGE_HEAD present) are unconditionally exempt from the gate. Satisfies SC9.
- When this story is complete, the hooks error output displays the expected ID format and how to create a ticket. Satisfies SC9.
- When this story is complete, pre-commit-config.example.yaml contains the ticket gate hook entry and dso-setup.sh / project-setup registers it during onboarding. Satisfies SC9.
- When this story is complete, if the v3 tracker is not mounted, the hook skips with a warning rather than hard-failing. Satisfies Risk Register 1.
- Unit tests written and passing for all new or modified logic.

## Considerations

- [Reliability] v3 storage must be queryable at commit time — hook needs graceful degradation if tracker worktree is not mounted
- [Testing] New hook needs test file following established pattern — test both blocking and skip paths
- [Maintainability] Reference update story (w21-wbqz) enumerated patterns should be aware of this hooks files, though this story contains no tk references to update
