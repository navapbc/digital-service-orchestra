---
id: dso-7idt
status: closed
deps: [dso-hmb3]
parent: dso-6524
links: []
created: 2026-03-18T18:47:52Z
type: story
priority: 1
assignee: Joe Oakhart
---
# As a client project developer installing DSO, dso-setup.sh works correctly from its new location in plugins/dso/scripts/


## Notes

**2026-03-18T18:49:26Z**


## What
Verify and update dso-setup.sh (now at plugins/dso/scripts/dso-setup.sh) path assumptions after the restructure. Run a smoke test to confirm the pre-commit hook and shim install correctly into a client project.

## Why
The installation contract is the most user-visible part of the plugin. If dso-setup.sh breaks after the restructure, client projects cannot install or update DSO. This story confirms the distribution boundary works end-to-end.

## Scope
IN: Audit and fix any hardcoded repo-root path assumptions in dso-setup.sh; manual smoke test (git init tmpdir, run dso-setup.sh, verify pre-commit hook plus shim plus shim execution)
OUT: CLAUDE.md updates (dso-zse0); behavioral changes to dso-setup.sh beyond path fixes

## Done Definitions
- When this story is complete, running bash plugins/dso/scripts/dso-setup.sh against a git-init temp directory exits 0 and produces a working pre-commit hook and executable shim at .claude/scripts/dso in the target directory
  <- Satisfies: smoke test (a) and (b)
- When this story is complete, CLAUDE_PLUGIN_ROOT=$(pwd)/plugins/dso bash shim validate.sh --help exits 0 from the repo root
  <- Satisfies: smoke test (c): shim resolves and forwards correctly

## Considerations
- [Reliability] dso-setup.sh may hardcode paths relative to its former repo-root location — run a grep scan for scripts/, hooks/, skills/ in dso-setup.sh before making targeted fixes
- [Reliability] Verify that the marketplace.json git-subdir value (plugins/dso) aligns with what Claude Code sets as CLAUDE_PLUGIN_ROOT in production — the smoke test manually overrides this value; confirm real Claude Code plugin loading would set the same path


<!-- note-id: mbzxhdik -->
<!-- timestamp: 2026-03-18T21:53:28Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CLOSE REASON: Fixed: dso-setup.sh already works correctly from plugins/dso/scripts/; all 26 smoke tests pass; CLAUDE_PLUGIN_ROOT shim forwarding verified
