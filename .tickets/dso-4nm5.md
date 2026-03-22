---
id: dso-4nm5
status: in_progress
deps: []
links: []
created: 2026-03-21T16:53:15Z
type: bug
priority: 4
assignee: Joe Oakhart
---
# Fix: fuzzy-match RED-phase counter swap fragility in test-fuzzy-match.sh


## Notes

**2026-03-22T16:23:48Z**

Classification: behavioral, Score: 1 (BASIC). Root cause: RED-phase counter swap at line 288 uses PASS=$FAIL instead of PASS=$(( PASS + FAIL )), meaning if PASS is non-zero when entering the RED block (e.g., a future test without the _FUZZY_MATCH_LOADED guard passes in RED phase), the real PASS count is silently discarded. Fix: change line 288 from PASS=$FAIL to PASS=$(( PASS + FAIL )).
