---
id: w21-t1tt
status: open
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

