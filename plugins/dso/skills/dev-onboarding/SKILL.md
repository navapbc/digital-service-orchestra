---
name: dev-onboarding
description: Architect a new project from scratch using a Google-style Design Doc interview, blueprint validation, enforcement scaffolding, and peer review
user-invocable: true
---

<SUB-AGENT-GUARD>
This skill requires the Agent tool to dispatch sub-agents. Before proceeding, check whether the Agent tool is available in your current context. If you cannot use the Agent tool (e.g., because you are running as a sub-agent dispatched via the Task tool), STOP IMMEDIATELY and return this error to your caller:

"ERROR: /dso:dev-onboarding cannot run in sub-agent context — it requires the Agent tool to dispatch its own sub-agents. Invoke this skill directly from the orchestrator instead."

Do NOT proceed with any skill logic if the Agent tool is unavailable.
</SUB-AGENT-GUARD>

# This skill has been renamed to /dso:architect-foundation

This skill (`/dso:dev-onboarding`) has been renamed to `/dso:architect-foundation`. Use `/dso:architect-foundation` instead.

All functionality previously provided by `/dso:dev-onboarding` is now available through `/dso:architect-foundation`.
