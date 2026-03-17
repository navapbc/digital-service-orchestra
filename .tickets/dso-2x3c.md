---
id: dso-2x3c
status: open
deps: [dso-awoz]
links: []
created: 2026-03-17T19:51:57Z
type: story
priority: 1
assignee: Joe Oakhart
parent: dso-42eg
---
# As a Claude agent in a host project, I receive consistent DSO script invocation instructions across all skills and workflow docs


## Notes

<!-- note-id: iit22jji -->
<!-- timestamp: 2026-03-17T19:53:08Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

## What
Migrate all skill and workflow doc references from `$CLAUDE_PLUGIN_ROOT/scripts/<name>` to `.claude/scripts/dso <name>` so agents receive consistent invocation instructions.

## Why
After the shim exists, all instructions to agents should use it. Leaving old $CLAUDE_PLUGIN_ROOT/scripts/ patterns creates inconsistency and means agents may still use the fragile pattern this epic was designed to fix.

## Scope
IN: All `skills/*/SKILL.md` files; workflow docs (`docs/workflows/*.md`, `CLAUDE.md`, `COMMIT-WORKFLOW.md`); any other instruction-layer markdown that tells agents to invoke DSO scripts. Replace `$CLAUDE_PLUGIN_ROOT/scripts/<name>` and `${CLAUDE_PLUGIN_ROOT}/scripts/<name>` with `.claude/scripts/dso <name>`. Include a verification grep step confirming zero remaining references.
OUT: Plugin-internal `hooks/hooks.json` configs (keep ${CLAUDE_PLUGIN_ROOT} — expanded by Claude Code's hook executor); plugin shell scripts that self-locate via BASH_SOURCE; these are explicitly not in scope.

## Done Definitions
- When this story is complete, `grep -r 'CLAUDE_PLUGIN_ROOT/scripts/' skills/ docs/workflows/ CLAUDE.md` returns no matches
  ← Satisfies: 'All skill markdown files, workflow docs...are updated to use the shim'
- When this story is complete, all updated references use `.claude/scripts/dso <name>` syntax
  ← Satisfies: 'All skill markdown files...updated to use shim...rather than $CLAUDE_PLUGIN_ROOT/scripts/<name>'

## Considerations
- [Maintainability] 60+ files require migration — implementation plan should batch the changes and run the verification grep as a final step to confirm completeness
