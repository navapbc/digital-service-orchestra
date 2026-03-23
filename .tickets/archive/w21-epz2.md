---
id: w21-epz2
status: closed
deps: [w21-zp4d, w21-jtkr, w21-txt8, w21-nv42, w21-0kt1]
links: []
created: 2026-03-21T00:03:01Z
type: story
priority: 3
assignee: Joe Oakhart
parent: w21-ykic
---
# Update project docs to reflect tiered review architecture

## Description

**What**: Update CLAUDE.md architecture section to describe the tiered review system, classifier, and new dimension names. Update any existing docs referencing the old single-reviewer model or old dimension names.

**Why**: Future agents need accurate awareness of the tiered review architecture to work within it correctly.

**Scope**:
- IN: CLAUDE.md architecture section, quick reference table, any existing docs referencing old dimension names or single-reviewer model
- OUT: Creating new documentation files (only update existing)

## Done Definitions

- When this story is complete, CLAUDE.md accurately describes the tiered review system, complexity classifier, tier boundaries, and new dimension names
  ← Satisfies: "Schema revision" and "Tier routing"
- When this story is complete, no existing documentation references the old single-reviewer model or old dimension names as current
  ← Satisfies: "All consumers updated"

## Escalation Policy

**Escalation policy**: Proceed unless a significant assumption is required to continue — one that could send the implementation in the wrong direction. Escalate only when genuinely blocked without a reasonable inference. Document all assumptions made without escalating.

## Notes

**2026-03-21T00:04:39Z**

Follow .claude/docs/DOCUMENTATION-GUIDE.md for documentation formatting, structure, and conventions.

**2026-03-22T23:05:11Z**

CHECKPOINT 1/6: Task context loaded ✓

**2026-03-22T23:06:19Z**

CHECKPOINT 2/6: Code patterns understood ✓ — Named-agent dispatch section in CLAUDE.md only mentions complexity-evaluator and conflict-analyzer, missing all 6 tiered code-reviewer agents. No other docs reference old dimension names (those are in code/prompt files which we must NOT change). Main change needed: update Named-agent dispatch sentence in CLAUDE.md to include the tiered review agents and classifier.

**2026-03-22T23:07:54Z**

CHECKPOINT 4/6: Implementation complete ✓ — Updated CLAUDE.md: (1) Named-agent dispatch paragraph now includes all 6 tiered code-reviewer agents + Tiered review system description with classifier factors, tier thresholds, size limits, and contract doc references; (2) Rule 14 updated to accurately describe multi-agent dispatch for deep tier. No other documentation files referenced old single-reviewer model or old dimension names as current (only prompt/build-source files retain old names per task instructions).

**2026-03-22T23:08:43Z**

CHECKPOINT 6/6: Done ✓ — Verified: (1) Dimension names in CLAUDE.md match actual validator (write-reviewer-findings.sh required_dims: hygiene, design, maintainability, correctness, verification); (2) No existing docs (outside ticket files and prompt templates) reference old single-reviewer model or old dimension names; (3) CLAUDE.md now accurately describes tiered review system, classifier script, 7 scoring factors, 3 tier thresholds, size-gating rules, 6 named review agents, and 5 dimension key names.

**2026-03-22T23:09:06Z**

CHECKPOINT 6/6: Done ✓ — CLAUDE.md updated with tiered review architecture
