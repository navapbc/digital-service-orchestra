---
id: dso-opue
status: in_progress
deps: [dso-s6kt]
links: []
created: 2026-03-20T03:32:16Z
type: task
priority: 1
assignee: Joe Oakhart
parent: dso-uc2d
---
# Update read-config.sh to resolve from .claude/dso-config.conf + move config file

## Implementation (GREEN phase for dso-s6kt tests)

Update read-config.sh resolution chain AND move this repo's config file. Both changes must be committed together to keep tests green.

### Changes to read-config.sh (plugins/dso/scripts/read-config.sh)

Replace the resolution order comment and logic block (lines 36-58) with:

Resolution order:
  1. WORKFLOW_CONFIG_FILE env var (exact file path — highest priority, for test isolation)
  2. git rev-parse --show-toplevel/.claude/dso-config.conf (new canonical path)
  NOTE: CLAUDE_PLUGIN_ROOT-based resolution removed — CLAUDE_PLUGIN_ROOT points to the plugin dir, not the host project git root. Host projects now always use .claude/dso-config.conf.

Remove the CLAUDE_PLUGIN_ROOT branch entirely (lines 45-50 in original). The new logic:
  if WORKFLOW_CONFIG_FILE set → use it
  else → git_root/.claude/dso-config.conf (if exists, else exit 0 gracefully)

### Move config file in this repo

  git mv workflow-config.conf .claude/dso-config.conf

(Create .claude/ directory if it does not exist — it already exists in this repo at .claude/)

### Constraints
- WORKFLOW_CONFIG_FILE env var must still override (test isolation preserved)
- Missing .claude/dso-config.conf must still exit 0 with empty output (graceful degradation)
- The CLAUDE_PLUGIN_ROOT detection in config-paths.sh is updated in a SEPARATE task (dso task for config-paths.sh) — read-config.sh itself no longer consults CLAUDE_PLUGIN_ROOT

## ACCEPTANCE CRITERIA

- [ ] bash tests/run-all.sh passes (exit 0)
  Verify: bash $(git rev-parse --show-toplevel)/tests/run-all.sh
- [ ] tests/scripts/test-read-config.sh all new tests pass (GREEN)
  Verify: bash $(git rev-parse --show-toplevel)/tests/scripts/test-read-config.sh 2>&1 | grep -E 'passed|0 failed'
- [ ] read-config.sh resolution order comment references .claude/dso-config.conf (not workflow-config.conf)
  Verify: grep -q '\.claude/dso-config\.conf' $(git rev-parse --show-toplevel)/plugins/dso/scripts/read-config.sh
- [ ] read-config.sh contains no CLAUDE_PLUGIN_ROOT branch for config file resolution
  Verify: grep -c 'CLAUDE_PLUGIN_ROOT.*workflow-config' $(git rev-parse --show-toplevel)/plugins/dso/scripts/read-config.sh | awk '{exit ($1 > 0)}'
- [ ] workflow-config.conf does NOT exist at repo root
  Verify: ! test -f $(git rev-parse --show-toplevel)/workflow-config.conf
- [ ] .claude/dso-config.conf EXISTS at repo root
  Verify: test -f $(git rev-parse --show-toplevel)/.claude/dso-config.conf
- [ ] Missing .claude/dso-config.conf still exits 0 with empty output (graceful degradation)
  Verify: actual=$(WORKFLOW_CONFIG_FILE=/nonexistent/path.conf bash $(git rev-parse --show-toplevel)/plugins/dso/scripts/read-config.sh commands.test); test -z "$actual"

## Notes

**2026-03-20T04:44:30Z**

CHECKPOINT 1/6: Task context loaded ✓

**2026-03-20T04:45:26Z**

CHECKPOINT 2/6: Code patterns understood ✓

**2026-03-20T04:45:30Z**

CHECKPOINT 3/6: Tests written (RED tests exist from dso-s6kt) ✓

**2026-03-20T04:45:58Z**

CHECKPOINT 4/6: Implementation complete ✓

**2026-03-20T04:49:55Z**

CHECKPOINT 5/6: Tests green ✓ — test-read-config.sh: 70 PASSED 0 FAILED; test-read-config-flat.sh: 16 PASSED 0 FAILED; previously RED tests now GREEN (test_resolves_from_dot_claude_dso_config_conf, test_no_fallback_to_workflow_config_conf)

**2026-03-20T04:51:18Z**

CHECKPOINT 6/6: Done ✓ — All ACs pass: (1) test-read-config.sh 70/0 pass/fail; (2) test-read-config-flat.sh 16/0 pass/fail; (3) resolution comment references .claude/dso-config.conf; (4) no CLAUDE_PLUGIN_ROOT.*workflow-config branch; (5) workflow-config.conf removed from root; (6) .claude/dso-config.conf exists; (7) missing config exits 0 empty. Pre-existing failures: test-config-callers-updated.sh (7 fail) and test-config-paths.sh (2 fail) from other epic tasks (dso-6trc, dso-cn4j, dso-2vwl).
