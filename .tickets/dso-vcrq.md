---
id: dso-vcrq
status: open
deps: []
links: []
created: 2026-03-20T03:14:20Z
type: bug
priority: 3
assignee: Joe Oakhart
---
# resolve-conflicts skill misdetects merge state when conflicts are pre-resolved

When invoking /dso:resolve-conflicts during an in-progress merge where conflicts have already been staged (e.g. .tickets/.index.json auto-resolved by merge-to-main.sh), the skill Step 1 detection logic reports no merge in progress and exits. It only checks git diff --name-only --diff-filter=U for unresolved files, but does not check for MERGE_HEAD to detect that a merge is still in progress needing completion. Fix: Step 1 should first check test -f .git/MERGE_HEAD; if true and no U-flagged files exist, report that merge is in progress with all conflicts resolved and proceed to Step 4 (complete the merge) rather than exiting.

