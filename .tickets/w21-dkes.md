---
id: w21-dkes
status: in_progress
deps: [w21-gdon]
links: []
created: 2026-03-20T00:41:46Z
type: task
priority: 2
assignee: Joe Oakhart
parent: dso-bzvu
---
# IMPL-INFRA: Add conditional infrastructure key prompts with port inference and required_tools guidance

Add a '### Infrastructure configuration' section to project-setup/SKILL.md Step 3 that conditionally prompts for infrastructure keys including app/db port numbers with inference logic, and required_tools with explanatory guidance.

Implementation steps:
1. Add sub-section '### Infrastructure configuration' after '### Database configuration'
2. Gate the section on: 'If DETECT_DOCKERFILE_PRESENT=true OR DETECT_DOCKER_COMPOSE_PRESENT=true'
3. Port inference for infrastructure.app_port:
   - Read DETECT_APP_PORT from detection output (project-detect.sh infers from docker-compose port mappings and .env files)
   - Present pre-filled default: 'Detected app port: <DETECT_APP_PORT>. Confirm or enter value:'
   - If DETECT_APP_PORT is absent/unknown, ask user to enter manually
   - Note on variable substitution: if raw docker-compose contains '${APP_PORT:-8000}', the detection script extracts '8000' as the default — the skill presents the resolved number, not the raw variable
4. Port inference for infrastructure.db_port (only when DETECT_DB_PRESENT=true):
   - Same pattern as app_port using DETECT_DB_PORT from detection output
5. infrastructure.required_tools prompt:
   - Always include in the infrastructure section (when infra section is shown)
   - Include guidance text: 'These are CLI tools DSO checks for at session start. If a listed tool is not installed, DSO will produce a warning or error when the session begins. Example: git, docker, make.'
   - Present current default (empty list) or pre-filled value if detection found tools
6. If neither Dockerfile nor docker-compose is detected, skip the section with note: '(skipping — no container infrastructure detected)'

File to edit: plugins/dso/skills/project-setup/SKILL.md

TDD REQUIREMENT: Tests in tests/skills/test_project_setup_skill_conditional_prompts.py (task w21-b9ll) must turn GREEN after this task:
- test_skill_has_infrastructure_conditional_section
- test_skill_has_required_tools_guidance
- test_skill_has_port_inference_instructions

Dependencies: w21-gdon (database section must be present for sequential SKILL.md editing), w21-b9ll (RED tests must exist)

## Acceptance Criteria

- [ ] SKILL.md contains infrastructure conditional section
  Verify: grep -q 'Infrastructure configuration\|infrastructure.*conditional\|infrastructure.*prompt' $(git rev-parse --show-toplevel)/plugins/dso/skills/project-setup/SKILL.md
- [ ] SKILL.md contains required_tools guidance explaining session-start checks
  Verify: grep -q 'session start\|warnings or errors\|CLI tools DSO checks' $(git rev-parse --show-toplevel)/plugins/dso/skills/project-setup/SKILL.md
- [ ] SKILL.md contains port inference instructions referencing variable substitution default extraction
  Verify: grep -q 'DETECT_APP_PORT\|app_port\|port.*infer\|variable substitution' $(git rev-parse --show-toplevel)/plugins/dso/skills/project-setup/SKILL.md
- [ ] SKILL.md mentions infrastructure.app_port and infrastructure.db_port
  Verify: grep -q 'infrastructure.app_port' $(git rev-parse --show-toplevel)/plugins/dso/skills/project-setup/SKILL.md && grep -q 'infrastructure.db_port' $(git rev-parse --show-toplevel)/plugins/dso/skills/project-setup/SKILL.md
- [ ] SKILL.md mentions infrastructure.required_tools
  Verify: grep -q 'infrastructure.required_tools' $(git rev-parse --show-toplevel)/plugins/dso/skills/project-setup/SKILL.md
- [ ] infrastructure tests pass (GREEN)
  Verify: cd $(git rev-parse --show-toplevel) && python -m pytest tests/skills/test_project_setup_skill_conditional_prompts.py::test_skill_has_infrastructure_conditional_section tests/skills/test_project_setup_skill_conditional_prompts.py::test_skill_has_required_tools_guidance tests/skills/test_project_setup_skill_conditional_prompts.py::test_skill_has_port_inference_instructions
- [ ] Skill file is valid markdown
  Verify: test -f $(git rev-parse --show-toplevel)/plugins/dso/skills/project-setup/SKILL.md
- [ ] make lint passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel)/app && make lint
- [ ] make format-check passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel)/app && make format-check


## Notes

<!-- note-id: 4slgq1zj -->
<!-- timestamp: 2026-03-20T02:12:41Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 1/6: Task context loaded ✓

<!-- note-id: 2pcfxytp -->
<!-- timestamp: 2026-03-20T02:12:50Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 2/6: Code patterns understood ✓

<!-- note-id: 44vi6jhd -->
<!-- timestamp: 2026-03-20T02:12:56Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 3/6: Tests written (pre-existing RED) ✓

<!-- note-id: w974rsv0 -->
<!-- timestamp: 2026-03-20T02:13:16Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 4/6: Implementation complete ✓

<!-- note-id: w0yvpors -->
<!-- timestamp: 2026-03-20T02:13:28Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 5/6: Validation passed ✓ — tests 3, 4, 5 now GREEN; tests 6 and 7 remain RED (owned by w21-gdon/w21-t1tt)

<!-- note-id: ywsoltrr -->
<!-- timestamp: 2026-03-20T02:13:38Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 6/6: Done ✓ — AC met: infrastructure.required_tools (CLI check guidance), infrastructure.app_port and infrastructure.db_port (port inference from docker-compose/default) added to Step 3, gated on container detection. Tests 3/4/5 GREEN.
