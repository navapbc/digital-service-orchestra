---
id: w21-epz2
status: in_progress
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
