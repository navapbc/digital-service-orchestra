---
id: dso-yv90
status: open
deps: [dso-5fbs]
links: []
created: 2026-03-23T15:20:14Z
type: task
priority: 1
assignee: Joe Oakhart
parent: w21-wbqz
---
# Update hook behavioral guards (tk → ticket command detection)

Update all hook files that contain behavioral guards detecting tk commands to detect ticket commands instead. The tk wrapper remains valid for Jira sync (tk sync).

## Depends on
dso-5fbs (RED test must exist before this task)

## Files to Edit

### plugins/dso/hooks/lib/pre-bash-functions.sh
- Line 152: ${CREATE_CMD:-tk create} → ${CREATE_CMD:-ticket create}
- Line 277 error message: 'tk create "Fix <check> failure"' → 'ticket create "Fix <check> failure"'
- Line 385 error message: 'tk commands work from any directory' → 'ticket commands work from any directory'
- Lines 507-508 early-exit guard: if [[ "$INPUT" != *"tk"* ]] → if [[ "$INPUT" != *"ticket "* ]]
  (More specific than old guard; avoids false positives on unrelated commands containing 'ticket' as English word since we check for 'ticket ' with trailing space)
- Lines 518-519 bug close only path: update comment 'Only act on `tk close` commands' → 'Only act on `ticket transition ... closed` commands'
- Lines 518-519 regex: tk[[:space:]]+close[[:space:]]+ → ticket[[:space:]]+transition[[:space:]]+
- Line 865 allowlist: keep "$FIRST_TOKEN" == "tk" (tk sync still valid); comment: 'ticket CLI patterns (ticket *, tk *)' — keep both
- Line 821 comment: 'go through ticket CLI commands (ticket *, tk *)' — keep (tk still valid for Jira sync)
- Line 830 comment: 'Allowlist: ticket CLI scripts (ticket, tk)' — keep

### plugins/dso/hooks/closed-parent-guard.sh
- Line 6-7 comments: update 'tk create ... --parent <id>' → 'ticket create ... --parent <id>'
- Line 33-34 usage examples: 'tk create' → 'ticket create', 'tk dep <child-id> <parent-id>' → 'ticket link <child-id> <parent-id> depends_on'
- Line 37 regex: tk[[:space:]]+create[[:space:]].*--parent → ticket[[:space:]]+create[[:space:]].*--parent
- Line 39 regex: tk[[:space:]]+dep[[:space:]]+ → ticket[[:space:]]+link[[:space:]]+
  Note: ticket CLI uses 'ticket link <id1> <id2> <relation>' not 'ticket dep'
- Line 40 comment: 'For `tk dep <child-id> <parent-id>`' → 'For `ticket link <child-id> <parent-id>`'
- Line 71 error message: 'tk status ${PARENT_ID} open' → 'ticket transition ${PARENT_ID} closed open'

### plugins/dso/hooks/bug-close-guard.sh
- Comment line 9: 'Only fires on `tk close` commands' → 'Only fires on `ticket transition ... closed` commands'
- Update any tk close detection in the script body

### plugins/dso/hooks/lib/deps.sh
- Line 618 comment: '.tickets/ — ticket files managed by the tk CLI' → '.tickets-tracker/ — ticket files managed by the ticket CLI'

### plugins/dso/hooks/check-validation-failures.sh
- Line 75 comment: 'TICKETS_DIR env var overrides ticket storage location (consistent with tk CLI)' → '(consistent with ticket CLI)'
- Line 179 comment: 'Format: "Tracked: mypy (tk-789)"' — update tk-789 example ID if it refers to old tk system

### plugins/dso/scripts/merge-to-main.sh
- Line 8 comment: 'tk (the issue tracker) uses file-per-issue storage under .tickets/' → update to reflect v3 system
- Line 898 comment: 'Exclude the configured tickets directory — ticket files are created by tk' → 'created by ticket CLI'
- Line 912 comment: 'tk commands (close, create, add-note) write .tickets/ files' → 'ticket commands write .tickets-tracker/ files'

## Syntax Validation
After editing all files:
  bash -n plugins/dso/hooks/lib/pre-bash-functions.sh
  bash -n plugins/dso/hooks/closed-parent-guard.sh
  bash -n plugins/dso/hooks/bug-close-guard.sh
  bash -n plugins/dso/hooks/lib/deps.sh
  bash -n plugins/dso/hooks/check-validation-failures.sh
  bash -n plugins/dso/scripts/merge-to-main.sh

