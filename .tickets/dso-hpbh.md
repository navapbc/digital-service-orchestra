---
id: dso-hpbh
status: in_progress
deps: []
links: []
created: 2026-03-19T18:19:02Z
type: task
priority: 1
assignee: Joe Oakhart
parent: dso-jt4w
jira_key: DIG-85
---
# Remove CLAUDE_PLUGIN_ROOT override from .claude/settings.json

Remove the `CLAUDE_PLUGIN_ROOT` entry from the `env` section of `.claude/settings.json`.
This override points to the repo root (`/Users/joeoakhart/digital-service-orchestra`)
instead of the plugin cache path that Claude Code auto-sets. Removing it lets the
auto-set value flow through to plugin scripts unmodified.

## ACCEPTANCE CRITERIA

- `.claude/settings.json` no longer contains a `CLAUDE_PLUGIN_ROOT` key in `env`
  Verify: `{ python3 -c "import json; d=json.load(open('.claude/settings.json')); assert 'CLAUDE_PLUGIN_ROOT' not in d.get('env',{})" && echo PASS; } || echo FAIL`
- Other env vars in settings.json are preserved unchanged
  Verify: `test -f .claude/settings.json && python3 -c "import json; json.load(open('.claude/settings.json'))" && echo PASS || echo FAIL`

## File Impact

- `.claude/settings.json`


## Notes

<!-- note-id: t1h7msjm -->
<!-- timestamp: 2026-03-19T20:13:42Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 1/6: Task context loaded ✓

<!-- note-id: 02gaiky8 -->
<!-- timestamp: 2026-03-19T20:13:56Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 2/6: Code patterns understood ✓

<!-- note-id: evecs0a9 -->
<!-- timestamp: 2026-03-19T20:14:04Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 3/6: Tests written (none required) ✓

<!-- note-id: koneppkn -->
<!-- timestamp: 2026-03-19T20:15:19Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 4/6: Implementation complete ✓

<!-- note-id: 79085qs9 -->
<!-- timestamp: 2026-03-19T20:15:31Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 5/6: Validation passed ✓

<!-- note-id: zniavdah -->
<!-- timestamp: 2026-03-19T20:15:35Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 6/6: Done ✓
