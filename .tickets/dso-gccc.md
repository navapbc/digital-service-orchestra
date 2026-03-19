---
id: dso-gccc
status: closed
deps: [dso-k0yk, dso-qd5d]
links: []
created: 2026-03-19T05:01:53Z
type: task
priority: 0
assignee: Joe Oakhart
parent: w21-auwy
---
# GREEN: Create plugins/dso/skills/fix-bug/SKILL.md

Create the core fix-bug skill file at plugins/dso/skills/fix-bug/SKILL.md. This is the walking skeleton for the entire dso:fix-bug feature and all sibling stories depend on it.

TDD Requirement: Tasks dso-k0yk (Python content tests) and dso-qd5d (shell structural tests) must already be written and failing (RED) before this task begins. After creating the skill file, both test suites must pass (GREEN):
- python3 -m pytest tests/skills/test_fix_bug_skill.py -q
- bash tests/hooks/test-fix-bug-skill.sh

Required Content (all must be present):

1. YAML Frontmatter:
   name: fix-bug
   description: (description of bug classification and routing skill)
   user-invocable: true

2. Config Resolution section (preserved from tdd-workflow pattern):
   PLUGIN_SCRIPTS, TEST_CMD, LINT_CMD, FORMAT_CHECK_CMD via read-config.sh

3. Error Type Classification:
   - Mechanical errors (import error, type annotation, lint violation, config syntax) -> read-fix-validate path WITHOUT scoring
   - Behavioral errors -> proceed to scoring rubric

4. Scoring Rubric (behavioral bugs only):
   - Severity: 0=low, 1=medium/moderate, 2=high/critical
   - Complexity: 0=simple/trivial, 1=moderate/medium, 2=complex
   - Environment: 0=local, 1=CI failure, 2=production/staging
   - Cascading failure: +2 if applies
   - Prior fix attempts: +2 if applies

5. Routing Thresholds:
   - Score <3 -> BASIC investigation
   - Score 3-5 -> INTERMEDIATE investigation
   - Score >=6 -> ADVANCED investigation

6. 8-Step Workflow Skeleton with step headers:
   Step 0: Check known issues
   Step 1: Score and classify (mechanical vs behavioral, then rubric)
   Step 2: Investigation sub-agent dispatch
   Step 3: Hypothesis testing (propose tests per root cause, run them)
   Step 4: Fix approval (auto-approve or user approval logic)
   Step 5: RED test (write failing test to confirm root cause)
   Step 6: Fix implementation (sub-agent)
   Step 7: Verify fix (RED -> GREEN)
   Step 8: Commit workflow

7. Investigation RESULT Report Schema definition (consumed by all tiers):
   ROOT_CAUSE: (one sentence)
   confidence: (high/medium/low)
   proposed_fixes: [...] (each with description, risk, degrades_functionality flag)
   tests_run: [...] (from hypothesis testing phase)
   prior_attempts: [...] (if any)

8. Discovery File Protocol:
   - Path convention: /tmp/fix-bug-discovery-<ticket-id>.json
   - Required fields: root_cause, confidence, proposed_fixes, tests_run, prior_fix_attempts
   - Used for passing investigation context to fix phase

9. Hypothesis Testing Phase detail (Step 3):
   For each root cause proposed: write a concrete test (bash/unit) that would prove or disprove it. Run the test. Record result in discovery file.

10. tdd-workflow deprecation reference (forward pointer only -- full deprecation is Task 4):
   Note in skill description that this replaces tdd-workflow for bug fixes.

## ACCEPTANCE CRITERIA

- [ ] `bash tests/run-all.sh` passes (exit 0)
  Verify: bash $(git rev-parse --show-toplevel)/tests/run-all.sh
- [ ] `ruff check` passes (exit 0)
  Verify: ruff check $(git rev-parse --show-toplevel)/plugins/dso/scripts/*.py $(git rev-parse --show-toplevel)/tests/**/*.py
- [ ] `ruff format --check` passes (exit 0)
  Verify: ruff format --check $(git rev-parse --show-toplevel)/plugins/dso/scripts/*.py $(git rev-parse --show-toplevel)/tests/**/*.py
- [ ] Skill file exists at plugins/dso/skills/fix-bug/SKILL.md
  Verify: test -f $(git rev-parse --show-toplevel)/plugins/dso/skills/fix-bug/SKILL.md
