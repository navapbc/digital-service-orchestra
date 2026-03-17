---
id: dso-42eg
status: open
deps: [dso-qii9]
links: []
created: 2026-03-17T18:34:22Z
type: epic
priority: 0
assignee: Joe Oakhart
jira_key: DIG-32
---
# Provide a method for client projects to conveniently call dso scripts 


## Notes

<!-- note-id: tdkmzxpn -->
<!-- timestamp: 2026-03-17T19:46:23Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->


## Context
Claude/agents and human developers working in host projects that use the DSO plugin need to call DSO scripts (tk, validate.sh, merge-to-main.sh, etc.) frequently. Today, every invocation requires constructing a full path via $CLAUDE_PLUGIN_ROOT/scripts/..., which is verbose, repetitive, and unreliable — CLAUDE_PLUGIN_ROOT isn't set in all contexts (skill markdown, SessionStart hooks) and can point to stale plugin cache versions. This forces skills, hooks, and scripts to each implement their own fallback logic, creating inconsistency and fragile path resolution across the codebase. The deliverable is a small POSIX shell dispatcher script (referred to below as 'the shim') and a companion sourceable library, both bootstrapped during one-time project setup.

## Success Criteria
1. A host project developer or agent can run any DSO script by invoking `.claude/scripts/dso <name> [args]`, which maps to $DSO_ROOT/scripts/<name> (e.g., `dso tk sync`, `dso validate.sh`). The shim exits with code 127 and a descriptive error if <name> does not match a file in $DSO_ROOT/scripts/.
2. The shim resolves DSO_ROOT by checking (1) $CLAUDE_PLUGIN_ROOT env var, then (2) dso.plugin_root key in workflow-config.conf, then (3) exiting with a descriptive error message — in that order.
3. A DSO hook or script can obtain DSO_ROOT by sourcing the shim in library mode (`source .claude/scripts/dso --lib`) and reading the exported DSO_ROOT variable, without depending on CLAUDE_PLUGIN_ROOT being set. Library mode exports only DSO_ROOT and produces no stdout.
4. The shim uses only POSIX-specified shell builtins and utilities (cd, pwd, dirname, command, git) — no readlink -f, realpath, or other GNU coreutils extensions — and resolves the correct absolute path on macOS (BSD), Ubuntu 22.04+, and WSL2/Ubuntu.
5. The shim works identically in git worktrees and the main repo checkout (uses git rev-parse --show-toplevel to locate workflow-config.conf).
6. After running setup once, `dso tk --help` succeeds in a new shell session without any additional export, source, or PATH modification.
7. A cross-context smoke test (included in the DSO plugin's test suite) invokes the shim from the repo root, a subdirectory, and a worktree, asserting exit 0 each time.
8. All skill markdown files, workflow docs (CLAUDE.md, COMMIT-WORKFLOW.md, etc.), and QUICK-REF content that instruct agents to invoke DSO scripts are updated to use the shim (.claude/scripts/dso <name>) rather than $CLAUDE_PLUGIN_ROOT/scripts/<name>. Plugin-internal hooks (hooks.json configs) and shell scripts that self-locate via BASH_SOURCE are explicitly out of scope for this migration.

## Dependencies
- dso-qii9 (Create a setup skill) — owns setup orchestration; this epic owns the shim and library. The shim can also be set up manually.
- dso-6524 (Separate DSO plugin from DSO project) — broader P2 restructuring. This epic's cascading lookup can adopt any path contract dso-6524 establishes as an additional fallback tier.

## Approach
The shim template lives in the DSO plugin at templates/host-project/dso and is copied verbatim to .claude/scripts/dso during setup. Setup writes dso.plugin_root=<absolute-path> to workflow-config.conf. Plugin-internal hooks and self-locating scripts retain their existing CLAUDE_PLUGIN_ROOT/BASH_SOURCE patterns.

