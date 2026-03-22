---
id: dso-daox
status: open
deps: [dso-mac2, dso-pu9c]
links: []
created: 2026-03-22T23:02:04Z
type: story
priority: 2
assignee: Joe Oakhart
parent: dso-d63r
---
# As a DSO practitioner, the brainstorm approval gate gives me control over research and scenario analysis cycles and records a planning-intelligence log

## Description

**What**: Replace the existing brainstorm spec approval step with a 4-option gate that lets the practitioner approve, re-trigger research or scenario analysis, or pause for discussion. Each invocation records a structured planning-intelligence log entry in the epic spec.
**Why**: Practitioners need control over when and how much research and scenario analysis runs. The log entry enables before/after comparison across epics to validate whether these capabilities reduce preventable planning failures.
**Scope**:
- IN: 4-option approval gate via AskUserQuestion, re-run routing for each option, planning-intelligence log entry in epic spec, correct labeling of initial-run vs. re-run options
- OUT: Research phase implementation (separate story), scenario analysis implementation (separate story), preplanning research (separate story)

## Done Definitions

- When this story is complete, the spec approval gate presents four options: (a) Approve — advances to fidelity review, (b) Perform red/blue team review cycle — re-runs scenario analysis and re-presents the gate, (c) Perform additional web research — re-runs the research phase and re-presents the gate, (d) Let's discuss more — pauses the skill for conversational review before re-presenting the gate
  ← Satisfies: "The spec approval gate presents four options via AskUserQuestion"
- When this story is complete, each brainstorm invocation records a structured planning-intelligence log entry in the epic spec containing: which bright-line conditions triggered (or "none"), whether red/blue team ran and how many scenarios survived the blue team filter, and whether the practitioner requested additional cycles via the gate
  ← Satisfies: "Each brainstorm invocation records a structured planning-intelligence log entry"
- When this story is complete, the approval gate correctly labels options as initial runs vs. re-runs based on whether research and scenario analysis have already executed in this brainstorm session, and the planning-intelligence log accurately records the state (not triggered / triggered / re-triggered via gate)
- Unit tests written and passing for all new or modified logic

## Considerations

- [Maintainability] Gate replaces the existing approval step in brainstorm — must integrate cleanly with existing Phase 2 flow
- [Performance] Re-run cycles multiply token cost — define whether re-runs replace or append to existing sections and bound total cost to prevent context limit issues

## Escalation Policy

**Escalation policy**: Escalate to the user whenever you do not have high confidence in your understanding of the work, approach, or intent. "High confidence" means clear evidence from the codebase or ticket context — not inference or reasonable assumption. When in doubt, stop and ask rather than guess.

