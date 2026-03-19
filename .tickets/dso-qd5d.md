---
id: dso-qd5d
status: closed
deps: []
links: []
created: 2026-03-19T05:01:29Z
type: task
priority: 0
assignee: Joe Oakhart
parent: w21-auwy
---
# RED: Write failing shell structural test for fix-bug skill

Write a failing bash test file at tests/hooks/test-fix-bug-skill.sh that verifies the structural requirements (file exists, frontmatter, required sections) of the fix-bug skill file.

TDD Requirement: Write this file in RED phase -- all tests must FAIL because plugins/dso/skills/fix-bug/SKILL.md does not yet exist. Run 'bash tests/hooks/test-fix-bug-skill.sh' to confirm failure before marking done.

Test Cases to Create:
1. test_fix_bug_skill_file_exists -- checks SKILL_FILE exists (-f test)
2. test_fix_bug_skill_frontmatter_name -- greps for 'name: fix-bug' in frontmatter
3. test_fix_bug_skill_user_invocable -- greps for 'user-invocable: true' in frontmatter
4. test_fix_bug_skill_mechanical_path_section -- greps for 'mechanical' section header or keyword
5. test_fix_bug_skill_scoring_section -- greps for scoring rubric content
6. test_fix_bug_skill_config_resolution_section -- greps for 'Config Resolution' section header
7. test_fix_bug_skill_workflow_skeleton_section -- greps for workflow step indicators

File Structure: Follow tests/hooks/test-generate-claude-md-skill.sh pattern:
- SCRIPT_DIR, PLUGIN_ROOT, DSO_PLUGIN_DIR setup
- source tests/lib/assert.sh
- SKILL_FILE=DSO_PLUGIN_DIR/skills/fix-bug/SKILL.md
- assert_eq calls for each test
- print_summary at end

Run 'bash tests/hooks/test-fix-bug-skill.sh' to verify RED state (should fail).

## ACCEPTANCE CRITERIA

- [ ] Test file exists at expected path and is executable
  Verify: test -f $(git rev-parse --show-toplevel)/tests/hooks/test-fix-bug-skill.sh
- [ ] Running shell test against missing skill file exits non-zero (RED state confirmed)
  Verify: bash $(git rev-parse --show-toplevel)/tests/hooks/test-fix-bug-skill.sh; test $? -ne 0
- [ ] test_fix_bug_skill_file_exists test case is present in script
  Verify: grep -q 'test_fix_bug_skill_file_exists' $(git rev-parse --show-toplevel)/tests/hooks/test-fix-bug-skill.sh
- [ ] test_fix_bug_skill_frontmatter_name test case is present in script
  Verify: grep -q 'test_fix_bug_skill_frontmatter_name' $(git rev-parse --show-toplevel)/tests/hooks/test-fix-bug-skill.sh
- [ ] test_fix_bug_skill_user_invocable test case is present in script
  Verify: grep -q 'test_fix_bug_skill_user_invocable' $(git rev-parse --show-toplevel)/tests/hooks/test-fix-bug-skill.sh
- [ ] Script uses assert.sh library (follows project test conventions)
  Verify: grep -q 'source.*assert.sh' $(git rev-parse --show-toplevel)/tests/hooks/test-fix-bug-skill.sh
- [ ] Script calls print_summary at end
  Verify: grep -q 'print_summary' $(git rev-parse --show-toplevel)/tests/hooks/test-fix-bug-skill.sh


## Notes

**2026-03-19T05:07:56Z**

CHECKPOINT 1/6: Task context loaded ✓

**2026-03-19T05:08:15Z**

CHECKPOINT 2/6: Code patterns understood ✓

**2026-03-19T05:08:39Z**

CHECKPOINT 3/6: Tests written ✓

**2026-03-19T05:08:50Z**

CHECKPOINT 4/6: Implementation complete ✓ (RED phase: test file created, no skill implementation needed in this task)

**2026-03-19T05:13:49Z**

CHECKPOINT 5/6: Validation passed ✓ — test-fix-bug-skill.sh confirmed RED (exits 1); full suite bash tests/run-all.sh exits 144 (known SIGURG ceiling per KNOWN-ISSUES.md INC-016, not caused by this change)

**2026-03-19T05:13:54Z**

CHECKPOINT 6/6: Done ✓ — All 7 AC criteria verified: file exists, exits non-zero (RED), all 3 required test cases present, uses assert.sh, calls print_summary
