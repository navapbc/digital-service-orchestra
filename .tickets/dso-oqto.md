---
id: dso-oqto
status: closed
deps: []
links: []
created: 2026-03-18T17:29:56Z
type: task
priority: 1
assignee: Joe Oakhart
parent: dso-mjdp
---
# Deregister PreCompact hook block from .claude-plugin/plugin.json

Remove the PreCompact hook registration block from .claude-plugin/plugin.json so context compaction no longer invokes any hook.

## Implementation Steps
1. Open .claude-plugin/plugin.json
2. Remove the entire PreCompact block (lines 19-28 in current file):
   {
     "PreCompact": [
       {
         "matcher": "",
         "hooks": [
           {
             "type": "command",
             "command": "${CLAUDE_PLUGIN_ROOT}/hooks/run-hook.sh ${CLAUDE_PLUGIN_ROOT}/hooks/pre-compact-checkpoint.sh"
           }
         ]
       }
     ]
   }
3. Ensure no trailing comma is left after the removal — validate JSON.
4. Verify no other PreCompact registration exists in .claude-plugin/ or .claude/ (settings.json override check per story considerations).

## TDD Requirement (RED before GREEN)
Write this failing test first:
  grep -c 'PreCompact' .claude-plugin/plugin.json
  # Before the fix: returns count > 0 (test is RED)
  # After the fix: returns 0 (test is GREEN)

## Constraints
- Only .claude-plugin/plugin.json is modified in this task
- JSON must remain valid after removal (python3 -m json.tool to verify)
- All other hook event registrations (SessionStart, PreToolUse, PostToolUse, Stop, PostToolUseFailure) must remain intact
- Confirm this is the only PreCompact registration point (no settings.json override)

## ACCEPTANCE CRITERIA

- [ ] `bash tests/run-all.sh` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && bash tests/run-all.sh
- [ ] `ruff check scripts/*.py tests/**/*.py` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff check scripts/*.py tests/**/*.py
- [ ] `ruff format --check scripts/*.py tests/**/*.py` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff format --check scripts/*.py tests/**/*.py
- [ ] .claude-plugin/plugin.json contains no PreCompact key
  Verify: ! grep -q 'PreCompact' .claude-plugin/plugin.json
- [ ] .claude-plugin/plugin.json is valid JSON
  Verify: python3 -m json.tool .claude-plugin/plugin.json > /dev/null
- [ ] All other hook event registrations remain intact (SessionStart, PreToolUse, PostToolUse, Stop, PostToolUseFailure)
  Verify: grep -q 'SessionStart' .claude-plugin/plugin.json && grep -q 'PreToolUse' .claude-plugin/plugin.json && grep -q 'PostToolUse' .claude-plugin/plugin.json && grep -q 'Stop' .claude-plugin/plugin.json && grep -q 'PostToolUseFailure' .claude-plugin/plugin.json
- [ ] No other PreCompact registration exists anywhere in the repo
  Verify: ! grep -rq 'PreCompact' .claude-plugin/ && ! find . -name 'settings.json' -not -path '*/.git/*' -exec grep -l 'PreCompact' {} \; 2>/dev/null | grep -q .

## Notes

**2026-03-18T17:44:01Z**

CHECKPOINT 6/6: Done ✓ — Files: .claude-plugin/plugin.json. PreCompact hook block removed. Tests: pass.
