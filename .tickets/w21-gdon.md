---
id: w21-gdon
status: open
deps: [w21-b9ll]
links: []
created: 2026-03-20T00:41:24Z
type: task
priority: 2
assignee: Joe Oakhart
parent: dso-bzvu
---
# IMPL-DB: Add conditional database key prompts to project-setup SKILL.md Step 3

Add a new '### Database configuration' section to project-setup/SKILL.md Step 3 that conditionally prompts for database keys when project detection indicates a database service is present.

Implementation steps:
1. Add a sub-section in Step 3 immediately after the 'Monitoring' section: '### Database configuration'
2. Gate prompting on detection output: 'If DETECT_DB_PRESENT=true (from project-detect.sh output), prompt for:'
   - database.ensure_cmd: command to create/migrate the database (e.g., 'make db-migrate')
   - database.status_cmd: command to check database connectivity (e.g., 'make db-status')
   - infrastructure.db_container: docker-compose service name for the database container (e.g., 'db' or 'postgres')
3. For each key, reference docs/CONFIGURATION-REFERENCE.md for description.
4. If DETECT_DB_PRESENT=false (or field absent/unknown), skip the entire sub-section with a note: '(skipping — no database service detected)'
5. Do NOT prompt for these keys when DB is not detected.

Detection field to reference: Use the 'db_detected' or 'docker_db_detected' field from the project-detect.sh output schema (as defined by dso-r2es; the exact field name must match the schema documented in that story's deliverable).

File to edit: plugins/dso/skills/project-setup/SKILL.md

TDD REQUIREMENT: Tests in tests/skills/test_project_setup_skill_conditional_prompts.py (task w21-b9ll) must turn GREEN after this task:
- test_skill_has_database_conditional_section
- test_database_section_conditioned_on_db_detection

Dependencies: w21-b9ll (RED test must exist), dso-r2es (detection script schema must be finalized)

## Acceptance Criteria

- [ ] SKILL.md contains a database conditional section heading
  Verify: grep -q 'Database configuration\|database.*prompt\|database.*conditional' $(git rev-parse --show-toplevel)/plugins/dso/skills/project-setup/SKILL.md
- [ ] SKILL.md references detection output field to gate database prompts
  Verify: grep -q 'db_detected\|docker_db_detected\|DETECT_DB' $(git rev-parse --show-toplevel)/plugins/dso/skills/project-setup/SKILL.md
- [ ] SKILL.md mentions database.ensure_cmd and database.status_cmd and infrastructure.db_container
  Verify: grep -q 'database.ensure_cmd' $(git rev-parse --show-toplevel)/plugins/dso/skills/project-setup/SKILL.md && grep -q 'database.status_cmd' $(git rev-parse --show-toplevel)/plugins/dso/skills/project-setup/SKILL.md && grep -q 'infrastructure.db_container' $(git rev-parse --show-toplevel)/plugins/dso/skills/project-setup/SKILL.md
- [ ] tests/skills/test_project_setup_skill_conditional_prompts.py database tests pass (GREEN)
  Verify: cd $(git rev-parse --show-toplevel) && python -m pytest tests/skills/test_project_setup_skill_conditional_prompts.py::test_skill_has_database_conditional_section tests/skills/test_project_setup_skill_conditional_prompts.py::test_database_section_conditioned_on_db_detection
- [ ] Skill file is valid markdown
  Verify: test -f $(git rev-parse --show-toplevel)/plugins/dso/skills/project-setup/SKILL.md
- [ ] make lint passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel)/app && make lint
- [ ] make format-check passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel)/app && make format-check

