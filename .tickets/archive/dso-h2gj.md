---
id: dso-h2gj
status: closed
deps: [dso-vxsh]
links: []
created: 2026-03-22T02:27:40Z
type: task
priority: 1
assignee: Joe Oakhart
parent: dso-pxos
---
# GREEN: Add rationalized-failures accountability step to end-session SKILL.md

Add Step 2.77 Rationalized Failures Accountability to the end-session skill, and update Step 6 to display results.

File: plugins/dso/skills/end-session/SKILL.md

Add Step 2.77 (after 2.75, before 2.8) with:
- Conversation Context Scan: agent scans conversation for rationalized failures — error output, test failures noted but not fixed, validation issues acknowledged, rationalization phrases ("pre-existing", "infrastructure issue", "known issue", "not related to this session")
- Numbered List: display each failure
- Accountability Questions (interrogative form):
  (a) "Was this failure observed before or after changes were made on this worktree?" — determined by git stash && <test-command> && git stash pop where <test-command> from commands.test via read-config.sh. Reproduces on main = pre-existing.
  (b) "Does a bug ticket already exist for this failure?" — search via tk list --type=bug
- Auto-Create Bug Tickets: for failures without tickets, tk create "<title>" -t bug -p <priority> with description
- Empty Guard: if no rationalized failures found, skip display
- Store as RATIONALIZED_FAILURES_FROM_2_77 for Step 6

Update Step 6 to display rationalized failures list (similar to technical learnings display).

TDD: Task 1 (dso-vxsh) tests turn GREEN after this edit.

test-exempt: static assets only (unit exemption criterion 3) — skill files are interpreted agent guidance, not compiled code. No executable entry point or function signatures testable in isolation. Behavioral verification via dogfooding (epic criterion 5: 80% recall over 10 sessions). Conditional logic structurally tested by test_step_has_empty_guard.

## ACCEPTANCE CRITERIA
- [ ] bash tests/run-all.sh passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && bash tests/run-all.sh
- [ ] Skill file exists
  Verify: test -f $(git rev-parse --show-toplevel)/plugins/dso/skills/end-session/SKILL.md
- [ ] Contains Step 2.77 heading
  Verify: grep -q '2.77' $(git rev-parse --show-toplevel)/plugins/dso/skills/end-session/SKILL.md
- [ ] Contains stored-failures variable
  Verify: grep -q 'RATIONALIZED_FAILURES_FROM_2_77' $(git rev-parse --show-toplevel)/plugins/dso/skills/end-session/SKILL.md
- [ ] Task 1 tests pass GREEN (all 12 assertions)
  Verify: bash $(git rev-parse --show-toplevel)/tests/skills/test-end-session-rationalized-failures.sh


## Notes

<!-- note-id: ag7p0b9g -->
<!-- timestamp: 2026-03-22T08:06:29Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 1/6: Task context loaded ✓

<!-- note-id: xw9xul2z -->
<!-- timestamp: 2026-03-22T08:06:35Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 2/6: Code patterns understood ✓

<!-- note-id: jeq8clrr -->
<!-- timestamp: 2026-03-22T08:06:41Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 3/6: Tests written (none required — RED tests from dso-vxsh) ✓

<!-- note-id: u8tl9d8c -->
<!-- timestamp: 2026-03-22T08:07:14Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 4/6: Implementation complete ✓

<!-- note-id: hkgmzha6 -->
<!-- timestamp: 2026-03-22T08:07:22Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 5/6: Validation passed ✓

<!-- note-id: d6xi7gaj -->
<!-- timestamp: 2026-03-22T08:10:56Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 6/6: Done ✓
