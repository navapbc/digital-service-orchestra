---
id: dso-g3vq
status: closed
deps: [dso-tisu]
links: []
created: 2026-03-18T16:05:41Z
type: task
priority: 2
assignee: Joe Oakhart
parent: dso-ojbb
---
# Update skills/project-setup/SKILL.md for --dryrun mode

Update skills/project-setup/SKILL.md to support --dryrun flag. When invoked with --dryrun, the skill runs the full interactive wizard but shows a combined preview instead of making changes, then asks 'Proceed with setup?'.

TDD REQUIREMENT: First check that existing skill-ref tests pass (test_check_skill_refs passes before changes). The skill itself is validated by inspection since it is agent-facing markdown, not executable code.

Changes to SKILL.md:
1. Add --dryrun detection at top of Step 1:
   DRYRUN flag detection: if --dryrun is in the args, set DRYRUN=true and pass it through.

2. Step 1 modification: call dso-setup.sh with --dryrun when DRYRUN=true:
   bash "$CLAUDE_PLUGIN_ROOT/scripts/dso-setup.sh" "$TARGET_REPO" --dryrun
   Capture stdout as SETUP_PREVIEW. Still handle exit codes (1=fatal stop, 2=warnings ask).

3. Steps 2-3 run normally regardless of dryrun: detect stack, run full interactive wizard collecting all answers.

4. Step 4 in dryrun mode: instead of writing workflow-config.conf, display what would be written:
   [dryrun] workflow-config.conf preview:
   <show all collected key=value pairs>

5. After wizard, show combined preview:
   === Dryrun Preview ===
   [Script actions that would run:]
   <SETUP_PREVIEW output>
   [workflow-config.conf that would be written:]
   <key=value pairs>
   Then ask: 'Proceed with setup? (yes/no)'
   - If yes: re-run Steps 1-4 without --dryrun, reusing collected answers without re-prompting
   - If no: stop gracefully

6. Step 5 in dryrun mode: show which templates would be copied instead of copying, then ask Proceed.

## Acceptance Criteria

- [ ] Skill file exists and is valid markdown
  Verify: test -f $(git rev-parse --show-toplevel)/skills/project-setup/SKILL.md
- [ ] Skill contains --dryrun handling documentation
  Verify: grep -q -- '--dryrun' $(git rev-parse --show-toplevel)/skills/project-setup/SKILL.md
- [ ] Skill contains Proceed prompt for dryrun mode
  Verify: grep -q 'Proceed' $(git rev-parse --show-toplevel)/skills/project-setup/SKILL.md
- [ ] Skill calls dso-setup.sh with --dryrun in dryrun mode
  Verify: grep -q 'dso-setup.sh.*--dryrun\|--dryrun' $(git rev-parse --show-toplevel)/skills/project-setup/SKILL.md
- [ ] check-skill-refs passes (no unqualified skill refs introduced)
  Verify: bash $(git rev-parse --show-toplevel)/scripts/check-skill-refs.sh 2>&1 | grep -qv 'FAIL'
- [ ] ruff check passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff check scripts/*.py tests/**/*.py


## Notes

**2026-03-18T16:44:03Z**

CHECKPOINT 1/6: Task context loaded ✓

**2026-03-18T16:44:10Z**

CHECKPOINT 2/6: Code patterns understood ✓

**2026-03-18T16:44:13Z**

CHECKPOINT 3/6: Tests written (none required) ✓

**2026-03-18T16:45:00Z**

CHECKPOINT 4/6: Implementation complete ✓

**2026-03-18T16:45:15Z**

CHECKPOINT 5/6: Validation passed ✓

**2026-03-18T16:45:46Z**

CHECKPOINT 6/6: Done ✓ — AC1: pass, AC2: pass, AC3: pass, AC4: pass, AC5: pass (check-skill-refs exits 0, no FAIL output; grep-qv false negative on empty stdout), AC6: pass (ruff exits 0)

**2026-03-18T16:59:33Z**

CHECKPOINT 6/6: Done ✓ — Batch 3 complete, review passed.
