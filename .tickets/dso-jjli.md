---
id: dso-jjli
status: open
deps: []
links: []
created: 2026-03-22T16:56:07Z
type: bug
priority: 2
assignee: Joe Oakhart
---
# merge-to-main.sh 'merge' phase name misleads agents into thinking code is on main

The 'merge' phase of merge-to-main.sh performs a git merge of the worktree branch INTO main locally, but agents interpret 'merge phase complete' as meaning their code is already on main and accessible. In reality, the code still needs to be pushed (the 'push' phase). This naming confusion causes agents to skip or misunderstand the push step. The phase should be renamed to something clearer like 'local-merge' or 'integrate' to distinguish it from 'code is on main/remote'. Additionally, the push phase has a bug: it tries to push the current branch (the worktree branch) instead of main, failing when the worktree branch has no upstream.


## Notes

<!-- note-id: lmsgrnfe -->
<!-- timestamp: 2026-03-22T16:56:45Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

Scope expansion: all phases should be renamed for clarity, not just 'merge'. Agents also misinterpret the 'push' phase — it currently tries to push the current branch (worktree) instead of main, and agents don't understand which ref is being pushed. The full phase list (sync, merge, validate, push, archive, ci_trigger) should be reviewed and renamed to clearly communicate what each phase actually does from the agent's perspective. For example: 'merge' could become 'local-integrate', 'push' could become 'push-main-to-remote', etc.
