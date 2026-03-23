---
id: dso-1cje
status: in_progress
deps: [dso-5fbs]
links: []
created: 2026-03-23T15:19:45Z
type: task
priority: 1
assignee: Joe Oakhart
parent: w21-wbqz
---
# Update infrastructure path references (.tickets/ → .tickets-tracker/)

Update all storage path references from the old .tickets/ layout to the v3 .tickets-tracker/ layout in infrastructure files.

## Depends on
dso-5fbs (RED test must exist before this task)

## Files to Edit

### plugins/dso/hooks/lib/review-gate-allowlist.conf
- Change: .tickets/** → .tickets-tracker/**
  (This is the single source of truth for non-reviewable file patterns consumed by compute-diff-hash.sh and skip-review-check.sh)

### plugins/dso/hooks/compute-diff-hash.sh
- Line 7 comment: '.tickets/ files' → '.tickets-tracker/ files'
- Line 24 comment: "pathspecs like ':!app/.tickets/'" → "pathspecs like ':!app/.tickets-tracker/'"
- Line 114 fallback array: ':!.tickets/**' → ':!.tickets-tracker/**'

### plugins/dso/scripts/merge-ticket-index.py
- Module docstring line 3: 'merge-ticket-index.py — Custom Git merge driver for .tickets/.index.json' → '.tickets-tracker/.index.json'
- Line 5: '.tickets/.index.json when two branches' → '.tickets-tracker/.index.json when two branches'
- Line 23 MERGE_AUTO_RESOLVE: 'path=.tickets/.index.json' → 'path=.tickets-tracker/.index.json'
- Line 35 .gitattributes example: '.tickets/.index.json merge=tickets-index-merge' → '.tickets-tracker/.index.json merge=tickets-index-merge'
- Line 134 argparse help: 'Custom Git merge driver for .tickets/.index.json' → '.tickets-tracker/.index.json'
- Line 170 log output: 'MERGE_AUTO_RESOLVE: path=.tickets/.index.json' → 'path=.tickets-tracker/.index.json'

### .gitattributes (CREATE new file at repo root)
Content:
  # Ticket index auto-merge driver
  # Register per-clone: git config merge.tickets-index-merge.driver 'python3 plugins/dso/scripts/merge-ticket-index.py %O %A %B'
  .tickets-tracker/.index.json merge=tickets-index-merge

## Syntax Validation
After editing, verify:
  bash -n plugins/dso/hooks/compute-diff-hash.sh
  python3 -m py_compile plugins/dso/scripts/merge-ticket-index.py

## ACCEPTANCE CRITERIA

- [ ] review-gate-allowlist.conf contains .tickets-tracker/** pattern
  Verify: grep -q '.tickets-tracker/\*\*' plugins/dso/hooks/lib/review-gate-allowlist.conf
- [ ] compute-diff-hash.sh fallback uses .tickets-tracker/** exclusion
  Verify: grep -q 'tickets-tracker' plugins/dso/hooks/compute-diff-hash.sh
- [ ] merge-ticket-index.py references .tickets-tracker/.index.json
  Verify: grep -q 'tickets-tracker' plugins/dso/scripts/merge-ticket-index.py
- [ ] .gitattributes exists at repo root with tickets-tracker merge driver
  Verify: test -f .gitattributes && grep -q 'tickets-tracker' .gitattributes
- [ ] Syntax validation passes for bash files
  Verify: bash -n plugins/dso/hooks/compute-diff-hash.sh
- [ ] Syntax validation passes for Python files
  Verify: python3 -m py_compile plugins/dso/scripts/merge-ticket-index.py
- [ ] RED tests from dso-5fbs now pass (GREEN)
  Verify: bash tests/hooks/test-compute-diff-hash-tickets-tracker.sh 2>&1 | grep -q "passed"


## Notes

**2026-03-23T15:50:41Z**

CHECKPOINT 1/6: Task context loaded ✓

**2026-03-23T15:50:55Z**

CHECKPOINT 2/6: Code patterns understood ✓

**2026-03-23T15:51:01Z**

CHECKPOINT 3/6: Tests written (none required — RED tests from dso-5fbs will turn GREEN) ✓

**2026-03-23T15:51:31Z**

CHECKPOINT 4/6: Implementation complete ✓

**2026-03-23T15:51:42Z**

CHECKPOINT 5/6: Validation passed ✓

**2026-03-23T15:52:10Z**

CHECKPOINT 6/6: Done ✓
