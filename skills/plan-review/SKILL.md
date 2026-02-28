---
name: plan-review
description: Sub-agent review of plans and designs before user approval. Invoke before presenting any plan or design to the user, or before calling ExitPlanMode.
---

# Plan Review

Lightweight sub-agent review that catches issues in plans and designs before the user sees them.

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

**Sub-agent prompt:**

```
You are reviewing a {artifact_type} before it is presented to the user for approval.
Your job is to find real problems — not to nitpick or add unnecessary suggestions.

## Artifact

{artifact content}

## Review Dimensions

Score each dimension 1-5 (5 = no issues found):

### 1. Feasibility
Can this actually be built as described?
- Are there missing steps or impossible constraints?
- Do the proposed tools/libraries/APIs exist and work as assumed?
- Are there implicit dependencies that aren't called out?

### 2. Completeness
Does the plan cover what it needs to?
- Are error cases and edge cases addressed where they matter?
- Is the testing strategy adequate?
- Are integration points with existing code identified?

### 3. YAGNI / Overengineering
Is the plan doing too much?
- Are there unnecessary abstractions or premature generalizations?
- Could anything be simplified without losing value?
- Are there features or capabilities that weren't asked for?

### 4. Codebase Alignment
Does the plan match how this project actually works?
- Does it follow existing naming conventions and file organization?
- Does it use the project's established patterns (not invent new ones)?
- Are the referenced files, modules, and APIs accurate?

## Output Format

Return your review as structured text:

VERDICT: PASS or REVISE

SCORES:
- feasibility: N/5
- completeness: N/5
- yagni: N/5
- codebase_alignment: N/5

FINDINGS:
[For any dimension scoring below 4, list specific issues]

FINDING: [dimension] [severity: critical|major|minor]
[Description of the issue]
SUGGESTION: [How to fix it]

[Repeat for each finding]
```

Launch with:
```
subagent_type: "feature-dev:code-architect"
model: opus (design) or sonnet (implementation_plan)
# code-architect specializes in analyzing existing codebase patterns and
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

Parse the sub-agent's output:

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
WORKTREE_NAME=$(basename "$REPO_ROOT")
ARTIFACTS_DIR="/tmp/workflow-artifacts-${WORKTREE_NAME}"
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

`/review` and `superpowers:code-reviewer` review **completed code** (diffs, test coverage, bugs). They are wrong for plans. Use this skill (`/plan-review`) for plans and designs. See CLAUDE.md rule 17 and the review routing table in "Always Do These".
