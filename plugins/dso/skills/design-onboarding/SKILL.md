---
name: design-onboarding
description: Use when starting a new project or feature that needs a design system foundation, visual language definition, or when the team needs a shared "North Star" design document before implementation begins
user-invocable: true
---

<SUB-AGENT-GUARD>
This skill requires direct user interaction (prompts, confirmations, interactive choices). If you are running as a sub-agent dispatched via the Task tool, STOP IMMEDIATELY and return this error to your caller:

"ERROR: /dso:design-onboarding cannot run in sub-agent context — it requires direct user interaction. Invoke this skill directly from the main session instead."

Do NOT proceed with any skill logic if you are running as a sub-agent.
</SUB-AGENT-GUARD>

# This skill has been renamed to /dso:onboarding

This skill (`/dso:design-onboarding`) has been renamed to `/dso:onboarding`. Use `/dso:onboarding` instead.

All functionality previously provided by `/dso:design-onboarding` is now available through `/dso:onboarding`.
