---
id: dso-tmmj
status: in_progress
deps: []
links: []
created: 2026-03-17T18:33:39Z
type: epic
priority: 0
assignee: Joe Oakhart
jira_key: DIG-8
---
# Methodical debugging improvements

We need to rework our debugging process. We need to create a hard separation between investigation + planning and implementation + fixing. When we encounter a bug, we should follow the process below. This should apply to bugs found during validation, CI failures, debug-everything, and and other instances when we are fixing a bug. We should create this as a workflow like our commit workflow and add guidance to using-lockpicks that invokes it when the user asks the agent to fix a bug or failure. A cluster of bugs identified by debug-everything may share a single invokation of this new debug workflow.  
Step 0: check to see if there are KNOWN ISSUES related to this bug. If so, add the details to the bug.
Step 1: investigation complexity Assess the severity of the bug based on expert definitions of severity (use websearch and webfetch to research these definitions when implementing this epic). High/critical severity scores 2 points. Medium/moderate severity scores 1 point. Low severity scores 0 points. Assess the complexity of the bug using the complexity evaluation used by both sprint and debug everything. Complex scores 2 points. Moderate/medium scores 1 point. Simple/trivial scores 0 points.  Assess where the bug was found. If it was found in a production or staging environment, score 2. If it caused a CI failure, score 1. Otherwise score 0. Assess whether previous commits have attempted to fix this bug. If so, score 2. Add up the scores for the bug using the above rules. A score of less than 3 routes to BASIC investigation. A score of 3 to 5 routes to INTERMEDIATE investigation. A score of higher then 5 routes to ADVANCED investigation. 
Step 2: investigation sub-agent Basic launches a sonnet sub-agent to determine the root cause of the bug and propose a fix.  Intermediate launches an opus sub-agent to determine the root cause of the bug and propose at least 2 ways to fix the issue. Results should include a recommendation, confidence level in each solution, risk level of each fix, whether the fix degrades intended functionality, and tradeoffs considered.  ADVANCED launches 2 opus sub-agents to determine the root cause of the bug and propose at least 2 ways to fix the issue each. Results should follow the same pattern as intermediate. The orchestrator should compare these results and merge them into a single report. Agents independently converging on the same root cause or same fix should increase our confidence level in that root cause or fix. Escalation: if at least one ADVANCED investigation has failed to resolve this issue, launches 4 opus sub-agents. One agent should be directed to use websearch and webfetch to research instances where other developers have encountered similar issues. One agent should be directed to review the ticket history and commit history of bugs and fixes related to this issue. One agent should be directed to carefully step through the relevant source code to create a model of each scenario that could be happening. This last agent is authorized to add logging and enable debugging to ensure it has a complete and accurate understanding of the problem. Each of these agents should be directed to provide one or more root cause with an associated confidence level and at least 3 proposed fixes that could resolve the issue that we have not already tried. All use a read-only sub-agent (the equivalent of planning mode) except the agent authorized to add logging. All sub-agents should be given the ticket ID of the bug along with instructions on how to read the ticket.
Step 3: hypothesis and testing For each root cause suggested by step 2, propose a test that would prove or disprove the suspected root cause. Run this test. 
Step 4: fix approval If there is only one proposed fix, the fix is automatically approved.  If there are multiple fixes, but one is high confidence, low risk, and does not degrade functionality, the fix is automatically approved.  Otherwise user approval is required. Display the proposals, including all details for each proposal. Display confidence level in each root cause, confidence level in each fix, and risk of each fix. Display the results from step 3 along with each corresponding root cause that was tested. Note when multiple agents converge on the same root cause or propose the same fix. 
Step 5: RED testing  If the bug causes an existing test to fail, skip this step. Otherwise, create a unit test that fails because of the bug we are fixing. If a previous loop created a RED test for this bug, the existing test may be edited. The test failure should confirm the root cause the investigation identified when possible. If we can't create a failing test, return to step 2 and perform another round of investigation for the bug escalating to the next highest level of investigation. Include the successful test results with the investigation prompt. 
Step 6: fix implementation Launch a sub-agent to implement the approved fix.  
Step 7: verify fix Verify the the RED tests are now GREEN (passing). If they are still failing, return to step 2 and perform another round of investigation for the bug escalating to the next highest level of investigation. Include the attempted fix and testing results with the investigation prompt. 
Step 8: commit Complete the commit workflow


## Notes

**2026-03-19T02:22:31Z**

## Brainstorm Spec (2026-03-18)

