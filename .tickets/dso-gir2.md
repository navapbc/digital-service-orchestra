---
id: dso-gir2
status: in_progress
deps: []
links: []
created: 2026-03-19T18:21:27Z
type: bug
priority: 2
assignee: Joe Oakhart
jira_key: DIG-60
parent: dso-9xnr
---
# Fix: qualify-skill-refs.sh multi-segment URL lookbehind gap — checker strips full URLs but fixer only checks :// prefix


## Notes

<!-- note-id: 4nkmam4n -->
<!-- timestamp: 2026-03-21T00:44:49Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

Classification: behavioral, Score: 2 (BASIC). Root cause: qualify-skill-refs.sh lookbehind (?<![a-zA-Z0-9_/]) does not include hyphen or dot, so URL path segments like foo--/sprint could be incorrectly rewritten. Fix: replaced single-arm regex with URL-aware alternation that matches full URLs first (kept unchanged) then unqualified skill refs. RED test added in tests/scripts/test-qualify-skill-refs.sh (test_skips_multi_segment_url).
