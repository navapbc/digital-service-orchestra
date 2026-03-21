---
id: w21-jtkr
status: open
deps: [w21-zp4d]
links: []
created: 2026-03-21T00:02:51Z
type: story
priority: 1
assignee: Joe Oakhart
parent: w21-ykic
---
# As a DSO practitioner, code changes are scored by a deterministic classifier and routed to the correct review tier

## Description

**What**: Build plugins/dso/scripts/review-complexity-classifier.sh with 7 scoring factors and floor rules. Integrate into REVIEW-WORKFLOW.md to replace the existing Step 3 grep-based model selection with classifier-driven tier routing: Light→haiku, Standard→sonnet, Deep→sonnet (Deep multi-reviewer comes in w21-txt8). Add review.behavioral_patterns config key to dso-config.conf. Add classifier to CLAUDE.md rule #20 safeguard files.

**Why**: This is the walking skeleton — after this story, every change is scored and routed to the correct tier, replacing the current uniform-scrutiny model.

**Scope**:
- IN: Classifier script (all 7 factors, floor rules, behavioral file detection), REVIEW-WORKFLOW.md tier dispatch integration, dso-config.conf behavioral_patterns key, CLAUDE.md safeguard list update
- OUT: Deep tier multi-reviewer architecture (w21-txt8), diff size thresholds (w21-nv42), telemetry logging (w21-0kt1)

## Done Definitions

- When this story is complete, running the classifier on a staged diff outputs JSON with per-factor scores, computed_total, and selected_tier
  ← Satisfies: "A deterministic shell script accepts a diff as input and outputs a JSON object"
- When this story is complete, floor rules override computed scores — verified by test cases for each floor rule (anti-shortcut, critical-path, safeguard, test deletion, exception broadening)
  ← Satisfies: "Floor rules override computed score"
- When this story is complete, REVIEW-WORKFLOW.md Step 3 is replaced by classifier invocation and the old grep-based model selection is removed
  ← Satisfies: "Tier routing: Score 0-2 Light, 3-6 Standard, 7+ Deep"
- When this story is complete, behavioral files matching review.behavioral_patterns in dso-config.conf receive full scoring weight identical to source code
  ← Satisfies: "Behavioral file path patterns stored in dso-config.conf"
- When this story is complete, the classifier operates on the same file set as compute-diff-hash.sh (including untracked files, respecting review-gate-allowlist.conf exclusions)
  ← Satisfies: "Files matching review-gate-allowlist.conf are exempt"
- When this story is complete, classifier failure (exit non-zero, timeout, exit 144) defaults to Standard tier
  ← Satisfies: "Classifier failure defaults to Standard tier"
- Unit tests written and passing for all new or modified logic

## Considerations

- [Performance] Classifier runs on every commit — must complete in <2s
- [Reliability] Exit 144 (SIGURG) handling critical — common in long-running tool calls
- [Maintainability] Floor rule list will grow — script needs clean extensibility for adding patterns without modifying scoring logic
- [Testing] Classifier must produce identical file set to compute-diff-hash.sh to prevent scoring/review misalignment

## Escalation Policy

**Escalation policy**: Proceed unless a significant assumption is required to continue — one that could send the implementation in the wrong direction. Escalate only when genuinely blocked without a reasonable inference. Document all assumptions made without escalating.
