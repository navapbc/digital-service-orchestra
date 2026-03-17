---
id: dso-0ifj
status: closed
deps: [dso-a33b]
links: []
created: 2026-03-17T20:21:27Z
type: task
priority: 0
assignee: Joe Oakhart
parent: dso-awoz
---
# Implement templates/host-project/dso shim script (GREEN)

## TDD Requirement (GREEN phase)

Implement templates/host-project/dso to make all tests in tests/scripts/test-shim-smoke.sh pass.

## Implementation Steps

1. Create the directory templates/host-project/ if it doesn't exist
2. Create templates/host-project/dso as a POSIX shell dispatcher script
3. Make it executable: chmod +x templates/host-project/dso

## Shim Requirements (from story dso-awoz done definitions)

### DSO_ROOT Resolution (cascading, in order):

1. If $CLAUDE_PLUGIN_ROOT is set → use it as DSO_ROOT
2. Else read dso.plugin_root from workflow-config.conf found via git rev-parse --show-toplevel
   - Read with: grep '^dso.plugin_root=' <config> | cut -d= -f2-
3. Else exit non-zero with error message that names 'dso.plugin_root' and 'workflow-config.conf'

### Script Dispatch:

- Given $1 is the script name and $2..$N are additional args
- If $DSO_ROOT/scripts/$1 exists → exec $DSO_ROOT/scripts/$1 "${@:2}"
- Else exit 127 with error message naming the missing script and the expected path

### POSIX Constraints:

- Use only: cd, pwd, dirname, command, git, grep, cut
- NO readlink -f
- NO realpath
- NO GNU coreutils extensions
- Must work on macOS (BSD), Ubuntu 22.04+, and WSL2/Ubuntu

### Worktree Support:

- Use git rev-parse --show-toplevel to locate the repo root for finding workflow-config.conf
- This returns the worktree root in git worktrees, which is correct (workflow-config.conf is a tracked file present in all worktrees)

### Error Messages (must be specific):

- Missing DSO_ROOT: must contain 'dso.plugin_root' and reference 'workflow-config.conf'
- Missing script: must contain the name of the requested script and the expected path ($DSO_ROOT/scripts/<name>)

## File to Create
- templates/host-project/dso (executable shell script)

## Acceptance Test
Run: bash tests/scripts/test-shim-smoke.sh
All 8 tests should pass (GREEN).

## Acceptance Criteria

- [ ] tests/scripts/test-shim-smoke.sh passes (exit 0)
  Verify: bash $(git rev-parse --show-toplevel)/tests/scripts/test-shim-smoke.sh
- [ ] templates/host-project/dso exists
  Verify: test -f $(git rev-parse --show-toplevel)/templates/host-project/dso
- [ ] templates/host-project/dso is executable
  Verify: test -x $(git rev-parse --show-toplevel)/templates/host-project/dso
- [ ] Shim contains no readlink -f or realpath (POSIX compliance)
  Verify: ! grep -qE 'readlink -f|realpath' $(git rev-parse --show-toplevel)/templates/host-project/dso
- [ ] Shim invoked with valid CLAUDE_PLUGIN_ROOT and known script exits 0
  Verify: CLAUDE_PLUGIN_ROOT=$(git rev-parse --show-toplevel) bash $(git rev-parse --show-toplevel)/templates/host-project/dso tk --help > /dev/null 2>&1
- [ ] Shim invoked with nonexistent script name exits 127
  Verify: CLAUDE_PLUGIN_ROOT=$(git rev-parse --show-toplevel) bash $(git rev-parse --show-toplevel)/templates/host-project/dso nonexistent_script 2>/dev/null; test $? -eq 127
- [ ] Shim error message names 'dso.plugin_root' when neither CLAUDE_PLUGIN_ROOT nor config is available
  Verify: (cd $(mktemp -d) && git init -q && unset CLAUDE_PLUGIN_ROOT && bash $(git rev-parse --show-toplevel)/templates/host-project/dso tk 2>&1 | grep -q 'dso.plugin_root')
- [ ] Shim exits with non-zero and descriptive error when run outside a git repo with no CLAUDE_PLUGIN_ROOT
  Verify: (tmpdir=$(mktemp -d) && unset CLAUDE_PLUGIN_ROOT && cd "$tmpdir" && bash $(git -C $(dirname "$tmpdir") rev-parse --show-toplevel)/templates/host-project/dso tk 2>&1; test $? -ne 0)
- [ ] bash tests/run-all.sh passes (exit 0)
  Verify: bash $(git rev-parse --show-toplevel)/tests/run-all.sh


## Notes

<!-- note-id: ohevxc6e -->
<!-- timestamp: 2026-03-17T20:35:44Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 6/6: Done ✓ — Files: templates/host-project/dso. Tests: PASSED 9/9 (all shim smoke tests pass).

<!-- note-id: nwkj0e4l -->
<!-- timestamp: 2026-03-17T20:35:45Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CLOSE REASON: Implemented: templates/host-project/dso — POSIX shim with cascading DSO_ROOT resolution, exit 127 for missing scripts
