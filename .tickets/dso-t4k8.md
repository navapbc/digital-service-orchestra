---
id: dso-t4k8
status: open
deps: []
links: []
created: 2026-03-17T18:34:33Z
type: epic
priority: 1
assignee: Joe Oakhart
jira_key: DIG-38
---
# Don't cover up problems

Using lockpicks and debugging skills and review resolution prompts should provide guidance that agents should fix errors instead of covering them to. Our goal is to prevent the anti-pattern of agents skipping tests, adding inline exceptions to lint rules, increasing error tolerance levels, and other behavior that quickly resolves a failure without addressing the underlying issue. We want to fix the problem, not remove visibility into the problem. 
Code review agents should be instructed to apply additional scrutiny to inline lint exceptions, skipped tests, and other changes that reduce visibility into problems.


## Notes

<!-- note-id: 7xctxj7d -->
<!-- timestamp: 2026-03-22T18:58:03Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->


## Context
Engineers maintaining the codebase find that sub-agents sometimes resolve failing tests, lint errors, or runtime exceptions by suppressing them rather than fixing the root cause — skipping tests, adding broad exception handlers, loosening assertions, removing failing test cases, or downgrading error severity. These changes pass validation in the short term but cause regressions to surface later, requiring costly re-investigation. Existing prohibitions in SUB-AGENT-BOUNDARIES.md cover some patterns but don't address the full range or explain why they're prohibited.

## Success Criteria
- Sub-agent prompt templates (task-execution.md, fix-task-tdd.md, fix-task-mechanical.md) each include a Prohibited Fix Patterns section listing the following anti-patterns with code examples, rationale, and a Do this instead alternative: (1) skipping or removing tests, (2) loosening assertions, (3) broad exception handlers, (4) downgrading error severity, (5) commenting out failing code
- SUB-AGENT-BOUNDARIES.md existing suppression prohibitions are expanded to cover the same five anti-patterns, merged with the existing list (deduplicated, not duplicated)
- Each prohibited patterns Do this instead alternative describes a concrete action the agent can take (e.g., fix the failing assertion not do the right thing)
- Verified by grepping each target file for the five anti-pattern categories and confirming each has a corresponding alternative

## Scope
This epic covers authoring-time prohibitions — what sub-agents must not write. Review-time detection (what reviewers flag) is handled by separate epics (w21-ovpn, w21-ykic). The three named prompt templates are the only sub-agent task-execution templates in scope; dedicated plugin agent prompts (complexity-evaluator, conflict-analyzer) are excluded.

## Dependencies
None

## Approach
Extend existing sub-agent prompt templates and SUB-AGENT-BOUNDARIES.md with a comprehensive anti-cover-up section. No new scripts or runtime checks — defense in depth is provided at the review layer by separate epics.

