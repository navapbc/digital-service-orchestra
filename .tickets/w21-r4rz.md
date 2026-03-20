---
id: w21-r4rz
status: open
deps: [w21-8qo1, w21-9d8u, w21-q8nv]
links: []
created: 2026-03-20T00:52:09Z
type: task
priority: 2
assignee: Joe Oakhart
parent: dso-jvjw
---
# IMPL: Update project-setup SKILL.md to document smart file handling behavior

Update plugins/dso/skills/project-setup/SKILL.md Step 5 to document the new smart file handling behavior introduced by this story:

1. Replace the current Step 5 description ('Copy DSO Templates') with accurate description of the supplement/merge logic:
   - CLAUDE.md: if exists, check for DSO markers and offer supplement (not overwrite); if absent, copy template
   - KNOWN-ISSUES.md: same supplement logic
   - .pre-commit-config.yaml: if exists, merge DSO hooks; if absent, copy example
   - CI workflow: if any .github/workflows/*.yml exists, run guard analysis and report missing guards; if none exist, copy ci.example.yml

2. Document the DETECT_ env var contract used for CI guard analysis (how detection output from project-detect.sh flows into dso-setup.sh)

3. Update Error Handling Reference table to include new cases:
   - 'CLAUDE.md or KNOWN-ISSUES.md already exists' -> supplement or skip based on DSO section markers
   - '.pre-commit-config.yaml already exists' -> merge DSO hooks
   - 'CI workflow already exists' -> run guard analysis, report missing guards, do not copy ci.example.yml

No new architectural patterns — documentation only update.

Note: Do not change Step 1 or Steps 2-4 of the skill (they cover dso-setup.sh script execution, stack detection, and config writing, which are in scope for other stories).

## Acceptance Criteria

- [ ] bash tests/run-all.sh passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && bash tests/run-all.sh
- [ ] plugins/dso/skills/project-setup/SKILL.md Step 5 references supplement logic for CLAUDE.md and KNOWN-ISSUES.md
  Verify: grep -q 'supplement\|DSO section\|marker' $(git rev-parse --show-toplevel)/plugins/dso/skills/project-setup/SKILL.md
- [ ] plugins/dso/skills/project-setup/SKILL.md references DETECT_ env var contract or detection output integration
  Verify: grep -q 'DETECT_\|detection output\|project-detect' $(git rev-parse --show-toplevel)/plugins/dso/skills/project-setup/SKILL.md
- [ ] plugins/dso/skills/project-setup/SKILL.md Error Handling Reference table includes CI workflow already exists case
  Verify: grep -q 'CI workflow\|existing.*workflow' $(git rev-parse --show-toplevel)/plugins/dso/skills/project-setup/SKILL.md
- [ ] bash $(git rev-parse --show-toplevel)/plugins/dso/scripts/check-skill-refs.sh passes (exit 0) — no unqualified skill refs
  Verify: bash $(git rev-parse --show-toplevel)/plugins/dso/scripts/check-skill-refs.sh


