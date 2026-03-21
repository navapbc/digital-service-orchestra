---
id: w21-ouns
status: closed
deps: []
links: []
created: 2026-03-19T18:11:59Z
type: bug
priority: 2
assignee: Joe Oakhart
parent: dso-9xnr
---
# fix: test-isolation rule no-script-dir-write misses variable aliases like FIXTURES_DIR derived from SCRIPT_DIR


## Notes

**2026-03-19T18:12:11Z**

The no-script-dir-write isolation rule only checks for literal $SCRIPT_DIR/ in write commands. It misses indirect writes through derived variables like FIXTURES_DIR="$SCRIPT_DIR/fixtures/...". Also, $REPO_ROOT writes are explicitly excluded ('too many legitimate reads') but test-record-review-crossval.sh writes sentinel files to REPO_ROOT. Two fixes needed: (1) trace variable assignments that derive from SCRIPT_DIR and flag writes through those aliases, (2) consider a narrower REPO_ROOT write rule that catches touch/mkdir/redirect to REPO_ROOT but not reads.

<!-- note-id: uo4wsqnz -->
<!-- timestamp: 2026-03-21T01:36:46Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CLOSE REASON: Fixed: isolation rule alias detection + tests (commit c25c396)
