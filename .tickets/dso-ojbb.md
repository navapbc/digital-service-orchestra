---
id: dso-ojbb
status: closed
deps: []
links: []
created: 2026-03-18T15:58:48Z
type: epic
priority: 2
assignee: Joe Oakhart
---
# Add --dryrun flag to dso-setup.sh and /dso:project-setup


## Notes

**2026-03-18T15:59:05Z**


## Context
Engineers evaluating DSO for a new project need to understand what setup will do before committing to it. Today, the only way to know what dso-setup.sh will change is to read the script or run it. A --dryrun flag lets engineers preview the full setup impact — files that would be copied, config keys that would be written, hooks that would be registered — and then confirm or abort, without having to undo anything.

## Success Criteria
- Running `dso-setup.sh --dryrun` exits 0 with no filesystem changes and prints a human-readable report listing each planned action with the content that would be written (shim contents, .pre-commit-config.yaml body, workflow-config.conf entry, etc.)
- Running `/dso:project-setup --dryrun` runs the full interactive wizard (same questions as normal setup), then displays the combined preview: the script's dryrun report plus the exact workflow-config.conf content that would be written based on the user's wizard answers, then asks "Proceed with setup?"
- If the user confirms, the skill proceeds with full setup using the answers already collected — no re-prompting
- `--dryrun` is position-independent: valid anywhere in the argument list alongside TARGET_REPO and PLUGIN_ROOT positional args
- All existing dso-setup.sh tests continue to pass; new tests assert dryrun output content and verify no filesystem changes occur

## Dependencies
None

## Approach
Option A: dso-setup.sh --dryrun prints a human-readable report to stdout (one section per planned action with actual content); the skill captures this, runs the full interactive wizard to collect answers, then displays the combined preview before asking to proceed. Answers collected during dryrun are reused if the user confirms — no re-prompting.

