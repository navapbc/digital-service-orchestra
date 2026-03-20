---
id: dso-psan
status: open
deps: [w22-45i1, w22-5z9r]
links: []
created: 2026-03-19T18:20:58Z
type: epic
priority: 1
assignee: Joe Oakhart
jira_key: DIG-47
---
# Add dev-onboarding and design-onboarding to setup

## Context
When a new project runs /dso:project-setup, the setup wizard configures DSO infrastructure (workflow-config, hooks, shim) but stops there. Two valuable follow-up skills — /dso:dev-onboarding (architecture blueprint, enforcement scaffolding, architectural tests) and /dso:design-onboarding (DESIGN_NOTES.md with visual language, user archetypes, golden paths) — exist but must be discovered and invoked manually. Most new projects skip them, leaving the project without architectural guardrails or a design system foundation until someone stumbles on the skills later.

## Success Criteria
1. After project-setup completes its existing steps, the user is presented with a prompt offering to run available onboarding skills, with descriptive option labels (e.g., "Set up architecture and design foundations" / "Skip for now")
2. Each option includes a brief description of what the skill produces so the user can make an informed choice
3. When both skills are available, 4 options are presented: run both (recommended), architecture only, design only, or skip
4. When only one skill is available (the other's artifacts already exist), the prompt changes to a yes/no question for that single skill
5. Selecting the combined option runs dev-onboarding first, then design-onboarding, in sequence
6. Selecting skip ends setup with no additional steps — the existing behavior is preserved
7. The onboarding skills remain independently invocable — the setup integration is a convenience, not a requirement
8. If an onboarding skill's output artifacts already exist in the project (e.g., DESIGN_NOTES.md for design-onboarding, ARCH_ENFORCEMENT.md for dev-onboarding), that skill is excluded — if both have already been run, the prompt is skipped entirely

## Dependencies
- Both /dso:dev-onboarding and /dso:design-onboarding are existing, stable skills not being modified by any other epic. This epic only adds a prompt to invoke them from setup.
- dso-kknz (Move workflow config to .claude/dso-config.conf) is a sequencing consideration: setup currently writes workflow-config.conf, and dso-kknz changes the config path. Recommend executing dso-psan before or in parallel with awareness.

## Approach
Add a Step 7 to the existing /dso:project-setup skill that checks for existing onboarding artifacts, dynamically builds the appropriate prompt (4-option when both available, yes/no when one available, skip when neither), and invokes the chosen skill(s) inline.

