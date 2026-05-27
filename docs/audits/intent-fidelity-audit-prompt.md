# Intent Fidelity Audit Prompt

Reusable prompt for evaluating the DSO pipeline's ability to translate user-defined intent into verified execution. Dispatch as an opus sub-agent with access to the full codebase.

**First used**: 2026-05-26 (pre-implementation baseline)
**Design doc**: `docs/designs/intent-fidelity-pipeline.md`

---

## Prompt

You are a senior process auditor evaluating a software development automation system called "Digital Service Orchestra" (DSO). Your goal is to evaluate the entire pipeline — from brainstorming through implementation to verification — against a single question:

**Does the current workflow reliably ensure that what the user defines and approves during brainstorming is what actually gets implemented and verified at closure?**

This is an "intent fidelity" audit. The system's goal is intent-driven development: a user defines a feature (via /dso:brainstorm), it gets decomposed into stories and tasks (via /dso:preplanning and /dso:implementation-plan), implemented by AI sub-agents (via /dso:sprint), reviewed (/dso:review), and verified before closure (dso:completion-verifier). The chronic failure mode is: **epics and stories are closed as P1=PASS when the intended functionality has not been fully implemented and tested.**

## Evidence of the problem

Here are real incidents that demonstrate the failure pattern:

### Incident 1: Epic 4047 (Jira reconciler) — shape without substance
The epic closed P1=PASS across all 11 stories. But post-hoc audit revealed:
- 6 of 7 inbound mutation leaves were empty stubs (no-op functions that accept input and return empty results)
- The reconciler ran a "dry-run" that "converged" with 2,050 mutations — but every mutation flowed through a stub handler that did nothing
- Mode-to-cap machinery was defined but never wired into the execution path
- The ONE leaf that actually worked was the only one with an explicit per-leaf implementation task in the decomposition
- The completion verifier signed off on each story because the Done Definitions were satisfied in a "shape-only" way — the code had the right structure but no behavior

Root cause (from bug 1761-21ca): "Epic->story->task decomposition allows behavioral implementation gaps to satisfy DDs as shape-only, producing P1=PASS closures with no-op load-bearing functions"

### Incident 2: Story-based review epic — closed but never consumed
An epic that built a CI workflow (sprint-story-review.yml) was closed as complete. But when the next sprint tried to use it:
- Zero workflow runs occurred for the subsequent sprint
- No story branches were created or pushed
- The verifier had accepted "workflow file exists" and "tests pass on the implementing branch" as evidence — but never tested "does this workflow actually fire for a downstream consumer?"

Root cause (from bug cd24-6553): output-based verification vs. outcome-based verification.

### Incident 3: Sprint orchestrator defer-over-implement bias (bug 41b5)
When a verifier flagged 2 failing tests that could be fixed with ~10 lines of code, the orchestrator chose to "defer" via RED markers instead of implementing. This produced:
- 6+ sub-agent dispatches (~600 tool calls)
- 3 empty commits
- Multiple failed remediation cycles
- The verifier explicitly suggested "implement the feature" but the orchestrator ignored this and kept trying the marker-registration path

### Incident 4: Brainstorm scrutiny bypass (bug ecc2-e508)
HARD-GATE scrutiny and fidelity dispatches were bypassed via "session-momentum rationalization" — the brainstorm:complete tag was applied without required reviewers actually running.

### Additional related bugs (all open):
- 975e: Preplanning bypass mechanism stories lack paired governance story
- bca0: Implementation-plan spec phases lack task-level coverage assertion
- d8e1: End-session has no surveillance of bypass-hatch use count
- f552: Sprint orchestrator offered to skip mandatory steps
- e710: Brainstorm architectural epic without self-use criterion
- 6111-fc7f: "Add Execution Trace Requirement to Plan and Fidelity Reviewers"
- 6068-cb2d: "Completion verifier: goal-backward verification with must_haves separation"

### The d076 postmortem
A prior postmortem (2026-05-16) audited 39 epics and found a 72% gap rate — 28 HIGH + 6 MEDIUM architecture-vs-evidence gaps. This produced a remediation epic (f9de-b7d9) but the structural pipeline problems persist.

## The pipeline stages to evaluate

Evaluate each stage for how it contributes to or fails to prevent intent drift:

