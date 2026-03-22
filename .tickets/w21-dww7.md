---
id: w21-dww7
status: open
deps: [w21-8cw2, dso-hdf8]
links: []
created: 2026-03-20T15:46:08Z
type: story
priority: 1
assignee: Joe Oakhart
parent: w21-bwfw
---
# As a developer, comments sync bidirectionally between local tickets and Jira without duplication


## Notes

**2026-03-20T15:46:56Z**

## Description
**What**: Bidirectional comment sync between local tickets and Jira. Outbound pushes local comments with embedded UUID markers. Inbound pulls Jira comments with dedup via Jira comment ID (primary) and UUID marker (secondary).
**Why**: Comments are the primary communication channel between agents and human reviewers. Without comment sync, context is lost between systems.
**Scope**:
- IN: Outbound comment push with UUID marker embed, inbound comment pull with Jira comment ID dedup, handling of edited comments (marker stripped by rich-text editor), comment origin tracking
- OUT: Hardening (w21-2r0x), observability (w21-qjcy)

## Done Definitions
- Outbound pushes local comments to Jira with embedded UUID marker (hidden HTML comment) ← Satisfies SC4
- Inbound pulls Jira comments using Jira comment ID as primary dedup key (survives rich-text editor stripping) ← Satisfies SC4
- Comments round-trip without duplication — local comment pushed to Jira and pulled back is not re-imported ← Satisfies SC4
- Edited Jira comments (marker stripped) are matched by Jira comment ID, not UUID ← adversarial review (Finding 5 from SRE review)
- Unit tests passing

## Considerations
- [Reliability] Comment origin markers can be stripped by Jira rich-text editor — Jira comment ID is the reliable dedup key
- [Testing] Need test fixtures for comment round-trip including edit scenarios

**Escalation policy**: Escalate to the user whenever you do not have high confidence in your understanding of the work, approach, or intent. High confidence means clear evidence from the codebase or ticket context — not inference or reasonable assumption. When in doubt, stop and ask rather than guess.

**2026-03-22T00:54:33Z**

COMPLEXITY_CLASSIFICATION: COMPLEX
