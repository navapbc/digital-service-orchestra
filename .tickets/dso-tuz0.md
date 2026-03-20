---
id: dso-tuz0
status: open
deps: [dso-jfy3]
links: []
created: 2026-03-20T03:33:02Z
type: task
priority: 1
assignee: Joe Oakhart
parent: dso-uc2d
---
# Update .claude/scripts/dso shim and templates/host-project/dso to use .claude/dso-config.conf

## Implementation (GREEN phase for dso-jfy3 tests)

Update both the live shim (.claude/scripts/dso) and the template shim (templates/host-project/dso) to read dso.plugin_root from .claude/dso-config.conf instead of workflow-config.conf.

### Changes to both .claude/scripts/dso AND templates/host-project/dso

Replace step (2) fallback block:

OLD:
  REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || REPO_ROOT=''
  if [ -n "$REPO_ROOT" ] && [ -f "$REPO_ROOT/workflow-config.conf" ]; then
      DSO_ROOT=$(grep '^dso.plugin_root=' "$REPO_ROOT/workflow-config.conf" | cut -d= -f2-)
  fi

NEW:
  REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || REPO_ROOT=''
  if [ -n "$REPO_ROOT" ] && [ -f "$REPO_ROOT/.claude/dso-config.conf" ]; then
      DSO_ROOT=$(grep '^dso.plugin_root=' "$REPO_ROOT/.claude/dso-config.conf" | cut -d= -f2-)
  fi

Also update:
- Comment block at top: change 'workflow-config.conf' to '.claude/dso-config.conf' in DSO_ROOT resolution order
- Error message in step (3): change 'to workflow-config.conf in your git repository root.' to 'to .claude/dso-config.conf in your git repository root.'

### Constraints
- Both files (.claude/scripts/dso and templates/host-project/dso) must be updated identically
- CLAUDE_PLUGIN_ROOT env var step (1) remains unchanged
- grep-based raw parsing is preserved (shim cannot use read-config.sh — chicken-and-egg)

