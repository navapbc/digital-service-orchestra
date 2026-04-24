---
name: plan-review
description: Orchestrator-level skill that reviews plans and designs before user approval by dispatching a dso:plan-review sub-agent. Invoke before presenting any plan or design to the user, or before calling ExitPlanMode. Do NOT dispatch this skill itself as a sub-agent — it requires the Agent tool and will refuse sub-agent invocation.
allowed-tools: Read, Write, Edit, Glob, Grep, Bash
---

<SUB-AGENT-GUARD>
Requires Agent tool. If running as a sub-agent (Agent tool unavailable), STOP and return: "ERROR: /dso:plan-review requires Agent tool; invoke from orchestrator."
</SUB-AGENT-GUARD>

# Plan Review

Orchestrator-level skill that dispatches a `dso:plan-review` sub-agent to review plans and designs before the user sees them. This skill runs at the orchestrator level — it is NOT itself dispatched as a sub-agent (the SUB-AGENT-GUARD above enforces this).

## When to Invoke

**MANDATORY** before any of these:
- Presenting a design doc to the user for approval (brainstorming skill)
- Presenting an implementation plan to the user (writing-plans skill)
- Calling `ExitPlanMode` (plan mode)

The hook on `ExitPlanMode` enforces this mechanically. For brainstorming and writing-plans, this is skill-enforced.

## Parameters

| Parameter | Required | Default | Description |
|-----------|----------|---------|-------------|
| `artifact_type` | Yes | — | `"design"` or `"implementation_plan"` |
| `artifact_path` | Yes | — | Path to the plan/design file, or inline content |

## Process

### Step 1: Dispatch Review Sub-Agent

Launch a **single sub-agent** with the plan content and review rubric.

**Model selection:**
- `artifact_type: "design"` → `opus` (architectural reasoning)
- `artifact_type: "implementation_plan"` → `sonnet` (structural analysis)

**Sub-agent prompt:** Read and fill placeholders in `${CLAUDE_PLUGIN_ROOT}/docs/workflows/prompts/plan-review-dispatch.md`. Replace `{artifact_type}` and `{artifact content}` with actual values.

**Inline dispatch is required — `dso:plan-review` is an agent file identifier, NOT a valid `subagent_type` value.** The Agent tool only accepts built-in types (`general-purpose`, `Explore`, `Plan`, etc.). Read `agents/plan-review.md` inline and dispatch as `subagent_type: "general-purpose"` with the model below.

Launch with:
```
Agent tool:
  subagent_type: "general-purpose"
  model: opus (design) or sonnet (implementation_plan)
# dso:plan-review specializes in analyzing existing codebase patterns and
# conventions — directly serves the Feasibility and Codebase Alignment
# dimensions. The prompt's YAGNI and Completeness rubrics extend coverage
# beyond the agent's default focus on architecture.
#
# Tier 3 for design: must evaluate architectural coherence, cross-cutting
# concerns, and whether the design will compose with existing patterns —
# requires reasoning about trade-offs, not just structural checks.
# Tier 2 for implementation_plan: must verify task atomicity, dependency
# graph validity, and TDD discipline across multiple tasks — structured
# analysis that haiku reliably misses implicit coupling in.
```

### Step 2: Process Results

First, validate the sub-agent's output schema (schema-hash: 9dba6875b85b7bc3):

```bash
REPO_ROOT=$(git rev-parse --show-toplevel)
source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/deps.sh"
PLAN_OUT="$(get_artifacts_dir)/plan-review-output.txt"
cat > "$PLAN_OUT" <<'EOF'
<sub-agent output>
EOF
".claude/scripts/dso validate-review-output.sh" plan-review "$PLAN_OUT"
```

If `SCHEMA_VALID: no` — send a correction prompt to the sub-agent requesting the exact format; do not proceed until validation passes.

Then parse the validated output:

1. **If VERDICT is PASS** (all scores >= 4):
   - Write the marker file (see below)
   - Proceed to present the plan to the user
   - Include a brief note: "This plan was reviewed by a sub-agent. No issues found."

2. **If VERDICT is REVISE** (any score < 4):
   - Address each finding by severity: critical first, then major, then minor
   - For critical/major findings: revise the plan directly
   - For minor findings: revise if quick, otherwise note them for the user
   - **Do NOT re-run the review** — one pass is enough. Note what was changed.
   - Write the marker file
   - Present the revised plan to the user with a summary of what the review caught and what was changed

### Step 3: Write Marker File

After the review completes (pass or revise-then-fix), write the marker:

```bash
REPO_ROOT=$(git rev-parse --show-toplevel)
source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/deps.sh"
ARTIFACTS_DIR=$(get_artifacts_dir)
mkdir -p "$ARTIFACTS_DIR"

cat > "$ARTIFACTS_DIR/plan-review-status" << EOF
passed
timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
artifact_type={design|implementation_plan}
verdict={PASS|REVISE}
scores=feasibility:{N},completeness:{N},yagni:{N},codebase_alignment:{N}
EOF
```

The `ExitPlanMode` hook checks for this file.

## What This Skill Does NOT Do

- No multi-stage review protocol (single pass only)
- No JSON schema output (findings are for the agent, not persisted)
- No automated revision cycles (agent fixes once, done)
- No conflict detection between findings

## Common Mistake: Do NOT Use Code Review for Plans

`/dso:review` reviews **completed code** (diffs, test coverage, bugs). It is wrong for plans. Use this skill (`/dso:plan-review`) for plans and designs. See CLAUDE.md rule 17 and the review routing table in "Always Do These".
