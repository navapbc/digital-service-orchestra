---
id: w22-7jyn
status: closed
deps: []
links: []
created: 2026-03-21T16:29:32Z
type: bug
priority: 1
assignee: Joe Oakhart
---
# Bug: CI Script Tests — 2 failures (test-doc-migration legacy ref, test-ticket-comment ordering)


## Notes

**2026-03-21T16:29:41Z**

CI run 23383713866 on commit 38b7e98 (main). Script Tests job failed with 2 failures:

1. test-doc-migration.sh: test_no_legacy_plugin_root_refs — expected 0 legacy refs, found 1. Likely a new file introduced a reference to a deprecated plugin root path pattern.

2. test-ticket-comment.sh: 'reducer shows both comments in order' — expected OK, got WRONG_FIRST:'second comment'. Comment ordering issue in the ticket comment reducer — second comment appears where first should be.

**2026-03-21T16:36:40Z**

Fixed: (1) legacy CLAUDE_PLUGIN_ROOT ref in resolve-conflicts/SKILL.md, (2) ticket-comment.sh timestamp collision via time.time_ns(). Commit 0385456.
