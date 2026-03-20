---
id: dso-2vwl
status: open
deps: [dso-3v44, dso-opue]
links: []
created: 2026-03-20T03:33:33Z
type: task
priority: 1
assignee: Joe Oakhart
parent: dso-uc2d
---
# Update all runtime scripts to use .claude/dso-config.conf path

## Implementation (GREEN phase for dso-3v44 tests)

Update all runtime scripts that hardcode 'workflow-config.conf' in config path construction to use '.claude/dso-config.conf'.

### Files to update (hardcoded path construction only):

1. plugins/dso/scripts/validate.sh
   Change: CONFIG_FILE="${CONFIG_FILE:-$REPO_ROOT/workflow-config.conf}"
   To:     CONFIG_FILE="${CONFIG_FILE:-$REPO_ROOT/.claude/dso-config.conf}"
   Also update the comment on line above.

2. plugins/dso/scripts/validate-phase.sh
   Change: CONFIG_FILE="$REPO_ROOT/workflow-config.conf"
   To:     CONFIG_FILE="$REPO_ROOT/.claude/dso-config.conf"
   Also update the error message that references workflow-config.conf in cfg_required().

3. plugins/dso/scripts/sprint-next-batch.sh
   Change all: "$REPO_ROOT/workflow-config.conf" path references
   To: "$REPO_ROOT/.claude/dso-config.conf"

4. plugins/dso/hooks/auto-format.sh
   Change: CLAUDE_PLUGIN_ROOT/workflow-config.conf reference
   To: use WORKFLOW_CONFIG_FILE env var or let config-paths.sh resolve (no hardcoded path)

5. plugins/dso/hooks/lib/pre-bash-functions.sh
   Same pattern: remove CLAUDE_PLUGIN_ROOT/workflow-config.conf direct references

6. plugins/dso/scripts/merge-to-main.sh
   Update CONFIG_FILE construction to .claude/dso-config.conf

7. plugins/dso/scripts/ci-status.sh
   Update config path references

8. plugins/dso/scripts/validate-config.sh
   Update the default resolution path (line 157-158)

9. Other scripts from grep list: check-local-env.sh, worktree-create.sh, smoke-test-portable.sh, bump-version.sh, project-detect.sh, reset-tickets.sh, resolve-stack-adapter.sh, capture-review-diff.sh, agent-batch-lifecycle.sh, cleanup-claude-session.sh, check-persistence-coverage.sh

### Approach for each script
- If the script constructs the path as REPO_ROOT/workflow-config.conf: change to REPO_ROOT/.claude/dso-config.conf
- If the script passes the path to read-config.sh as an explicit arg: update that arg
- Comments referencing workflow-config.conf must also be updated to .claude/dso-config.conf

### Exclusions (do NOT change in this task)
- read-config.sh: updated in dso-opue
- config-paths.sh: updated in dso-6trc
- dso-setup.sh: out of scope per story (separate story dso-q2ev)
- smoke-test-portable.sh writes a temp workflow-config.conf fixture: update fixture to write .claude/dso-config.conf

## ACCEPTANCE CRITERIA

- [ ] bash tests/run-all.sh passes (exit 0)
  Verify: bash $(git rev-parse --show-toplevel)/tests/run-all.sh
- [ ] tests/scripts/test-config-callers-updated.sh all tests pass (GREEN)
  Verify: bash $(git rev-parse --show-toplevel)/tests/scripts/test-config-callers-updated.sh 2>&1 | grep -E 'passed|0 failed'
- [ ] validate.sh references .claude/dso-config.conf in CONFIG_FILE construction
  Verify: grep -q '\.claude/dso-config\.conf' $(git rev-parse --show-toplevel)/plugins/dso/scripts/validate.sh
- [ ] validate-phase.sh references .claude/dso-config.conf in CONFIG_FILE construction
  Verify: grep -q '\.claude/dso-config\.conf' $(git rev-parse --show-toplevel)/plugins/dso/scripts/validate-phase.sh
- [ ] sprint-next-batch.sh references .claude/dso-config.conf (not workflow-config.conf)
  Verify: grep -q '\.claude/dso-config\.conf' $(git rev-parse --show-toplevel)/plugins/dso/scripts/sprint-next-batch.sh
- [ ] No active lines in plugins/dso/scripts/*.sh construct REPO_ROOT/workflow-config.conf path (excluding dso-setup.sh, read-config.sh, validate-config.sh)
  Verify: grep -r 'REPO_ROOT.*workflow-config\.conf' $(git rev-parse --show-toplevel)/plugins/dso/scripts/ --include='*.sh' | grep -v 'read-config\.sh\|validate-config\.sh\|dso-setup\.sh\|submit-to-schemastore\.sh' | grep -c . | awk '{exit ($1 > 0)}'
