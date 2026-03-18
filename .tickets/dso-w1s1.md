---
id: dso-w1s1
status: closed
deps: [dso-60hd]
links: []
created: 2026-03-18T01:21:43Z
type: feature
priority: 2
assignee: Joe Oakhart
parent: dso-8qvu
---
# As a DSO plugin maintainer, I can bulk-qualify all unqualified skill references and integrate the linter into CI


## Notes

**2026-03-18T01:22:16Z**


**What**: Create `scripts/qualify-skill-refs.sh` that bulk-replaces all unqualified refs with /dso: equivalents across the in-scope file set, then run it on the actual codebase. Also integrate `check-skill-refs.sh` as a fatal check in `scripts/validate.sh`.

**Why**: The linter (dso-60hd) proves the concept; this story executes the transformation and locks in the regression guard. The validate.sh integration is placed here (not in dso-60hd) because the fatal check can only be activated after the bulk replace clears all ~270 existing refs.

**Scope**:
- IN: scripts/qualify-skill-refs.sh, execution on the actual codebase, scripts/validate.sh fatal integration
- OUT: the linter script and test suite (dso-60hd)

**Depends on**: dso-60hd

**Done Definitions**:
- When this story is complete, running qualify-skill-refs.sh followed by check-skill-refs.sh exits 0 on all in-scope files
  ← Satisfies: "After running qualify-skill-refs.sh, check-skill-refs.sh exits 0 on all in-scope files"
- When this story is complete, running qualify-skill-refs.sh twice on the codebase produces no additional changes
  ← Satisfies: rewriter idempotency requirement
- When this story is complete, check-skill-refs.sh is invoked unconditionally in scripts/validate.sh; running validate.sh --ci fails if any in-scope file has an unqualified ref
  ← Satisfies: "check-skill-refs.sh integrated into validate.sh as a fatal check"
- When this story is complete, a first-time DSO contributor can identify skill ownership in skills/, docs/, or commands/ by reading the call site alone
  ← Satisfies: "first-time contributor can identify skill ownership without consulting a registry"

**Considerations**:
- [Reliability] Bulk rewriter modifies 60+ files — verify git state is clean and committed before running to ensure reversibility
- [Testing] Verify whole-word-match regex against edge cases before executing on the real codebase
- [Consistency] qualify-skill-refs.sh must operate on the same hardcoded file set as check-skill-refs.sh (skills/, docs/, hooks/, commands/ recursively + CLAUDE.md)
- [Semantics] CLAUDE.md uses both /sprint (alias form) and /dso:sprint (qualified form) in agent instructions — decide whether to rewrite CLAUDE.md refs or handle them specially before executing the bulk replace


<!-- note-id: qumczs1e -->
<!-- timestamp: 2026-03-18T02:41:38Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CLOSE REASON: Superseded by dso-0isl (richer story with done definitions, AC, considerations)
