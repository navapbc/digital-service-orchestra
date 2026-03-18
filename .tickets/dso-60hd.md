---
id: dso-60hd
status: closed
deps: []
links: []
created: 2026-03-18T01:21:40Z
type: feature
priority: 2
assignee: Joe Oakhart
parent: dso-8qvu
---
# As a DSO plugin maintainer, I can detect unqualified DSO skill references via check-skill-refs.sh


## Notes

**2026-03-18T01:22:16Z**


**What**: Create `scripts/check-skill-refs.sh` with the canonical 24-skill list and a test suite in `tests/scripts/test-check-skill-refs.sh`.

**Why**: This is the walking skeleton of the epic — the linter provides the validation mechanism that proves the bulk replace (Story dso-w1s1) worked and guards against future regressions.

**Scope**:
- IN: scripts/check-skill-refs.sh, tests/scripts/test-check-skill-refs.sh
- OUT: validate.sh integration (dso-w1s1), the actual bulk replacement (dso-w1s1)

**Done Definitions**:
- When this story is complete, running check-skill-refs.sh on a file containing `/sprint` exits non-zero
  ← Satisfies: "check-skill-refs.sh exits non-zero on unqualified refs to the canonical list"
- When this story is complete, running check-skill-refs.sh on a file containing `/dso:sprint` exits 0
  ← Satisfies: "check-skill-refs.sh exits 0 when all references are qualified"
- When this story is complete, the test suite in tests/scripts/test-check-skill-refs.sh passes three negative cases: URL containing a skill name, already-qualified /dso:sprint reference, and hyphenated token /review-gate
  ← Satisfies: test negative cases success criterion

**Considerations**:
- [Testing] Regex whole-word-match and URL exclusion are complex — ensure edge cases (URLs, code fences, markdown headers, YAML values) are covered by the test suite
- [Maintainability] The canonical 24-skill list will need updating when new skills are added — define the list once (shared sourced file) to keep check-skill-refs.sh and qualify-skill-refs.sh in sync


<!-- note-id: ck2kc1ye -->
<!-- timestamp: 2026-03-18T02:41:38Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CLOSE REASON: Superseded by dso-wo1i (richer story with done definitions, AC, considerations)
