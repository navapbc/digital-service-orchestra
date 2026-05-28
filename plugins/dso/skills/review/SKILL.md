---
name: review
description: Dispatch a code review of the current diff using the tiered LLM review workflow (light/standard/deep). Reads REVIEW-WORKFLOW.md and executes it inline. Use before committing or when CLAUDE.md says to run /dso:review. Trigger phrases include 'run a code review', 'review my changes', 'do a code review', '/dso:review', 'code review'.
user-invocable: true
allowed-tools: Read, Write, Edit, Glob, Grep, Bash, Agent
---

# Review

Shallow entry point for the DSO tiered code review workflow.

<HARD-GATE>
Before doing anything else, check `dso.workflow`. If it is `ci-pr`, this skill is a no-op — emit the skipped markers and return immediately. Do NOT load REVIEW-WORKFLOW.md, do NOT dispatch a classifier, do NOT dispatch a code-reviewer sub-agent. CI runs the parity-uplifted llm-review job on push; any local dispatch here is wasted budget that produces results no consumer will read (bug 818d-61dc).

```bash
DSO_WORKFLOW=$(DSO_DEPRECATION_QUIET=1 ".claude/scripts/dso" read-config.sh dso.workflow 2>/dev/null || true)
if [ "$DSO_WORKFLOW" = "ci-pr" ]; then
    .claude/scripts/dso commit-step skip reviewer-record "dso.workflow=ci-pr"
    .claude/scripts/dso commit-step skip classifier-dispatch "dso.workflow=ci-pr"
    echo "dso.workflow=ci-pr — /dso:review is a no-op (CI runs llm-review)."
    # END the skill — return to caller. Do NOT proceed to "Instructions" below.
    exit 0
fi
```

The rationalization "but I should run it anyway to be safe" is exactly the failure mode this gate prevents. The pre-commit review-gate and the Layer 2 hook both already skip enforcement under ci-pr; dispatching here adds latency and cost without changing the merge outcome.
</HARD-GATE>

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
2. Execute its steps verbatim — starting from Step 0 (Clear Stale Review Artifacts).
3. Follow all HARD-GATE sections and workflow enforcement gates.

The workflow file is the complete specification. If `dso.workflow=ci-pr` is set, the workflow will instruct you to skip local review and emit .skipped markers instead.
