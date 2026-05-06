---
name: review-protocol
description: Use when a calling skill (e.g., /dso:implementation-plan, /dso:design-review, /dso:preplanning architectural-pattern check) needs to run a multi-perspective review of an artifact (plan, design, pattern). The caller passes subject, artifact, a perspectives list (each is a reviewer file), pass_threshold, start_stage, max_revision_cycles, and caller_id; this skill dispatches one sub-agent per perspective, scores on configured dimensions, detects conflicts between reviewers, runs a revision cycle up to max_revision_cycles, and returns JSON per the standardized REVIEW-SCHEMA. Not user-invocable directly — it is the shared review engine that calling skills delegate to instead of writing ad-hoc review logic.
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
