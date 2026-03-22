---
id: w21-jtkr
status: closed
deps: [w21-zp4d, dso-9ltc]
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

## Notes

<!-- note-id: f4sbk3kx -->
<!-- timestamp: 2026-03-21T18:14:13Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->


## Update: Named agent dispatch due to dso-9ltc (review agent build process)

With dedicated review agents defined in dso-9ltc, this story's tier routing dispatches to named agents instead of generic agents with prompts:
- Light (score 0-2): dispatch to dso:code-reviewer-light (haiku)
- Standard (score 3-6): dispatch to dso:code-reviewer-standard (sonnet)
- Deep (score 7+): dispatch to dso:code-reviewer-deep-* agents (handled by w21-txt8)

REVIEW-WORKFLOW.md Step 4 changes from loading code-review-dispatch.md into a general-purpose agent to dispatching the classifier-selected named agent with per-review context only (diff path, working directory, diff stat, issue context). The stable review procedure (schema, output contract, scoring rules) is already in each agent's system prompt.

Done definition 3 (REVIEW-WORKFLOW.md Step 3 replacement) should reference named agent dispatch rather than model selection. The old code-review-dispatch.md is preserved as a fallback but is no longer the primary dispatch path.

Integration test: invoke at least one generated agent with a minimal diff and verify schema-valid output on first attempt. This validates the end-to-end path from classifier → named agent → write-reviewer-findings.sh.


**2026-03-22T14:17:49Z**

COMPLEXITY_CLASSIFICATION: COMPLEX
