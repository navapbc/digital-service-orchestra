---
name: review
description: Dispatch a code review of the current diff using the tiered LLM review workflow (light/standard/deep). Reads REVIEW-WORKFLOW.md and executes it inline. Use before committing or when CLAUDE.md says to run /dso:review. Trigger phrases include 'run a code review', 'review my changes', 'do a code review', '/dso:review', 'code review'.
user-invocable: true
allowed-tools: Read, Write, Edit, Glob, Grep, Bash, Agent
---

# Review

Shallow entry point for the DSO tiered code review workflow.

## What This Does

Loads and executes `${CLAUDE_PLUGIN_ROOT}/docs/workflows/REVIEW-WORKFLOW.md` inline. That document is the authoritative review workflow — this skill exists only to provide a `/dso:review` invocation surface. All review logic, tier selection, agent dispatch, and resolution rules are in REVIEW-WORKFLOW.md.

## Usage

```bash
/dso:review
```

Run from the orchestrator context (sprint, commit, or standalone) before committing.

## Instructions

**IMPORTANT**: Do NOT call the Skill tool again or re-invoke `/dso:review` recursively. Instead:

1. Read `${CLAUDE_PLUGIN_ROOT}/docs/workflows/REVIEW-WORKFLOW.md` now.
2. Execute its steps verbatim — starting from Step 1 (Capture Diff Hash).
3. Follow all HARD-GATE sections and enforcement.strategy gates.

The workflow file is the complete specification. If enforcement.strategy=ci is set, the workflow will instruct you to skip local review and emit .skipped markers instead.
