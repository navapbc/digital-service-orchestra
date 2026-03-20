---
id: dso-xdd8
status: open
deps: []
links: []
created: 2026-03-20T15:57:07Z
type: task
priority: 2
assignee: Joe Oakhart
parent: dso-bugk
---
# Update validate-config.sh and project-detect.sh: replace workflow-config.conf path references

Update runtime path references in two scripts that still check for the old config filename/path.

Files to update:

1. plugins/dso/scripts/validate-config.sh (3 occurrences):
   - Line 4: comment 'Validates a workflow-config.conf file' → 'Validates a dso-config.conf file'
   - Lines 157-158: functional path check:
       if [[ -f "$root/workflow-config.conf" ]]; then
           config_file="$root/workflow-config.conf"
     Update to check '.claude/dso-config.conf' relative to git root:
       if [[ -f "$root/.claude/dso-config.conf" ]]; then
           config_file="$root/.claude/dso-config.conf"
   NOTE: Also check if there's a fallback path variable or if the function accepts a path argument — preserve argument-based paths if present.

2. plugins/dso/scripts/project-detect.sh (5 occurrences):
   - Line 24: comment update → 'port numbers from dso-config.conf'
   - Line 200: array entry 'workflow-config.conf' — update to '.claude/dso-config.conf' or remove if this is file presence detection
   - Line 320: comment update → 'Port numbers from dso-config.conf'
   - Lines 323, 325: functional file check:
       if [[ -f "$PROJECT_DIR/workflow-config.conf" ]]; then
       port_values="$(grep -E '_port\s*=' "$PROJECT_DIR/workflow-config.conf" \
     Update to:
       if [[ -f "$PROJECT_DIR/.claude/dso-config.conf" ]]; then
       port_values="$(grep -E '_port\s*=' "$PROJECT_DIR/.claude/dso-config.conf" \

Read the full context around each occurrence before editing to ensure the path update is semantically correct (project root vs git root vs CLAUDE_PLUGIN_ROOT).

TDD Requirement: N/A — Unit test exemption applies (all 3 criteria met):
1. No conditional logic added — purely updating existing path constants to new canonical path
2. Any test would be a change-detector test asserting path strings
3. Infrastructure-boundary-only — config path constants, no new decision points

However, manually verify the changed path logic is correct by reading surrounding context before editing.

## Acceptance Criteria

- [ ] Zero occurrences of 'workflow-config.conf' in validate-config.sh
  Verify: test $(grep -c 'workflow-config.conf' $(git rev-parse --show-toplevel)/plugins/dso/scripts/validate-config.sh) -eq 0
- [ ] Zero occurrences of 'workflow-config.conf' in project-detect.sh
  Verify: test $(grep -c 'workflow-config.conf' $(git rev-parse --show-toplevel)/plugins/dso/scripts/project-detect.sh) -eq 0
- [ ] validate-config.sh path check uses .claude/dso-config.conf
  Verify: grep '.claude/dso-config.conf' $(git rev-parse --show-toplevel)/plugins/dso/scripts/validate-config.sh | grep -q 'dso-config'
- [ ] project-detect.sh port-detection path uses .claude/dso-config.conf
  Verify: grep '.claude/dso-config.conf' $(git rev-parse --show-toplevel)/plugins/dso/scripts/project-detect.sh | grep -q 'dso-config'