### Context
DSO's current tdd-workflow gives agents a simple RED→GREEN→VALIDATE cycle with no investigation phase. When bugs are complex, have prior fix attempts, or surface in CI/staging, agents guess at root causes and fail to fix them — wasting cycles and triggering cascading failures. A new dso:fix-bug skill enforces a hard separation between investigation and implementation, scaling depth to bug severity before any fix is attempted. It replaces tdd-workflow as the canonical individual bug-fix path and becomes the unit of work that debug-everything delegates to.

### Success Criteria

1. A dso:fix-bug skill handles individual bug (and bug cluster) resolution; tdd-workflow is deprecated with a forward pointer to dso:fix-bug.

2. Errors are first classified by type: mechanical (import error, type annotation, lint violation, config syntax) skip scoring and route directly to a lightweight read→fix→validate path; all other bugs are scored for investigation depth.

3. Investigation depth (BASIC/INTERMEDIATE/ADVANCED) is determined by a scoring rubric: severity (0/1/2), complexity (0/1/2), environment (0/1/2), cascading failure status (+2), prior fix attempts (+2) — thresholds <3=BASIC, 3-5=INTERMEDIATE, ≥6=ADVANCED.

4. Each investigation tier uses differentiated sub-agents with specific root cause techniques:
   - BASIC: single sonnet — structured localization (file→class→line), five whys, self-reflection before reporting root cause.
   - INTERMEDIATE: single opus (error-debugging:error-detective; falls back to general-purpose with investigation prompt) — dependency-ordered code reading, intermediate variable tracking, five whys, hypothesis generation + elimination, self-reflection.
   - ADVANCED: two independent opus agents with differentiated lenses: Agent A (code tracer — execution path tracing, intermediate variable tracking, five whys, hypothesis set from code evidence) and Agent B (historical — timeline reconstruction, fault tree analysis, git bisect, hypothesis set from change history); orchestrator applies convergence scoring and fishbone synthesis across cause categories (Code Logic, State, Configuration, Dependencies, Environment, Data).
   - ESCALATED: four opus agents — (1) web researcher (error pattern analysis, similar issue correlation, dependency changelogs), (2) history analyst (timeline reconstruction, fault tree analysis, commit bisection), (3) code tracer (execution path tracing, dependency-ordered reading, intermediate variable tracking, five whys), (4) empirical/logging agent (authorized to add logging and enable debugging to empirically validate or veto hypotheses from agents 1-3); if Agent 4 vetoes consensus from agents 1-3, a resolution agent weighs all findings, conducts additional tests, and surfaces the highest-confidence conclusion.

5. Escalation to the next investigation tier triggers when: (a) fix verification fails after a completed fix attempt, OR (b) investigation returns no root cause or a low-confidence root cause (medium or below). When ESCALATED investigation also fails to produce a high-confidence root cause, the skill surfaces all findings and escalates to the user — no blind fix attempt.

6. Investigation sub-agents are given pre-loaded context before dispatch: existing failing tests, stack traces, relevant commit history, and prior fix attempts from the ticket. Sub-agents run existing tests immediately to establish a concrete failure baseline before analyzing code.

7. When invoked with a cluster of bugs, dso:fix-bug investigates them as a single problem and splits into per-root-cause tracks only when the investigation identifies multiple independent root causes.

8. debug-everything delegates individual bug and cluster resolution to dso:fix-bug; its fix-task-tdd.md and fix-task-mechanical.md prompts are updated or replaced accordingly.

9. using-lockpicks routes single-bug requests to dso:fix-bug and multi-bug/all-bugs requests to debug-everything; sprint references dso:fix-bug for validation failures.

10. fix-cascade-recovery retains its emergency-brake steps (stop, assess git damage, revert decision, circuit breaker reset) and hands off to dso:fix-bug for investigation; its root cause analysis steps are removed.

11. The error-debugging plugin is added to INSTALL.md as a recommended plugin; when unavailable, investigation sub-agents fall back to general-purpose with an investigation-specific prompt covering the same root cause techniques.

12. The skill is successfully used to resolve at least one INTERMEDIATE or ADVANCED bug in the DSO codebase itself (dogfooding), confirming investigation sub-agents identify root cause before any fix is attempted and RED tests fail before the fix is applied.

### Dependencies
None

### Approach
New dso:fix-bug skill (standalone file) replacing tdd-workflow. Preserves tdd-workflow's config resolution pattern and RED→GREEN→VALIDATE cycle as the fix phase (Steps 5-7). Integration updates required in: debug-everything (fix-task prompts), using-lockpicks (routing), sprint (validation failure references), and fix-cascade-recovery (hand-off after emergency brake). Sub-agent routing uses discover-agents.sh with error-debugging:error-detective preferred for INTERMEDIATE and above; falls back to general-purpose with bundled investigation prompt. Research archive: plugins/dso/docs/archive/debugging-research-2026-03-18.md
