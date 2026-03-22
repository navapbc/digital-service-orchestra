---
id: w22-jucp
status: open
deps: []
links: []
created: 2026-03-22T15:24:31Z
type: epic
priority: 2
assignee: Joe Oakhart
---
# Rebase-aware test gate — detect rebase state and adjust hash verification

Make the pre-commit test gate rebase-aware so merge-to-main.sh auto-resolve path doesn't get blocked by hash mismatch. Detect .git/rebase-merge/ or .git/rebase-apply/ and, if the only non-allowlisted diff is identical code changes on a different base, accept existing test status. See analysis in w21-nrpb.

