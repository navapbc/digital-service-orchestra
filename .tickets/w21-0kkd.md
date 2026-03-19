---
id: w21-0kkd
status: open
deps: []
links: []
created: 2026-03-19T05:06:34Z
type: task
priority: 2
parent: w21-0ohz
assignee: Joe Oakhart
---
# Add continuation callout, Step 10a, MANDATORY directive, and structural test for sprint SKILL.md

Edit `plugins/dso/skills/sprint/SKILL.md` and create `tests/scripts/test-sprint-continuation-guidance.sh` to satisfy all success criteria from epic w21-0ohz.

## Context
Orchestrators sometimes close an epic directly from Phase 6 without entering Phase 7 (validation). This task adds a visible CONTINUE callout in Step 10, a new Step 10a for post-merge task closing, and strengthens Step 13's Phase 7 routing to use a MANDATORY positive directive.

## Files
- `plugins/dso/skills/sprint/SKILL.md` — Edit (Steps 10, 10a, 13)
- `tests/scripts/test-sprint-continuation-guidance.sh` — Create (auto-discovered by run-script-tests.sh)

## TDD Sequence (execute in order)

**Step 1 (RED)**: Create `tests/scripts/test-sprint-continuation-guidance.sh` with four named assertions using the tests/lib/assert.sh pattern (see test-commit-workflow-step-1-5.sh for reference). The test file IS the RED phase — behavioral code with conditional assertions; NOT exempt from TDD.

Assertions:
1. `test_continue_callout_exists`: `awk '/### Step 10: /,/### Step 11:/' SKILL.md | grep -q '> \*\*CONTINUE:\*\*'`
2. `test_mandatory_directive_exists`: `awk '/### Step 13/,/## Phase 7/' SKILL.md | grep -q 'MANDATORY'`
3. `test_step_10a_exists`: `awk '/### Step 10: /,/### Step 11:/' SKILL.md | grep -q '### Step 10a'`
4. `test_no_placeholder_bug_id`: `! grep -q 'project-specific-bug-id' SKILL.md`

**Step 2 (Confirm RED)**: Run `bash tests/run-all.sh` — all four assertions must FAIL.

**Step 3 (GREEN)**: Edit `plugins/dso/skills/sprint/SKILL.md`:

a. After the `write-blackboard.sh --clean` code block in Step 10 and before `### Step 11`, add:
```
> **CONTINUE:** After `merge-to-main.sh` completes and blackboard cleanup is done, proceed to Step 11 then Step 13. Do NOT close the epic or invoke `/dso:end-session` here.
```

b. Add new `### Step 10a: Close Completed Tasks (/dso:sprint)` section between Step 10 and Step 11:
```
After `merge-to-main.sh` succeeds, close each task whose code was successfully committed and merged:

```bash
tk close <id> --reason="Fixed: <summary>"
```

Do NOT close tasks that are still open or in a failed state.
```

c. Change Step 13 Phase 7 bullet from:
`- If all tasks are closed → Phase 7 (validation)`
to:
`- If all tasks are closed → **Phase 7 is MANDATORY** — proceed immediately to Phase 7 (validation)`

d. Remove `(project-specific-bug-id)` from Step 10's CONTROL FLOW WARNING. Replace with `(observed 2026-03-18)` or remove the parenthetical entirely.

e. **Step 8 requires NO changes** — it is already notes-only (checkpoint format only, no task-closing language). Verify by inspection.

**Step 4 (Confirm GREEN)**: Run `bash tests/run-all.sh` — all four assertions must PASS.

## TDD Exemption
The TDD cycle is self-contained in this single task. The SKILL.md changes are to a Markdown documentation file — unit exemption criterion 3 (static assets with no executable assertion possible). The test file is NOT exempt — it IS the RED phase. Bundled in one task to satisfy stability (committing test alone leaves run-all.sh failing). `red_test_dependency`: N/A — single task.

## ACCEPTANCE CRITERIA

- [ ] `bash tests/run-all.sh` exits 0
  Verify: cd $(git rev-parse --show-toplevel) && bash tests/run-all.sh
- [ ] `> **CONTINUE:**` callout exists in Step 10 section (between `### Step 10:` and `### Step 11:` headings)
  Verify: awk '/### Step 10: /,/### Step 11:/' plugins/dso/skills/sprint/SKILL.md | grep -q '> \*\*CONTINUE:\*\*'
- [ ] `MANDATORY` appears in Step 13's Phase 7 routing bullet
  Verify: awk '/### Step 13/,/## Phase 7/' plugins/dso/skills/sprint/SKILL.md | grep -q 'MANDATORY'
- [ ] `### Step 10a` heading exists between `### Step 10:` and `### Step 11:` headings
  Verify: awk '/### Step 10: /,/### Step 11:/' plugins/dso/skills/sprint/SKILL.md | grep -q '### Step 10a'
- [ ] `(project-specific-bug-id)` does not appear in SKILL.md
  Verify: ! grep -q 'project-specific-bug-id' plugins/dso/skills/sprint/SKILL.md
- [ ] Step 8 in SKILL.md contains no task-closing language
  Verify: ! awk '/### Step 8/,/### Step 9/' plugins/dso/skills/sprint/SKILL.md | grep -q 'tk close'
- [ ] Test file exists with at least 4 assertion calls
  Verify: test -f $(git rev-parse --show-toplevel)/tests/scripts/test-sprint-continuation-guidance.sh && grep -c '^ *assert_' $(git rev-parse --show-toplevel)/tests/scripts/test-sprint-continuation-guidance.sh | awk '{exit ($1 < 4)}'
