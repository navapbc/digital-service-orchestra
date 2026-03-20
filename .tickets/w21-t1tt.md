---
id: w21-t1tt
status: in_progress
deps: [w21-dkes]
links: []
created: 2026-03-20T00:42:07Z
type: task
priority: 2
assignee: Joe Oakhart
parent: dso-bzvu
---
# IMPL-STAGING-PYVER: Add conditional staging.url prompt and worktree.python_version auto-detection

Add conditional staging.url prompting and worktree.python_version auto-detection sections to project-setup/SKILL.md Step 3.

Implementation steps:

1. Staging section - add '### Staging configuration' sub-section:
   - Gate on: 'If DETECT_STAGING_CONFIG_PRESENT=true (staging config file, heroku.yml, or STAGING_URL env var detected)'
   - Prompt for staging.url: 'Staging URL (e.g., https://your-app.herokuapp.com):'
   - If DETECT_STAGING_URL from detection output is non-empty, pre-fill as default
   - If staging config not detected, skip with note: '(skipping — no staging configuration detected)'

2. worktree.python_version auto-detection - add '### Python version' sub-section:
   - ALWAYS prompt for worktree.python_version (not conditional on detection, but pre-fill from detection)
   - Pre-fill logic (in priority order):
     a. DETECT_PYTHON_VERSION from project-detect.sh (sourced from pyproject.toml, .python-version, or python3 --version)
     b. If not detected, leave blank for manual entry
   - Display as: 'Python version (auto-detected: <DETECT_PYTHON_VERSION>). Confirm or enter value:'
   - If not detected: 'Python version (e.g., 3.13.0):'
   - This is used for worktree.python_version in workflow-config.conf

File to edit: plugins/dso/skills/project-setup/SKILL.md

TDD REQUIREMENT: Tests in tests/skills/test_project_setup_skill_conditional_prompts.py (task w21-b9ll) must turn GREEN after this task:
- test_skill_has_staging_conditional_section
- test_skill_has_python_version_autodetection

All 7 tests must be GREEN after this task completes (full story done definitions satisfied).

Dependencies: w21-dkes (infrastructure section must be present), w21-b9ll (RED tests must exist)

## Acceptance Criteria

- [ ] SKILL.md contains staging conditional section gated on staging config detection
  Verify: grep -q 'Staging configuration\|staging.*conditional\|staging.url' $(git rev-parse --show-toplevel)/plugins/dso/skills/project-setup/SKILL.md
- [ ] SKILL.md contains staging.url key reference
  Verify: grep -q 'staging.url' $(git rev-parse --show-toplevel)/plugins/dso/skills/project-setup/SKILL.md
- [ ] SKILL.md references DETECT_STAGING_CONFIG_PRESENT or equivalent for staging gate
  Verify: grep -q 'DETECT_STAGING\|staging.*detect\|staging_config' $(git rev-parse --show-toplevel)/plugins/dso/skills/project-setup/SKILL.md
- [ ] SKILL.md contains worktree.python_version with auto-detection pre-fill instructions
  Verify: grep -q 'worktree.python_version' $(git rev-parse --show-toplevel)/plugins/dso/skills/project-setup/SKILL.md
- [ ] SKILL.md references detection sources for Python version (pyproject.toml, .python-version, or python3)
  Verify: grep -q 'pyproject.toml\|\.python-version\|DETECT_PYTHON' $(git rev-parse --show-toplevel)/plugins/dso/skills/project-setup/SKILL.md
- [ ] All 7 conditional prompt tests pass (GREEN — story complete)
  Verify: cd $(git rev-parse --show-toplevel) && python -m pytest tests/skills/test_project_setup_skill_conditional_prompts.py
- [ ] Skill file is valid markdown
  Verify: test -f $(git rev-parse --show-toplevel)/plugins/dso/skills/project-setup/SKILL.md
- [ ] make lint passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel)/app && make lint
- [ ] make format-check passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel)/app && make format-check


## Notes

<!-- note-id: eon2octe -->
<!-- timestamp: 2026-03-20T02:30:25Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 1/6: Task context loaded ✓

<!-- note-id: ay9c99st -->
<!-- timestamp: 2026-03-20T02:30:31Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 2/6: Code patterns understood ✓ — Tests 6 and 7 are RED (staging conditional section and Python version auto-detection missing from Step 3 of SKILL.md)

<!-- note-id: 965b7oz8 -->
<!-- timestamp: 2026-03-20T02:30:36Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 3/6: Tests written (pre-existing RED) ✓ — w21-b9ll RED tests confirmed: test_skill_has_staging_conditional_section, test_skill_has_python_version_autodetection

<!-- note-id: sj757gk6 -->
<!-- timestamp: 2026-03-20T02:31:01Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 4/6: Implementation complete ✓ — Added '### Staging configuration' section (gated on DETECT_STAGING_CONFIG_PRESENT, prompts for staging.url with DETECT_STAGING_URL pre-fill) and '### Python version' section (always prompts for worktree.python_version, pre-fills from DETECT_PYTHON_VERSION sourced from pyproject.toml, .python-version, or python3 binary) to SKILL.md Step 3

<!-- note-id: 9bg5k9id -->
<!-- timestamp: 2026-03-20T02:31:10Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 5/6: Validation passed ✓ — All 7 tests GREEN (was 5/7; now 7/7)

<!-- note-id: 54i0159g -->
<!-- timestamp: 2026-03-20T02:31:23Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 6/6: Done ✓ — All AC verified: staging.url section gated on DETECT_STAGING_CONFIG_PRESENT, worktree.python_version auto-detection from pyproject.toml/.python-version/python3 binary, all 7 tests GREEN, all grep AC checks pass
