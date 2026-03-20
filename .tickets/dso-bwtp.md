---
id: dso-bwtp
status: open
deps: [dso-ozsx]
links: []
created: 2026-03-20T00:42:42Z
type: task
priority: 1
assignee: Joe Oakhart
parent: dso-6576
---
# IMPL: Update project-setup SKILL.md to include CI auto-detection wizard step

Update plugins/dso/skills/project-setup/SKILL.md Step 3 (Interactive Configuration Wizard) to add a CI configuration sub-section that reads detection output from dso-r2es (project-detect.sh) and presents ci.* keys for user confirmation.

TDD EXEMPTION: This task modifies only static agent instruction content (SKILL.md markdown). No executable conditional logic is added. Criterion 3: 'modifies only static assets (schema migrations with no branching logic, Markdown documentation, static config files) where no executable assertion is possible.'

IMPLEMENTATION STEPS:
1. In plugins/dso/skills/project-setup/SKILL.md, add a CI configuration sub-section after the Jira integration sub-section in Step 3
2. The sub-section should:
   a. Check if project-detect.sh output is available (from dso-r2es detection context)
   b. If CI workflows detected: present detected ci.workflow_name value for confirmation
   c. Prompt for: ci.workflow_name, ci.fast_gate_job, ci.fast_fail_job, ci.test_ceil_job, ci.integration_workflow
   d. For each, show auto-detected value (from project-detect.sh output) or indicate 'not detected'
   e. Note: 'merge.ci_workflow_name is deprecated — if detected in existing config, migrate to ci.workflow_name'
   f. If existing config has merge.ci_workflow_name: show deprecation notice and suggest setting ci.workflow_name
3. Authoritative key descriptions come from docs/CONFIGURATION-REFERENCE.md

FILE: plugins/dso/skills/project-setup/SKILL.md (edit — add CI sub-section to Step 3)


## ACCEPTANCE CRITERIA

- [ ] CI configuration sub-section exists in project-setup SKILL.md Step 3
  Verify: grep -q 'ci\.workflow_name\|CI workflow' $(git rev-parse --show-toplevel)/plugins/dso/skills/project-setup/SKILL.md
- [ ] SKILL.md mentions auto-detection of CI workflow from .github/workflows/
  Verify: grep -q '\.github/workflows\|project-detect' $(git rev-parse --show-toplevel)/plugins/dso/skills/project-setup/SKILL.md
- [ ] SKILL.md mentions deprecation of merge.ci_workflow_name
  Verify: grep -q 'merge\.ci_workflow_name.*deprecated\|deprecated.*merge\.ci_workflow_name' $(git rev-parse --show-toplevel)/plugins/dso/skills/project-setup/SKILL.md
- [ ] No qualified skill references broken (check-skill-refs.sh passes)
  Verify: bash $(git rev-parse --show-toplevel)/plugins/dso/scripts/check-skill-refs.sh
