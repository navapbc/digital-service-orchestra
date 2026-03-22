---
id: dso-d63r
status: open
deps: []
links: []
created: 2026-03-22T22:54:02Z
type: epic
priority: 2
assignee: Joe Oakhart
---
# Planning Intelligence — Research & Scenario Hardening


## Notes

<!-- note-id: fx4ud8rc -->
<!-- timestamp: 2026-03-22T22:54:20Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->


## Context
DSO practitioners using `/dso:brainstorm` and `/dso:preplanning` regularly discover critical edge cases and missing context that the agent and sub-agent review process failed to catch. When these gaps slip through to implementation, they produce serious bugs in completed epics — bugs that were preventable with more thorough upfront analysis. Separately, when research and investigation tasks are deferred to sprint execution, agents diverge from user intent because they lack the context needed to make good decisions autonomously. The scenario analysis targets spec-level gaps — ambiguous edge cases, unstated assumptions, and missing failure modes — not implementation defects that testing would catch. This epic adds two capabilities to the planning workflow: (1) web research triggered by defined conditions, agent judgment, or user request during brainstorm and preplanning, and (2) red/blue team scenario analysis during brainstorm that stress-tests the epic spec against hypothetical usage scenarios scaled to the feature's complexity. Both capabilities share the same approval gate and output format (structured sections in epic/story specs), making them a coherent unit of delivery. This epic supersedes three existing epics: dso-sq4k (web research triggers in brainstorm/preplanning — fully absorbed by criteria 1, 4, 6), dso-lqyw (integrating WebSearch into planning decisions — fully absorbed by criteria 1, 6), and w21-chse (hypothetical scenario analysis during epic planning — fully absorbed by criteria 2, 3). All three will be closed when this epic is created.

## Success Criteria
1. `/dso:brainstorm` includes a research phase that triggers on defined bright-line conditions (e.g., unfamiliar patterns, ambiguous tradeoffs, prompt engineering tasks), agent judgment for unanticipated cases, or user requests — using WebSearch/WebFetch to incorporate prior art, best practices, and expert insights into the epic spec
2. `/dso:brainstorm` includes a red/blue team scenario analysis phase that generates hypothetical usage scenarios (timeouts, race conditions, conflicts, out-of-order operations, misuse, first-time setup, environment configuration, CI/CD integration) scaled to the epic's complexity, with a blue team filter that drops scenarios impossible given the codebase and proposed design
3. The spec approval gate presents four options via AskUserQuestion: (a) Approve — advances to fidelity review, (b) Perform red/blue team review cycle — re-runs scenario analysis and re-presents the gate, (c) Perform additional web research — re-runs the research phase and re-presents the gate, (d) Let's discuss more — pauses the skill for conversational review before re-presenting the gate
4. `/dso:preplanning` includes a story-level research phase that fires when decomposition reveals gaps requiring investigation (e.g., a story depends on an external API whose behavior is undocumented, a story assumes a data format not described in the epic context, or agent confidence on a key implementation decision is low), resolving them before handing off to sprint execution
5. After brainstorm completes, the epic spec contains a dedicated Research Findings section (if research was triggered) and a Scenario Analysis section (if red/blue team ran), each with structured summaries; after preplanning completes, each story spec that triggered story-level research contains a Research Notes section — presence and non-emptiness of these sections is verifiable by inspecting the output artifact
6. The brainstorm skill file contains an enumerated list of at least three named bright-line trigger conditions, each with a one-sentence example illustrating when the condition applies, plus a paragraph describing how the agent decides to trigger research outside those explicit conditions
7. Each brainstorm invocation records a structured planning-intelligence log entry in the epic spec containing: which bright-line conditions triggered (or "none"), whether red/blue team analysis ran and how many scenarios survived the blue team filter, and whether the practitioner requested additional research or scenario cycles via the approval gate — enabling before/after comparison across epics without requiring a separate tracking mechanism

## Scope
In scope: modifications to `/dso:brainstorm` (research phase, scenario analysis, approval gate) and `/dso:preplanning` (story-level research phase). Out of scope: changes to `/dso:implementation-plan` or `/dso:sprint` (they consume the enriched specs passively), runtime/CI integration, and review-layer changes (covered by separate epics w21-ovpn, w21-ykic).

## Dependencies
None

## Approach
Extend `/dso:brainstorm` with two new phases — web research (triggered by bright-line conditions, agent judgment, or user request) and red/blue team scenario analysis (scaled to complexity) — plus a 4-option approval gate before fidelity review. Extend `/dso:preplanning` with a lighter research phase that fires only when story decomposition surfaces gaps. All findings flow into epic/story specs so downstream skills inherit the context automatically.

