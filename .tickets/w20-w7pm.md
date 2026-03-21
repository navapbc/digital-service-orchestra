---
id: w20-w7pm
status: open
deps: []
links: []
created: 2026-03-21T21:23:47Z
type: bug
priority: 1
assignee: Joe Oakhart
tags: [agent-compliance, validate-work]
---
# Validation sub-agents in /dso:validate-work fix errors instead of only reporting them

## Bug
During sprint Phase 7 post-epic validation, the Local Validation sub-agent (Sub-Agent 1) dispatched by /dso:validate-work actively fixed two issues it found:
1. A legacy plugin root reference in resolve-conflicts SKILL.md
2. An event timestamp collision in ticket event scripts

The /dso:validate-work skill explicitly states 'Never fix issues — this skill is verification-only' and 'Never modify code — read-only operations only'. The sub-agent prompt (local-validation.md) says 'Do NOT fix any issues — only report pass/fail for each check.'

## Expected Behavior
Sub-agents should report findings only. No Edit, Write, or Bash commands that modify files should be used.

## Root Cause Hypothesis
The sub-agent is dispatched as general-purpose with full tool access. It sees failures and autonomously decides to fix them despite the prompt instructions. The prompt-level prohibition is insufficient — the agent rationalizes around it.

## Suggested Fix
Either:
1. Use a sub-agent type that lacks Edit/Write/Bash tools (but this conflicts with needing Bash to run validation commands)
2. Add a PreToolUse hook that blocks Edit/Write during validate-work execution
3. Add stronger framing in the prompt (e.g., 'You will be terminated if you modify any files')

## File Impact
- plugins/dso/skills/validate-work/prompts/local-validation.md
- Potentially plugins/dso/skills/validate-work/SKILL.md (sub-agent dispatch config)

