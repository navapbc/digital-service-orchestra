---
name: using-lockpick
description: Use when starting any conversation - establishes how to find and use skills, requiring Skill tool invocation before ANY response including clarifying questions
---

<EXTREMELY-IMPORTANT>
If you think there is even a 1% chance a skill might apply to what you are doing, you ABSOLUTELY MUST invoke the skill.

IF A SKILL APPLIES TO YOUR TASK, YOU DO NOT HAVE A CHOICE. YOU MUST USE IT.

This is not negotiable. This is not optional. You cannot rationalize your way out of this.
</EXTREMELY-IMPORTANT>

## How to Access Skills

**In Claude Code:** Use the `Skill` tool. When you invoke a skill, its content is loaded and presented to you—follow it directly. Never use the Read tool on skill files.

**When the Skill tool returns `Successfully loaded skill`:** The skill content IS now available — it appears in a `<system-reminder>` block in your context (look for "The following skills were invoked in this session"). Do NOT invoke the Skill tool a second time. Do NOT use the Read tool to read the skill file. The content is in context; proceed to follow it directly.

**If the Skill tool fails with "Unknown skill":** Read the skill file directly at `plugins/dso/skills/<skill-name>/SKILL.md` (strip the `dso:` prefix to get the directory name) and follow its instructions. Do NOT stop or report failure — the fallback is always available. This is a session-state issue (skill registry drift under long context), not a missing-skill problem.

## The Rule

**Invoke relevant or requested skills BEFORE any response or action.** Even a 1% chance a skill might apply means that you should invoke the skill to check. If an invoked skill turns out to be wrong for the situation, you don't need to use it.

## Skill Priority

Process skills first (`/dso:brainstorm`, `/dso:fix-bug` for bug fixes) — then implementation skills (`/dso:sprint`, `/dso:implementation-plan`).

## Skill Types

**Rigid** (`/dso:fix-bug`, `verification-before-completion`): follow exactly. **Flexible** (patterns): adapt to context. The skill itself tells you which.

## User Instructions

Instructions say WHAT, not HOW. "Add X" or "Fix Y" doesn't mean skip workflows.

## Feature Intent Detection

When a user message signals intent to build something new, invoke `/dso:brainstorm` before entering plan mode or selecting implementation skills.

**Explicit signals**: "new feature", "create an epic", "I want to build", "add a capability".

**Implicit signals**: proposals for significant new capabilities or architectural changes.

**Action**: Detect signal → invoke `/dso:brainstorm` first. Do not jump to `/dso:sprint` or `/dso:implementation-plan` without brainstorming first.

## When No Skill Matches

**Silent Investigation**: Before asking anything, read code, tickets (`.claude/scripts/dso ticket show`), git history, CLAUDE.md, and memory to gather context that already exists.

**Confidence Test**: Ask yourself: can I state in one sentence what I will do and why? If yes, proceed. If no, enter the clarification loop.

**Clarification Loop**: Ask one question per message. Use multiple-choice options when possible. Focus on one probing area at a time:

- **(a) Intent** — what outcome does the user want? Ask what success looks like.
- **(b) Scope** — how much should change, what else might be affected? Ask what boundary the change should stay within.
- **(c) Risks** — what could break or go wrong, what constraints exist? Ask what concerns or side effects to avoid.

**Exit Condition**: Once the confidence test passes, proceed immediately. Do not request explicit confirmation.
