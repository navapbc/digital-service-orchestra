---
id: w21-ycsr
status: closed
deps: [w21-v1vi]
links: []
created: 2026-03-19T20:36:52Z
type: epic
priority: 2
assignee: Joe Oakhart
---
# Harden ticket deduplication and archive child protection


## Notes

**2026-03-19T20:37:02Z**

## Context
DSO developers using tk sync experienced 16 duplicate orphan stories created in a single sync run (commit 437c5d4) because the sync ledger (.sync-state.json) was missing entries for existing local tickets, causing pull logic to treat incoming Jira issues as new. Separately, archive-closed-tickets.sh archived epic dso-fel5 despite it having open children, because its protection logic walks only the deps graph and does not check the parent field. Together these left 16 parentless duplicate stories requiring manual investigation and cleanup. This epic adds defense-in-depth dedup checks (index-based title matching on tk create, frontmatter scan + title fallback on sync pull) and extends the archive protection to parent-child relationships.

## Success Criteria
1. tk create fails with a non-zero exit code and an error message naming the conflicting ticket ID when a ticket with an identical title already exists (lookup via .tickets/.index.json)
2. tk sync pull skips creating a local ticket when one with the same jira_key already exists in any ticket's frontmatter (regardless of ledger state), printing a warning to stderr that names both the Jira key and the existing local ticket ID
3. tk sync pull skips creating a local ticket when one with the same title already exists locally, printing a warning to stderr — checked after criterion 2's jira_key check
4. Running tk sync twice in succession with no Jira-side changes produces identical local state — no new tickets created on the second run
5. archive-closed-tickets.sh does not archive a closed epic when any ticket's parent field references that epic and the child's status is open or in_progress; the skip is logged to stderr with the list of blocking child IDs

## Dependencies
None

## Approach
Defense-in-depth: add title-match guard to tk create (via .index.json), add frontmatter jira_key scan + title fallback to sync pull, and extend archive protection to walk parent-child relationships in addition to deps.

## Precondition
The 16 existing orphan duplicates must be deleted before implementation begins.
