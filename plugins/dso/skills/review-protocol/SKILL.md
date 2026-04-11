---
name: review-protocol
description: Use when a skill needs structured multi-perspective review with conflict detection, revision cycles, and standardized JSON output — replaces ad-hoc mental reviews and custom sub-agent review logic
allowed-tools: Read, Write, Edit, Glob, Grep, Bash
---

<SUB-AGENT-GUARD>
This skill requires the Agent tool to dispatch sub-agents. Before proceeding, check whether the Agent tool is available in your current context. If you cannot use the Agent tool (e.g., because you are running as a sub-agent dispatched via the Task tool), STOP IMMEDIATELY and return this error to your caller:

"ERROR: /dso:review-protocol cannot run in sub-agent context — it requires the Agent tool to dispatch its own sub-agents. Invoke this skill directly from the orchestrator instead."

Do NOT proceed with any skill logic if the Agent tool is unavailable.
</SUB-AGENT-GUARD>

# Review Protocol

## Output Schema

See `${CLAUDE_PLUGIN_ROOT}/docs/REVIEW-SCHEMA.md` for the standardized JSON output schema used by all review protocols.

## Your task

1. Read the file at `${CLAUDE_PLUGIN_ROOT}/docs/workflows/REVIEW-PROTOCOL-WORKFLOW.md`
2. Execute every step in order.
3. Pass through any arguments received (subject, artifact, perspectives, pass_threshold, start_stage, max_revision_cycles, caller_id).
