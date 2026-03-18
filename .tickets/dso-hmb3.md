---
id: dso-hmb3
status: closed
deps: []
parent: dso-6524
links: []
created: 2026-03-18T18:47:45Z
type: story
priority: 1
assignee: Joe Oakhart
---
# As a DSO developer, plugin files live under plugins/dso/ so project-only files at the repo root are not distributed when the plugin is installed


## Notes

**2026-03-18T18:48:28Z**


## What
Move `skills/`, `hooks/`, `commands/`, `scripts/`, `docs/`, and `.claude-plugin/plugin.json` from the repo root to `plugins/dso/`. Update `.claude-plugin/marketplace.json` source entry to use `git-subdir: "plugins/dso"`. Commit `workflow-config.conf` to the repo root. Update `.pre-commit-config.yaml` hook paths to reflect new `plugins/dso/hooks/` location. Update `scripts/check-skill-refs.sh` glob patterns to scan `plugins/dso/` paths.

## Why
The plugin root and repo root are currently identical — every plugin installation inadvertently distributes development artifacts (`.tickets/`, `tests/`, `workflow-config.conf`, `CLAUDE.md`) that clients should never receive. This story delivers the structural separation that all other stories depend on.

## Scope
IN: Physical file move of 5 directories + plugin.json; marketplace.json source entry update; .pre-commit-config.yaml hook path update; workflow-config.conf committed to root; check-skill-refs.sh glob patterns updated
OUT: CLAUDE.md script/hook/docs reference updates (dso-zse0); dso-setup.sh smoke test (dso-7idt); examples/CLAUDE.md.example creation (dso-zse0)

## Done Definitions
- When this story is complete, `ls plugins/dso/` shows `skills/`, `hooks/`, `commands/`, `scripts/`, `docs/`, `.claude-plugin/`; repo root no longer contains these directories at top level
  ← Satisfies: "plugins/dso/ contains expected dirs; repo root does not"
- When this story is complete, `git ls-files workflow-config.conf` returns `workflow-config.conf` from repo root (non-empty file)
  ← Satisfies: "workflow-config.conf is committed and present in worktrees"
- When this story is complete, `git worktree add ../dso-worktree main` succeeds and `ls ../dso-worktree/workflow-config.conf` returns the file without any symlink or manual copy step
  ← Satisfies: "DSO developer can create a git worktree and workflow-config.conf is present"
- When this story is complete, `.claude-plugin/marketplace.json` source field uses `git-subdir` pointing to `plugins/dso/`
  ← Satisfies: "marketplace.json updated with git-subdir"
- When this story is complete, `bash plugins/dso/scripts/validate.sh --ci` exits 0 from the repo root
  ← Satisfies: "validate.sh --ci exits 0 after restructure" (merge gate)

## Considerations
- [Testing] check-skill-refs.sh currently scans repo-root paths — update its in-scope globs to cover `plugins/dso/skills/`, `plugins/dso/hooks/`, `plugins/dso/docs/`, `plugins/dso/commands/`; failure to do so silently stops /dso: qualification enforcement
- [Maintainability] Hook scripts that reference other hooks via relative paths must use `${CLAUDE_PLUGIN_ROOT}` — verify all hooks resolve correctly after move
- [Reliability] `.pre-commit-config.yaml` at repo root references `hooks/` entry points (e.g., `hooks/pre-commit-review-gate.sh`) that move to `plugins/dso/hooks/` — update this file as part of S1 scope or all git hooks break immediately
- [Reliability] Verify `plugins/dso/.claude-plugin/plugin.json` uses only relative paths (e.g., `./skills/`, `./hooks/`) — not absolute or repo-root-relative paths; a broken plugin.json path would be invisible to done-definition checks
- [Reliability] S1 moves 6+ top-level directories — coordinate timing to ensure no in-flight worktree branches exist when this commits; any existing worktrees become invalid after this merge


**2026-03-18T19:35:15Z**

COMPLEXITY_CLASSIFICATION: COMPLEX
