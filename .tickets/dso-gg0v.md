---
id: dso-gg0v
status: open
deps: []
links: []
created: 2026-03-22T00:33:09Z
type: bug
priority: 2
assignee: Joe Oakhart
tags: [agent-compliance, debug-everything]
---
# debug-everything validation prompts use soft "Do NOT fix" language instead of hard-stop READ-ONLY ENFORCEMENT

## Bug

The following debug-everything validation sub-agent prompts use soft "Do NOT fix" imperative language instead of the hard-stop READ-ONLY ENFORCEMENT section pattern fixed in w20-w7pm:

- plugins/dso/skills/debug-everything/prompts/full-validation.md
- plugins/dso/skills/debug-everything/prompts/post-batch-validation.md
- plugins/dso/skills/debug-everything/prompts/tier-transition-validation.md
- plugins/dso/skills/debug-everything/prompts/critic-review.md
- plugins/dso/skills/debug-everything/prompts/diagnostic-and-cluster.md

## Expected Behavior

Each validation/diagnostic prompt should have a dedicated ## READ-ONLY ENFORCEMENT section that explicitly names the Edit tool, Write tool, and file-modifying Bash commands as PROHIBITED — matching the pattern implemented in w20-w7pm for validate-work prompts.

## Discovered by

Bug w20-w7pm anti-pattern search (CLAUDE.md rule 9).

## Notes

<!-- note-id: elp3zdbl -->
<!-- timestamp: 2026-03-22T23:01:54Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

Classification: mechanical (pattern replication from w20-w7pm)
