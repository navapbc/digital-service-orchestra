---
name: review-protocol
description: Use when a skill needs structured multi-perspective review with conflict detection, revision cycles, and standardized JSON output — replaces ad-hoc mental reviews and custom sub-agent review logic
allowed-tools: Read, Write, Edit, Glob, Grep, Bash
---

<SUB-AGENT-GUARD>
Requires Agent tool. If running as a sub-agent (Agent tool unavailable), STOP and return: "ERROR: /dso:review-protocol requires Agent tool; invoke from orchestrator."
</SUB-AGENT-GUARD>

# Review Protocol

## Output Schema

See `${CLAUDE_PLUGIN_ROOT}/docs/REVIEW-SCHEMA.md` for the standardized JSON output schema used by all review protocols.

## Your task

1. Read the file at `${CLAUDE_PLUGIN_ROOT}/docs/workflows/REVIEW-PROTOCOL-WORKFLOW.md`
2. Execute every step in order.
3. Pass through any arguments received (subject, artifact, perspectives, pass_threshold, start_stage, max_revision_cycles, caller_id).
