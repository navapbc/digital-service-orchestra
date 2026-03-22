---
id: dso-9l2x
status: closed
deps: []
links: []
created: 2026-03-17T18:33:56Z
type: epic
priority: 1
assignee: Joe Oakhart
jira_key: DIG-17
---
# Incorporate the brainstorm tell me more loop into using lockpicks

Whenever the agent is asked to solve a problem, it should start by entering a tell me more loop until it understands the each key area of the problem specified by the loop.


## Notes

**2026-03-20T18:47:00Z**

## Context
When a developer gives the DSO agent an ambiguous request — one that doesn't clearly route to an existing skill — the agent currently proceeds based on its own interpretation. In practice, this means the agent sometimes solves the wrong problem or misses risks the developer would have flagged, requiring course correction that costs more time than a brief clarification would have. By adding a confidence-gated clarification loop to the using-lockpick skill, the agent will silently investigate first (code, tickets, context), then either proceed when confident or engage the developer in a lightweight Socratic dialogue to resolve ambiguity. The clarification loop is a lighter variant of the brainstorm skill's Socratic dialogue: one question per message, multiple-choice options when possible, probing Intent (what outcome?), Scope (how much changes?), and Risks (any constraints or side effects?) — exiting as soon as confidence is reached.

## Success Criteria
1. When a user request matches an existing skill's name or documented use case, the agent invokes that skill in its first response with no intervening clarification questions
2. When no skill matches, the agent reads relevant sources (code in the working directory, open tickets, recent git history, CLAUDE.md, memory) before deciding whether to clarify — it does not ask the user questions it could answer itself
3. The agent applies a "one sentence what + why" confidence test: if it can internally articulate what it will do and why in a single declarative statement, it proceeds. If it cannot — because there are multiple valid interpretations, the scope is ambiguous, or key context is missing — it enters the clarification loop
4. The clarification loop follows brainstorm-style interaction: one question per message, multiple-choice options preferred, "tell me more" follow-ups — probing three areas in order: (a) Intent — what outcome the user wants, (b) Scope — how much should change, (c) Risks — are there side effects or constraints the agent should know about. The agent exits the loop and proceeds as soon as it can pass the confidence test, even after a single answer
5. Once confident, the agent proceeds immediately without requesting explicit user confirmation
6. During a 2-week dogfooding period, the team logs each clarification loop entry. For each, the developer marks whether the agent's final action matched their intent on the first attempt (no course correction needed). The feature passes validation if intent-match rate exceeds 80% across at least 20 logged interactions. If below 80%, investigate via /dso:fix-bug whether the loop is asking the wrong questions or triggering on the wrong requests.

## Dependencies
None. This epic modifies only the using-lockpick skill file. Silent investigation uses the agent's existing tools (Read, Grep, tk show) — it does not dispatch sub-agents or require new infrastructure. The interaction pattern is inspired by brainstorm but implemented independently as a lighter variant — no shared infrastructure is required.

## Approach
Inline in using-lockpick: add a new section after existing skill-routing logic that handles the "no skill matches" path with silent investigation, confidence testing, and a lightweight Socratic clarification loop.