- [ ] Skill file contains 'name: fix-bug' frontmatter
  Verify: grep -q '^name: fix-bug' $(git rev-parse --show-toplevel)/plugins/dso/skills/fix-bug/SKILL.md
- [ ] Skill file contains 'user-invocable: true' frontmatter
  Verify: grep -q '^user-invocable: true' $(git rev-parse --show-toplevel)/plugins/dso/skills/fix-bug/SKILL.md
- [ ] Skill file contains mechanical error classification (import error, lint violation)
  Verify: grep -q 'import error\|lint violation\|mechanical' $(git rev-parse --show-toplevel)/plugins/dso/skills/fix-bug/SKILL.md
- [ ] Skill file contains routing thresholds (BASIC, INTERMEDIATE, ADVANCED)
  Verify: grep -q 'BASIC' $(git rev-parse --show-toplevel)/plugins/dso/skills/fix-bug/SKILL.md && grep -q 'INTERMEDIATE' $(git rev-parse --show-toplevel)/plugins/dso/skills/fix-bug/SKILL.md && grep -q 'ADVANCED' $(git rev-parse --show-toplevel)/plugins/dso/skills/fix-bug/SKILL.md
- [ ] Skill file contains RESULT schema fields (ROOT_CAUSE, confidence)
  Verify: grep -q 'ROOT_CAUSE' $(git rev-parse --show-toplevel)/plugins/dso/skills/fix-bug/SKILL.md && grep -q 'confidence' $(git rev-parse --show-toplevel)/plugins/dso/skills/fix-bug/SKILL.md
- [ ] Skill file contains discovery file protocol
  Verify: grep -q 'discovery file\|discovery_file\|discovery-file' $(git rev-parse --show-toplevel)/plugins/dso/skills/fix-bug/SKILL.md
- [ ] Skill file contains hypothesis testing phase
  Verify: grep -q 'hypothesis\|Hypothesis' $(git rev-parse --show-toplevel)/plugins/dso/skills/fix-bug/SKILL.md
- [ ] Skill file contains config resolution pattern (read-config.sh)
  Verify: grep -q 'read-config.sh' $(git rev-parse --show-toplevel)/plugins/dso/skills/fix-bug/SKILL.md
- [ ] Python content tests pass (GREEN)
  Verify: python3 -m pytest $(git rev-parse --show-toplevel)/tests/skills/test_fix_bug_skill.py -q
- [ ] Shell structural tests pass (GREEN)
  Verify: bash $(git rev-parse --show-toplevel)/tests/hooks/test-fix-bug-skill.sh
- [ ] Skill file is valid markdown (no broken internal file references)
  Verify: grep -oE '\$\{?REPO_ROOT\}?/[^ )\`]+' $(git rev-parse --show-toplevel)/plugins/dso/skills/fix-bug/SKILL.md | while read p; do test -e "$(git rev-parse --show-toplevel)/${p#*/}" 2>/dev/null || echo "MISSING: $p"; done | grep -c MISSING | awk '{exit ($1 > 0)}'
- [ ] RESULT schema uses uppercase ROOT_CAUSE field name (canonical casing for downstream tier consumption)
  Verify: grep -q 'ROOT_CAUSE' $(git rev-parse --show-toplevel)/plugins/dso/skills/fix-bug/SKILL.md

<!-- Gap Analysis Amendment (dso-auwy Step 6): ROOT_CAUSE uppercase casing must be canonical — sibling stories w21-c4ek, w21-dksj, w21-9pp1 consume this schema and must not diverge on field naming. -->


## Notes

**2026-03-19T05:21:18Z**

CHECKPOINT 1/6: Task context loaded ✓

**2026-03-19T05:21:29Z**

CHECKPOINT 2/6: Code patterns understood ✓

**2026-03-19T05:21:33Z**

CHECKPOINT 3/6: Tests written (none required — RED tests exist) ✓

**2026-03-19T05:23:21Z**

CHECKPOINT 4/6: Implementation complete ✓

**2026-03-19T05:23:38Z**

CHECKPOINT 5/6: Tests GREEN — Python: 12 passed, 0 failed. Shell: 7 passed, 0 failed ✓

**2026-03-19T05:26:44Z**

CHECKPOINT 6/6: Done ✓