### Stage 1: Brainstorming (/dso:brainstorm)
- How are Success Criteria (SCs) defined?
- Are SCs outcome-based or output-based? (e.g., "workflow file exists" vs. "workflow fires for downstream consumers")
- Is there a self-use criterion for architectural features?
- Does the scrutiny pipeline actually run, or can it be bypassed?

### Stage 2: Preplanning (/dso:preplanning -> dso:story-decomposer)
- How do stories map to SCs?
- Can a story satisfy a Done Definition with structural artifacts alone (the file exists, the function signature exists) without behavioral verification?
- Are bypass mechanisms paired with governance?
- Does the red-team reviewer catch "shape-only" satisfaction risks?

### Stage 3: Implementation planning (/dso:implementation-plan -> dso:task-decomposer)
- How do tasks map to story DDs?
- Can a task be marked complete when it implements structure without behavior?
- Is there a coverage assertion that every behavioral DD has a task that tests the behavior end-to-end?
- Are "deferred to later task" claims tracked and enforced?

### Stage 4: Implementation (/dso:sprint)
- How does the sprint orchestrator verify task completion?
- Can a sub-agent mark a task done by creating stubs?
- Does the orchestrator evaluate whether "deferred" features should actually just be implemented?
- How are RED markers and test deferrals handled?

### Stage 5: Verification (dso:completion-verifier)
- What does the verifier actually check — outputs or outcomes?
- Can the verifier pass a story where load-bearing functions are empty stubs?
- Does the verifier test behavioral integration or just structural presence?
- How does it handle deferred-evidence obligations?
- Is the P1 gate actually enforced, or can it be bypassed?

### Stage 6: Closure (/dso:end-session, ticket transitions)
- Are bypass hatches counted and audited?
- Can the orchestrator skip verification steps?

## What to produce

Write a structured diagnostic report with:

1. **Problem definition** (2-3 paragraphs): Define the core failure mode precisely. Name it. Characterize it.

2. **Intent fidelity scorecard**: For each pipeline stage (1-6), rate:
   - Current intent preservation: HIGH / MEDIUM / LOW / NONE
   - Primary failure mode at this stage
   - Whether the failure is detectable by downstream stages
   - Whether there is a mechanical enforcement (hook, gate, script) or only behavioral guidance (skill text, agent instructions)

3. **Root cause analysis**: Identify the 3-5 structural root causes that cut across stages. These should be architectural, not per-incident.

4. **Gap taxonomy**: Classify the types of intent drift into a taxonomy (e.g., "shape-only satisfaction", "output-vs-outcome confusion", "defer-as-skip", "scrutiny bypass", etc.)

5. **Intervention points**: For each root cause, identify where in the pipeline the earliest reliable intervention could be placed — favoring mechanical enforcement over behavioral guidance.

6. **Recommended changes** (prioritized): What specific changes to the workflow, verifier, decomposer, and sprint skill would close the highest-impact gaps? Prioritize by: (a) blast radius of the gap, (b) mechanical enforceability, (c) implementation cost.

## Key files to read

Read these files to understand the current workflow:

- `plugins/dso/skills/brainstorm/SKILL.md` — brainstorm workflow
- `plugins/dso/skills/preplanning/SKILL.md` — story decomposition
- `plugins/dso/skills/implementation-plan/SKILL.md` — task decomposition
- `plugins/dso/skills/sprint/SKILL.md` — sprint execution (especially Phase F Steps 18-19 for verification)
- `plugins/dso/agents/completion-verifier.md` — the verifier agent prompt
- `plugins/dso/agents/story-decomposer.md` — story decomposer agent
- `plugins/dso/agents/task-decomposer.md` — task decomposer agent
- `plugins/dso/skills/shared/workflows/remediation-loop-protocol.md` — how remediation works
- `plugins/dso/docs/VERIFIER-PROTOCOL.md` — verifier protocol
- `plugins/dso/skills/shared/workflows/epic-scrutiny-pipeline.md` — scrutiny pipeline

Read these files thoroughly before writing your report. The report should be grounded in what the files actually say, not assumptions.

Be ruthlessly honest. This is a self-audit — the goal is to find every structural weakness, not to reassure. If you find that the system has good intentions documented in skill files but no mechanical enforcement, say so clearly.

Format: Use markdown with clear headers. Keep each section focused and evidence-based. Total length: aim for 3000-5000 words — thorough but not padded.
