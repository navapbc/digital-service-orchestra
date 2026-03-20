---
id: dso-4ap3
status: open
deps: [dso-uqm6, dso-kiue, dso-1kul, dso-wmjr, dso-0zsx, dso-xdd8, dso-5ewd, dso-ul37]
links: []
created: 2026-03-20T15:57:37Z
type: task
priority: 2
assignee: Joe Oakhart
parent: dso-bugk
---
# Verify: grep -r workflow-config.conf plugins/ CLAUDE.md returns zero matches

Final verification task: confirm that all references to 'workflow-config.conf' have been eliminated from the in-scope file set.

Run the story's done-definition grep command and confirm it returns zero matches.

Steps:
1. Run: grep -r 'workflow-config.conf' plugins/ CLAUDE.md
   Expected: no output (zero matches)
2. If any matches remain: identify which file/task missed them, update the relevant ticket, and fix before marking this task complete
3. Also run validate.sh --ci to confirm no regressions (story done definition)
4. Check for semantic prose issues: grep -r 'workflow.config\|wf-config\|workflow_config' plugins/ CLAUDE.md for similar-name variants that may have been missed

TDD Requirement: N/A — this is a verification-only task with no code changes.

This task depends on all other dso-bugk tasks (uqm6, kiue, 1kul, wmjr, 0zsx, xdd8, 5ewd) being complete.

## Acceptance Criteria

- [ ] grep -r 'workflow-config.conf' plugins/ CLAUDE.md returns zero matches
  Verify: test $(grep -r 'workflow-config.conf' $(git rev-parse --show-toplevel)/plugins/ $(git rev-parse --show-toplevel)/CLAUDE.md 2>/dev/null | wc -l) -eq 0
- [ ] plugins/dso/docs/dso-config.example.conf exists (example file was renamed)
  Verify: test -f $(git rev-parse --show-toplevel)/plugins/dso/docs/dso-config.example.conf
- [ ] validate.sh --ci passes end-to-end
  Verify: bash $(git rev-parse --show-toplevel)/plugins/dso/scripts/validate.sh --ci

