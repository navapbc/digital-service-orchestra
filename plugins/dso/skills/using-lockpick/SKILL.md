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

## The Rule

**Invoke relevant or requested skills BEFORE any response or action.** Even a 1% chance a skill might apply means that you should invoke the skill to check. If an invoked skill turns out to be wrong for the situation, you don't need to use it.

```dot
digraph skill_flow {
    "User message received" [shape=doublecircle];
    "About to EnterPlanMode?" [shape=doublecircle];
    "Already brainstormed?" [shape=diamond];
    "Invoke /dso:brainstorm skill" [shape=box];
    "Might any skill apply?" [shape=diamond];
    "Invoke Skill tool" [shape=box];
    "Announce: 'Using [skill] to [purpose]'" [shape=box];
    "Has checklist?" [shape=diamond];
    "Create TaskCreate task per item" [shape=box];
    "Follow skill exactly" [shape=box];
    "Respond (including clarifications)" [shape=doublecircle];

    "About to EnterPlanMode?" -> "Already brainstormed?";
    "Already brainstormed?" -> "Invoke /dso:brainstorm skill" [label="no"];
    "Already brainstormed?" -> "Might any skill apply?" [label="yes"];
    "Invoke /dso:brainstorm skill" -> "Might any skill apply?";

    "User message received" -> "Might any skill apply?";
    "Might any skill apply?" -> "Invoke Skill tool" [label="yes, even 1%"];
    "Might any skill apply?" -> "Respond (including clarifications)" [label="definitely not"];
    "Invoke Skill tool" -> "Announce: 'Using [skill] to [purpose]'";
    "Announce: 'Using [skill] to [purpose]'" -> "Has checklist?";
    "Has checklist?" -> "Create TaskCreate task per item" [label="yes"];
    "Has checklist?" -> "Follow skill exactly" [label="no"];
    "Create TaskCreate task per item" -> "Follow skill exactly";
}
```

## Red Flags

These thoughts mean STOP—you're rationalizing:

| Thought | Reality |
|---------|---------|
| "This is just a simple question" | Questions are tasks. Check for skills. |
| "I need more context first" | Skill check comes BEFORE clarifying questions. |
| "Let me explore the codebase first" | Skills tell you HOW to explore. Check first. |
| "I can check git/files quickly" | Files lack conversation context. Check for skills. |
| "Let me gather information first" | Skills tell you HOW to gather information. |
| "This doesn't need a formal skill" | If a skill exists, use it. |
| "I remember this skill" | Skills evolve. Read current version. |
| "This doesn't count as a task" | Action = task. Check for skills. |
| "The skill is overkill" | Simple things become complex. Use it. |
| "I'll just do this one thing first" | Check BEFORE doing anything. |
| "This feels productive" | Undisciplined action wastes time. Skills prevent this. |
| "I know what that means" | Knowing the concept ≠ using the skill. Invoke it. |

## Skill Priority

Process skills first (`/dso:brainstorm`, `/dso:fix-bug` for bug fixes, `/dso:tdd-workflow` for new feature TDD) — then implementation skills (`/dso:sprint`, `/dso:implementation-plan`).

## Skill Types

**Rigid** (`/dso:fix-bug`, `/dso:tdd-workflow`, `verification-before-completion`): follow exactly. **Flexible** (patterns): adapt to context. The skill itself tells you which.

## Execution Discipline

**Follow skills and workflows exactly as written. Do not take shortcuts.**

When a skill or workflow specifies steps, phases, gates, or procedures, execute every one in order. Do not:

- Skip steps you consider "unnecessary" or "obvious"
- Combine steps to "save time"
- Substitute your own judgment for a documented gate or check
- Omit a validation step because "the change is small"
- Rationalize that "this particular case doesn't need" a required step

**Why this matters**: Skills encode hard-won lessons from production failures. Every gate exists because skipping it caused a real problem. Config masking hid bugs for weeks because a validation step was conditional instead of mandatory. Tests passed locally but failed in CI because a smoke test was skipped. The cost of running an "unnecessary" step is seconds; the cost of skipping a necessary one is hours of debugging.

**If a skill step seems wrong or outdated**, flag it to the user — do not silently skip it. The correct response to a bad instruction is to raise it, not to ignore it.

## User Instructions

Instructions say WHAT, not HOW. "Add X" or "Fix Y" doesn't mean skip workflows.

## When No Skill Matches

When no skill clearly applies, do not ask clarifying questions immediately. Follow this loop:

**Silent Investigation**: Before asking anything, do silent investigation — use Read, Grep, ticket show (tickets), git history, CLAUDE.md, and memory to gather context that already exists.

**Confidence Test**: Ask yourself: can I state in one sentence what I will do and why? If you can articulate what the action is and why it addresses the user's goal as a single declarative statement, proceed. If you cannot, enter the clarification loop.

**Clarification Loop**: Ask one question per message. Use multiple-choice options whenever possible. Use "tell me more" follow-ups to drill down. Focus each question on one of three labeled probing areas:

- **(a) Intent** — what outcome does the user want? (Intent probe: ask what success looks like)
- **(b) Scope** — how much should change, what else might be affected? (Scope probe: ask what boundary the change should stay within)
- **(c) Risks** — what could break or go wrong, what constraints exist? (Risks probe: ask what concerns or side effects to avoid)

Exit the loop as soon as the confidence test passes — do not ask more questions than necessary.

**Proceed**: Once the confidence test passes, proceed immediately. Do not request explicit confirmation.

**Dogfooding Evaluation**: Define *intent-match* as: the agent's final action matches the user's actual intent on the first attempt. Log each clarification loop entry and score intent-match after each interaction. Target: 80% intent-match rate across 20+ interactions. This measures success of the clarification loop.
