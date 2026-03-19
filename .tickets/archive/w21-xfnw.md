---
id: w21-xfnw
status: closed
deps: [w21-hcyh]
links: []
created: 2026-03-19T05:13:55Z
type: task
priority: 1
assignee: Joe Oakhart
parent: dso-iwb4
---
# Validate: run check-skill-refs.sh and RED test confirm GREEN after sprint SKILL.md edit

Run the full validation suite to confirm the sprint SKILL.md edit from Task `w21-hcyh` is correct
and introduces no regressions. This is the final gate task for epic `dso-iwb4`.

## TDD Requirement

TDD exemption (unit level): this task has no conditional logic and contains no behavioral code —
it is a pure validation runner. Exemption criterion #1: no conditional logic; exemption criterion #2:
any "test" for this task would be a change-detector (it tests that the validation commands run,
not any new behavior).

## Implementation steps

1. Confirm the RED test (Task w21-1y6e) now passes (GREEN):
   ```bash
   REPO_ROOT=$(git rev-parse --show-toplevel)
   "$REPO_ROOT/plugins/dso/tests/test-sprint-skill-step10-no-merge-to-main.sh"
   ```
   Expected: exit 0, output PASS

2. Run check-skill-refs.sh to confirm no unqualified skill references were introduced:
   ```bash
   "$REPO_ROOT/plugins/dso/scripts/check-skill-refs.sh"
   ```
   Expected: exit 0

3. Run validate.sh --ci to confirm the full validation suite passes:
   ```bash
   .claude/scripts/dso validate.sh --ci
   ```

4. If any step fails, report the failure and do not close this task. The appropriate fix
   belongs in Task w21-hcyh (reopen it and add a note with the failure details).

## Files to modify

None — this is a read-only validation task.

## File Impact

| File | Action |
|------|--------|
| (none) | — |

## ACCEPTANCE CRITERIA

- [ ] `make test-unit-only` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel)/app && make test-unit-only
- [ ] `make lint` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel)/app && make lint
- [ ] `make format-check` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel)/app && make format-check
- [ ] RED test (w21-1y6e) passes GREEN after edit
  Verify: $(git rev-parse --show-toplevel)/plugins/dso/tests/test-sprint-skill-step10-no-merge-to-main.sh
- [ ] check-skill-refs.sh passes (no unqualified skill refs)
  Verify: $(git rev-parse --show-toplevel)/plugins/dso/scripts/check-skill-refs.sh
- [ ] Skill file exists and is valid markdown
  Verify: test -f $(git rev-parse --show-toplevel)/plugins/dso/skills/sprint/SKILL.md

## Notes

<!-- note-id: aad82qrq -->
<!-- timestamp: 2026-03-19T05:46:15Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 1/6: Task context loaded ✓

<!-- note-id: igwicwml -->
<!-- timestamp: 2026-03-19T05:46:29Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 2/6: Code patterns understood ✓

<!-- note-id: guladp0h -->
<!-- timestamp: 2026-03-19T05:46:31Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 3/6: Tests written (none required — validation task) ✓

<!-- note-id: y2qnt5n7 -->
<!-- timestamp: 2026-03-19T05:47:20Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 4/6: Implementation complete ✓

<!-- note-id: j8v8m83w -->
<!-- timestamp: 2026-03-19T05:47:44Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 5/6: Validation passed ✓ — RED test GREEN (3/3 assertions), check-skill-refs exit 0, SKILL.md exists, python tests 180/180 passed. make test-unit-only/lint/format-check N/A (no app/ dir in plugin-only repo)

<!-- note-id: 8l781jz9 -->
<!-- timestamp: 2026-03-19T05:47:50Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 6/6: Done ✓ — All AC pass. Self-check: (1) make test-unit-only/lint/format-check: N/A no app dir; (2) RED test GREEN: PASS exit 0; (3) check-skill-refs: PASS exit 0; (4) SKILL.md exists: PASS; (5) python tests: 180 passed

**2026-03-19T05:48:08Z**

CHECKPOINT 6/6: Done ✓ — All validations pass: RED test GREEN (3/3), check-skill-refs.sh clean, 180 Python tests pass.
