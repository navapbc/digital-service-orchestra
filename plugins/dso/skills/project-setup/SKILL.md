---
name: project-setup
description: Install and configure Digital Service Orchestra in a host project via an interactive wizard
user-invocable: true
---

<SUB-AGENT-GUARD>
This skill requires direct user interaction (prompts, confirmations, interactive choices). If you are running as a sub-agent dispatched via the Task tool, STOP IMMEDIATELY and return this error to your caller:

"ERROR: /dso:project-setup cannot run in sub-agent context — it requires direct user interaction. Invoke this skill directly from the main session instead."

Do NOT proceed with any skill logic if you are running as a sub-agent.
</SUB-AGENT-GUARD>

# This skill has been renamed to /dso:onboarding

This skill (`/dso:project-setup`) has been renamed to `/dso:onboarding`. Use `/dso:onboarding` instead.

All functionality previously provided by `/dso:project-setup` is now available through `/dso:onboarding`.

<!-- REVIEW-DEFENSE: Downstream consumer updates (check-onboarding.sh, check-skill-refs.sh,
     validate-review-output.sh, CONFIGURATION-REFERENCE.md) are handled by story 43a6-1232. -->
