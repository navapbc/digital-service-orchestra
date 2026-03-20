---
id: dso-tuz0
status: in_progress
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

## ACCEPTANCE CRITERIA

- [ ] bash tests/run-all.sh passes (exit 0)
  Verify: bash $(git rev-parse --show-toplevel)/tests/run-all.sh
- [ ] tests/scripts/test-dso-shim-plugin-root.sh new tests pass (GREEN)
  Verify: bash $(git rev-parse --show-toplevel)/tests/scripts/test-dso-shim-plugin-root.sh 2>&1 | grep -E 'passed|0 failed'
- [ ] .claude/scripts/dso references .claude/dso-config.conf (not workflow-config.conf)
  Verify: grep -q '\.claude/dso-config\.conf' $(git rev-parse --show-toplevel)/.claude/scripts/dso
- [ ] templates/host-project/dso references .claude/dso-config.conf (not workflow-config.conf)
  Verify: grep -q '\.claude/dso-config\.conf' $(git rev-parse --show-toplevel)/templates/host-project/dso
- [ ] .claude/scripts/dso active lines do not reference workflow-config.conf
  Verify: grep -v '^\s*#' $(git rev-parse --show-toplevel)/.claude/scripts/dso | grep -v 'workflow-config\.conf'

## Notes

**2026-03-20T05:25:42Z**

CHECKPOINT 1/6: Task context loaded ✓

**2026-03-20T05:25:54Z**

CHECKPOINT 2/6: Code patterns understood ✓

**2026-03-20T05:26:10Z**

CHECKPOINT 3/6: Tests written (RED tests exist from dso-jfy3) ✓

**2026-03-20T14:47:42Z**

CHECKPOINT 4/6: Implementation complete ✓

**2026-03-20T14:48:52Z**

CHECKPOINT 5/6: Tests GREEN — 9 passed, 0 failed ✓

**2026-03-20T15:09:51Z**

CHECKPOINT 6/6: Done ✓ — AC verify: 4/5 AC pass. AC 'tests/run-all.sh passes' blocked by dso-setup.sh (safeguard file, requires user approval): test_setup_dso_tk_help_works fails because setup writes to workflow-config.conf but shim now reads .claude/dso-config.conf. Tracking ticket dso-5p5i created.
