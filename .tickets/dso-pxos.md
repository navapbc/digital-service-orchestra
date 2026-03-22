---
id: dso-pxos
status: open
deps: []
links: []
created: 2026-03-17T18:33:49Z
type: epic
priority: 1
assignee: Joe Oakhart
jira_key: DIG-13
---
# Update end-session to display a list of pre-existing failures encountered.

During end-session, before technical learnings, the agent should generate a list of failures the session encountered that were considered pre-existing or otherwise rationalized and not fixed. 
For each failure, the agent should answer the following questions: 
Did you observe the failure before or after changes were made on your worktree? If not, is this really a pre-existing failure?
Does a bug exist for the failure, as required by CLAUDE.md? If not, why didn't you create one?


## Notes

<!-- note-id: gpfgardo -->
<!-- timestamp: 2026-03-22T02:21:48Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

## Context
During sprint sessions, DSO agents encounter test failures, validation errors, and other issues that they classify as "pre-existing" or "infrastructure-related" and move on without fixing or creating bug tickets. Existing enforcement mechanisms (CLAUDE.md rules, inline guidance) haven't reliably prevented this because the agent is focused on its primary task and rationalizes skipping the issue in the moment. By adding a retrospective accountability step at session close — when the agent is no longer preoccupied — the agent reviews what it rationalized, answers structured accountability questions, and creates bug tickets for any untracked issues. This creates a natural checkpoint similar to the existing technical learnings step, where the agent can reflect honestly rather than defensively.

## Success Criteria
1. During end-session (before technical learnings in Step 2.8), the agent scans its own conversation context for signals of rationalized failures — error output it received, test failures it noted, validation issues it acknowledged, and any situation where it used phrases like "pre-existing", "infrastructure issue", "known issue", or "not related to this session" to justify not fixing something. This is a conversation-context scan, not an artifact-file read. The agent displays the results as a numbered list of every failure it encountered during the session that it did not fix.
2. For each failure in the list, the agent answers two accountability questions: (a) "Was this failure observed before or after changes were made on this worktree?" — determined by checking whether the failure reproduces on the main branch: git stash && <test-command> && git stash pop where <test-command> is resolved from the project's commands.test config key via read-config.sh. If the failure reproduces on main, it is pre-existing. If not, the agent's changes likely caused it. (b) "Does a bug ticket already exist for this failure?" — determined by searching open bug tickets via tk list --type=bug and checking for matching descriptions.
3. For any failure where no bug ticket exists, the agent creates one via tk create with appropriate priority and a description that includes when the failure was observed and why it wasn't fixed during the session.
4. The list is visible in the session summary output (Step 6 of end-session) so the human operator can review the agent's self-assessment and override if needed.
5. After 10 sessions using this feature, the human operator reviews end-session summaries and counts how many rationalized failures were surfaced vs. how many the operator independently noticed were missing. After each reviewed session, the operator records the spot-check result as a note on this epic ticket via tk add-note (format: Session <date>: surfaced <N>/<M> failures). The feature passes validation if the agent surfaces at least 80% of failures the operator would have flagged across the recorded sessions.

## Dependencies
None. This epic addresses a different failure mode than dso-t4k8 ("Don't cover up problems"): dso-t4k8 prevents agents from masking problems through code changes during implementation. This epic surfaces failures the agent acknowledged but chose not to fix or ticket — a retrospective accountability check, not an inline enforcement mechanism.

## Approach
Passive collection via end-session scan: at session close, the agent scans its conversation context for rationalized failures, displays them with accountability questions, and auto-creates bug tickets for gaps. No changes to sprint or other workflows — all logic lives in the end-session skill.
