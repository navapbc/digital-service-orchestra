---
id: w21-hcyh
status: closed
deps: [w21-1y6e]
links: []
created: 2026-03-19T05:12:49Z
type: task
priority: 1
assignee: Joe Oakhart
parent: dso-iwb4
---
# Edit sprint SKILL.md: remove merge-to-main.sh from Step 10, add git push to worktree branch

Edit `plugins/dso/skills/sprint/SKILL.md` to implement the governance constraint from epic `dso-iwb4`:
changes must be committed and the worktree updated from main between batches, but changes must NOT
be merged to main until the epic is complete (Phase 9).

## TDD Requirement

The RED test from Task `w21-1y6e` must be confirmed failing before starting this task.
This task turns the RED test GREEN.

TDD exemption for a separate RED task at this level: the test-writing step is Task w21-1y6e (the
preceding RED test task). This is the GREEN implementation step. The dependency on w21-1y6e
satisfies the red_test_dependency requirement. Exemption criterion: task is "infrastructure-boundary-only"
for agent guidance — it is a static markdown file change with no executable business logic.

## What to change in Step 10 (### Step 10: Commit & Push)

**Remove** the merge-to-main.sh call block after the commit workflow completes. Specifically remove:
- The paragraph "After the commit completes, merge to main using `merge-to-main.sh`..."
- The bash block with `"$REPO_ROOT/scripts/merge-to-main.sh"`
- The line "Do NOT use `git push` directly — it only pushes the worktree branch and does not merge to main."

**Replace** with:
```
After the commit completes, push the worktree branch to keep it up to date:

```bash
git push
```

Do NOT run `merge-to-main.sh` here — merging to main happens only at epic completion in Phase 9, after non-CI validation passes.
```

**Update** the CONTROL FLOW WARNING below Step 10: change the reference from
`merge-to-main.sh` to `git push` so the control-flow warning reflects the new flow.

**Update Step 11** context compaction check intro sentence:
- Old: `Between batches — after all work is committed and pushed — check whether...`
- New: `Between batches — after all work is committed and pushed to the worktree branch — check whether...`

**Verify Phase 9 unchanged**: Confirm that `## Phase 9: Session Close` still delegates to
`/dso:end-session` which handles merge-to-main. No changes to Phase 9.

## Files to modify

- EDIT: `plugins/dso/skills/sprint/SKILL.md`

## File Impact

| File | Action |
|------|--------|
| `plugins/dso/skills/sprint/SKILL.md` | Edit |

## ACCEPTANCE CRITERIA

- [ ] `make test-unit-only` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel)/app && make test-unit-only
- [ ] `make lint` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel)/app && make lint
- [ ] `make format-check` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel)/app && make format-check
- [ ] Skill file is valid markdown
  Verify: test -f $(git rev-parse --show-toplevel)/plugins/dso/skills/sprint/SKILL.md
- [ ] merge-to-main.sh NOT referenced in Step 10 section
  Verify: ! awk '/### Step 10/,/^### /' $(git rev-parse --show-toplevel)/plugins/dso/skills/sprint/SKILL.md | grep -q "merge-to-main.sh"
- [ ] git push IS referenced in Step 10 section
  Verify: awk '/### Step 10/,/^### /' $(git rev-parse --show-toplevel)/plugins/dso/skills/sprint/SKILL.md | grep -q "git push"
- [ ] merge-to-main.sh still referenced in Phase 9
  Verify: awk '/## Phase 9/,0' $(git rev-parse --show-toplevel)/plugins/dso/skills/sprint/SKILL.md | grep -q "merge-to-main"
- [ ] RED test from w21-1y6e now passes (GREEN)
  Verify: $(git rev-parse --show-toplevel)/plugins/dso/tests/test-sprint-skill-step10-no-merge-to-main.sh
- [ ] check-skill-refs.sh passes (no unqualified skill refs introduced)
  Verify: $(git rev-parse --show-toplevel)/plugins/dso/scripts/check-skill-refs.sh

## Notes

<!-- note-id: oohg41ge -->
<!-- timestamp: 2026-03-19T05:31:05Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 1/6: Task context loaded ✓

<!-- note-id: 2au46ro0 -->
<!-- timestamp: 2026-03-19T05:31:50Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 2/6: Code patterns understood ✓

<!-- note-id: vi1e0rqa -->
<!-- timestamp: 2026-03-19T05:31:50Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 3/6: Tests written (none required — skill file edit, validated by existing RED test) ✓

<!-- note-id: iotvnu1d -->
<!-- timestamp: 2026-03-19T05:31:50Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 4/6: Implementation complete ✓

<!-- note-id: v8kwc1km -->
<!-- timestamp: 2026-03-19T05:33:52Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 5/6: Validation passed ✓ — RED test now GREEN (3/3 assertions pass), 180 Python tests pass, check-skill-refs clean

<!-- note-id: 3kyqzy72 -->
<!-- timestamp: 2026-03-19T05:33:58Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 6/6: Done ✓

**2026-03-19T05:45:11Z**

CHECKPOINT 6/6: Done ✓ — Files: plugins/dso/skills/sprint/SKILL.md. Tests: 180 passed + RED test GREEN (3/3). git push fix applied in Autonomous Resolution Loop.
