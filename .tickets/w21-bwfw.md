---
id: w21-bwfw
status: open
deps: [w21-54wx]
links: []
created: 2026-03-20T03:28:20Z
type: epic
priority: 1
assignee: Joe Oakhart
---
# Ticket system v3 — Jira bridge and LLM-optimized output


## Notes

**2026-03-20T03:28:59Z**

## Context
The ticket system needs to stay synchronized with Jira (the team's external project tracker) and provide token-efficient output for LLM agents that interact with tickets frequently. Currently, Jira sync requires local ACLI credentials and runs synchronously, slowing down developer workflows. Moving the Jira bridge to GitHub Actions eliminates local dependencies and runs asynchronously. LLM-optimized output reduces token consumption by 60-70% per ticket read, which compounds across hundreds of agent interactions per session.

## Success Criteria
1. A GitHub Actions workflow watches the tickets branch and creates/updates Jira issues for new CREATE, STATUS, and COMMENT events using ACLI, writing SYNC events that map local IDs to Jira issue keys
2. ticket sync pulls SYNC events from the remote tickets branch, making Jira keys available locally via the reducer
3. ticket show <id> --format=llm outputs minified single-line JSON with shortened keys, stripped nulls, and no verbose timestamps — at least 50% token reduction compared to standard output
4. ticket list --format=llm outputs JSONL (one ticket per line) for pipeline-friendly agent consumption
5. Jira bridge processes new events within 2 minutes of push to the tickets branch
6. No local ACLI installation or Jira credentials are required for developers — all Jira operations happen in CI

## Dependencies
w21-54wx (sync infrastructure)

## Approach
GitHub Actions workflow triggered on tickets branch push. ACLI for Jira operations. SYNC events for bidirectional ID mapping. --format=llm flag for token-optimized output.
