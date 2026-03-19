---
id: dso-zc6s
status: closed
deps: [dso-60hd, dso-w1s1]
links: []
created: 2026-03-18T01:21:46Z
type: feature
priority: 2
assignee: Joe Oakhart
parent: dso-8qvu
---
# Update project docs to reflect new check-skill-refs.sh and qualify-skill-refs.sh scripts


## Notes

**2026-03-18T01:22:16Z**


**What**: Update CLAUDE.md to reflect the two new scripts introduced by this epic.

**Why**: Future agents discover available scripts via CLAUDE.md's architecture section and Quick Reference table. Without updating these, check-skill-refs.sh and qualify-skill-refs.sh will be invisible to agents reading the project configuration.

**Scope**:
- IN: CLAUDE.md architecture section (new scripts), CLAUDE.md Quick Reference table (check-skill-refs.sh entry)
- OUT: Creating new documentation files; updating skill or workflow files (those are updated by dso-w1s1)
- Follow .claude/docs/DOCUMENTATION-GUIDE.md for formatting conventions.

**Depends on**: dso-60hd, dso-w1s1

**Done Definitions**:
- When this story is complete, the CLAUDE.md architecture section mentions check-skill-refs.sh and qualify-skill-refs.sh with their purpose (linter and one-shot rewriter)
  ← Satisfies: documentation freshness after epic completion
- When this story is complete, the CLAUDE.md Quick Reference table includes an entry for check-skill-refs.sh so agents can discover it
  ← Satisfies: agent discoverability of the new lint rule


<!-- note-id: ulhqflny -->
<!-- timestamp: 2026-03-18T02:41:39Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CLOSE REASON: Superseded by dso-0vyd (richer story with done definitions, AC, considerations)
