#!/usr/bin/env bash
# tests/hooks/test-hook-asymmetry.sh
# Verifies that hooks.json does NOT contain an Agent PreToolUse entry —
# the worktree isolation guard was removed because the Claude Code platform
# already prevents sub-agents from using the Agent tool at all.
#
# Usage:
#   bash tests/hooks/test-hook-asymmetry.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
REPO_ROOT="$(git rev-parse --show-toplevel)"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

HOOKS_JSON="$DSO_PLUGIN_DIR/.claude-plugin/plugin.json"

# ─────────────────────────────────────────────────────────────
# test_hooks_json_has_no_agent_pretooluse
# hooks.json must NOT have an Agent matcher in PreToolUse —
# the worktree isolation guard was removed (dead code cleanup).
# ─────────────────────────────────────────────────────────────
if [[ -f "$HOOKS_JSON" ]]; then
    result=$(HOOKS_JSON_PATH="$HOOKS_JSON" python3 -c "
import json, os, sys
with open(os.environ['HOOKS_JSON_PATH']) as f:
    d = json.load(f)
matchers = [h['matcher'] for h in d.get('hooks', {}).get('PreToolUse', [])]
if 'Agent' in matchers:
    print('present')
else:
    print('absent')
" 2>&1)
    actual="$result"
else
    actual="missing_file"
fi
assert_eq "test_hooks_json_has_no_agent_pretooluse" "absent" "$actual"

# ─────────────────────────────────────────────────────────────
# test_agent_entry_count_is_zero
# Agent matcher must not appear in PreToolUse at all.
# ─────────────────────────────────────────────────────────────
if [[ -f "$HOOKS_JSON" ]]; then
    result=$(HOOKS_JSON_PATH="$HOOKS_JSON" python3 -c "
import json, os, sys
with open(os.environ['HOOKS_JSON_PATH']) as f:
    d = json.load(f)
count = sum(1 for h in d.get('hooks', {}).get('PreToolUse', []) if h.get('matcher') == 'Agent')
print(str(count))
" 2>&1)
    actual="$result"
else
    actual="missing_file"
fi
assert_eq "test_agent_entry_count_is_zero" "0" "$actual"

# ─────────────────────────────────────────────────────────────
# test_pre_agent_sh_not_referenced_in_hooks_json
# pre-agent.sh must not be referenced in any hook command.
# ─────────────────────────────────────────────────────────────
if [[ -f "$HOOKS_JSON" ]]; then
    result=$(HOOKS_JSON_PATH="$HOOKS_JSON" python3 -c "
import json, os, sys
with open(os.environ['HOOKS_JSON_PATH']) as f:
    d = json.load(f)
hooks_sections = d.get('hooks', {})
found = False
for event_hooks in hooks_sections.values():
    for entry in event_hooks:
        for hook in entry.get('hooks', []):
            if 'pre-agent.sh' in hook.get('command', ''):
                found = True
print('referenced' if found else 'absent')
" 2>&1)
    actual="$result"
else
    actual="missing_file"
fi
assert_eq "test_pre_agent_sh_not_referenced_in_hooks_json" "absent" "$actual"

# ─────────────────────────────────────────────────────────────
# test_all_expected_pretooluse_matchers_present
# All required PreToolUse hooks must be present (Agent excluded).
# ─────────────────────────────────────────────────────────────
if [[ -f "$HOOKS_JSON" ]]; then
    result=$(HOOKS_JSON_PATH="$HOOKS_JSON" python3 -c "
import json, os, sys
with open(os.environ['HOOKS_JSON_PATH']) as f:
    d = json.load(f)
expected = {'Bash', 'Edit', 'Write', 'ExitPlanMode', 'TaskOutput'}
actual = {h['matcher'] for h in d.get('hooks', {}).get('PreToolUse', [])}
missing = expected - actual
if missing:
    print('missing: ' + ', '.join(sorted(missing)))
else:
    print('all_present')
" 2>&1)
    actual="$result"
else
    actual="missing_file"
fi
assert_eq "test_all_expected_pretooluse_matchers_present" "all_present" "$actual"

print_summary
