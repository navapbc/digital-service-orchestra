---
id: dso-6trc
status: open
deps: [dso-c2tl, dso-opue]
links: []
created: 2026-03-20T03:32:37Z
type: task
priority: 1
assignee: Joe Oakhart
parent: dso-uc2d
---
# Update config-paths.sh to use .claude/dso-config.conf resolution

## Implementation (GREEN phase for dso-c2tl tests)

Update plugins/dso/hooks/lib/config-paths.sh to remove the CLAUDE_PLUGIN_ROOT/workflow-config.conf lookup and instead let read-config.sh do all resolution (which now uses .claude/dso-config.conf).

### Changes to config-paths.sh

1. Remove the _CONFIG_FILE setup block (lines 29-35):
   Remove: if [[ -n CLAUDE_PLUGIN_ROOT && -f CLAUDE_PLUGIN_ROOT/workflow-config.conf ]] branch
   Remove: _CONFIG_FILE assignment entirely

2. Remove the _CONFIG_FILE conditional branches from _cfg_read() and _cfg_read_list():
   Simplify both helpers to always call: val=$("$_READ_CONFIG" "$key" 2>/dev/null) || true
   (No config file arg — let read-config.sh resolve via WORKFLOW_CONFIG_FILE or git root .claude/dso-config.conf)

3. Update the comment block at top:
   Change 'workflow-config.conf' references to '.claude/dso-config.conf'
   Remove note about CLAUDE_PLUGIN_ROOT-based config lookup

### Key invariant
WORKFLOW_CONFIG_FILE env var still works because read-config.sh checks it first — this is how tests inject fixtures. No change needed in config-paths.sh for that.

### Constraints  
- _CONFIG_PATHS_LOADED idempotency guard must remain
- Defaults for all exported variables remain unchanged

## ACCEPTANCE CRITERIA

- [ ] bash tests/run-all.sh passes (exit 0)
  Verify: bash $(git rev-parse --show-toplevel)/tests/run-all.sh
- [ ] tests/hooks/test-config-paths.sh new tests pass (GREEN)
  Verify: bash $(git rev-parse --show-toplevel)/tests/hooks/test-config-paths.sh 2>&1 | grep -E 'passed|0 failed'
- [ ] config-paths.sh contains no CLAUDE_PLUGIN_ROOT/workflow-config.conf conditional branch
  Verify: grep -c 'CLAUDE_PLUGIN_ROOT.*workflow-config' $(git rev-parse --show-toplevel)/plugins/dso/hooks/lib/config-paths.sh | awk '{exit ($1 > 0)}'
- [ ] config-paths.sh _CONFIG_PATHS_LOADED guard still present
  Verify: grep -q '_CONFIG_PATHS_LOADED' $(git rev-parse --show-toplevel)/plugins/dso/hooks/lib/config-paths.sh
- [ ] config-paths.sh comment block references .claude/dso-config.conf
  Verify: grep -q '\.claude/dso-config\.conf' $(git rev-parse --show-toplevel)/plugins/dso/hooks/lib/config-paths.sh
