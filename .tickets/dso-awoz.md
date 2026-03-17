---
id: dso-awoz
status: closed
deps: []
links: []
created: 2026-03-17T19:51:47Z
type: story
priority: 0
assignee: Joe Oakhart
parent: dso-42eg
---
# As a developer in a host project, I can invoke any DSO script via .claude/scripts/dso


## Notes

<!-- note-id: bqswd9fw -->
<!-- timestamp: 2026-03-17T19:52:18Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

## What
Create the shim template at `templates/host-project/dso` in the DSO plugin. This is the walking skeleton — it unblocks all other stories.

## Why
Every host project invocation of DSO scripts currently requires constructing `$CLAUDE_PLUGIN_ROOT/scripts/<name>`, which is verbose and unreliable. The shim provides a single stable entry point.

## Scope
IN: Create `templates/host-project/dso`; cascading DSO_ROOT resolution ($CLAUDE_PLUGIN_ROOT → dso.plugin_root in workflow-config.conf → error with actionable message naming the key and file); POSIX-only (cd, pwd, dirname, command, git — no readlink -f, realpath); worktree + main repo support via git rev-parse --show-toplevel; dispatch maps `dso <name>` to `$DSO_ROOT/scripts/<name>`, exits 127 with descriptive error if not found
OUT: Library mode (--lib) [S2], setup bootstrapping [S3], smoke tests [S4], doc migration [S5]

## Done Definitions
- When this story is complete, `dso tk --help` exits 0 from repo root and any subdirectory
  ← Satisfies: 'A host project developer or agent can run any DSO script via .claude/scripts/dso'
- When this story is complete, `dso nonexistent` exits 127 with a message naming the missing script
  ← Satisfies: 'The shim exits with code 127 and a descriptive error if <name> does not match'
- When this story is complete, shim resolves DSO_ROOT correctly when only workflow-config.conf is set (CLAUDE_PLUGIN_ROOT unset)
  ← Satisfies: 'The shim resolves DSO_ROOT by checking (1) $CLAUDE_PLUGIN_ROOT, then (2) dso.plugin_root'
- When this story is complete, shim exits with error message naming `dso.plugin_root` in `workflow-config.conf` when neither source is available
  ← Satisfies: 'The shim resolves DSO_ROOT... then (3) exiting with a descriptive error message'
- When this story is complete, shim uses no readlink -f, realpath, or GNU coreutils extensions
  ← Satisfies: 'The shim uses only POSIX-specified shell builtins'

## Considerations
- [Reliability] Error messages must name the config key and file — vague 'plugin not found' errors will confuse users
- [Reliability] git rev-parse --show-toplevel returns the worktree root in a worktree, not the main repo root — workflow-config.conf must be found relative to it (it is a tracked file, so it will be present)

<!-- note-id: 2qcoyneo -->
<!-- timestamp: 2026-03-17T20:17:20Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

COMPLEXITY_CLASSIFICATION: COMPLEX

## ACCEPTANCE CRITERIA

- [ ] `templates/host-project/dso` exists in the DSO plugin repo
  Verify: test -f $(git rev-parse --show-toplevel)/templates/host-project/dso
- [ ] Shim is executable and has no non-POSIX constructs (no readlink -f, realpath)
  Verify: grep -qvE 'readlink -f|realpath' $(git rev-parse --show-toplevel)/templates/host-project/dso
- [ ] `dso tk --help` exits 0 when DSO_ROOT is resolvable
  Verify: CLAUDE_PLUGIN_ROOT=$(git rev-parse --show-toplevel) bash $(git rev-parse --show-toplevel)/templates/host-project/dso tk --help
- [ ] `dso nonexistent` exits 127 with descriptive error message
  Verify: CLAUDE_PLUGIN_ROOT=$(git rev-parse --show-toplevel) bash $(git rev-parse --show-toplevel)/templates/host-project/dso nonexistent 2>&1; test $? -eq 127
- [ ] Shim resolves DSO_ROOT from workflow-config.conf when CLAUDE_PLUGIN_ROOT is unset
  Verify: unset CLAUDE_PLUGIN_ROOT; bash $(git rev-parse --show-toplevel)/templates/host-project/dso tk --help 2>&1 | grep -q "Usage"
- [ ] Shim exits with error naming dso.plugin_root key when neither CLAUDE_PLUGIN_ROOT nor config entry is available
  Verify: unset CLAUDE_PLUGIN_ROOT; REPO_ROOT=$(git rev-parse --show-toplevel); bash "$REPO_ROOT/templates/host-project/dso" tk 2>&1 | grep -q "dso.plugin_root"
