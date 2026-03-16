#!/usr/bin/env bash
# lockpick-workflow/tests/hooks/test-hook-asymmetry.sh
# Verifies that hooks.json contains Agent PreToolUse entry with pre-agent.sh dispatcher,
# preventing silent behavioral regression when settings.json hooks are removed during
# Phase A of the GitHub plugin transition.
#
# Usage:
#   bash lockpick-workflow/tests/hooks/test-hook-asymmetry.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REPO_ROOT="$(git rev-parse --show-toplevel)"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

HOOKS_JSON="$PLUGIN_ROOT/hooks.json"

# ─────────────────────────────────────────────────────────────
# test_hooks_json_has_agent_pretooluse
# hooks.json must have an Agent matcher in PreToolUse.
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
    print('missing')
" 2>&1)
    actual="$result"
else
    actual="missing_file"
fi
assert_eq "test_hooks_json_has_agent_pretooluse" "present" "$actual"

# ─────────────────────────────────────────────────────────────
# test_agent_entry_exactly_once
# Agent matcher must appear exactly once in PreToolUse (idempotency).
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
assert_eq "test_agent_entry_exactly_once" "1" "$actual"

# ─────────────────────────────────────────────────────────────
# test_agent_entry_uses_pre_agent_sh
# The Agent PreToolUse entry must reference pre-agent.sh dispatcher.
# ─────────────────────────────────────────────────────────────
if [[ -f "$HOOKS_JSON" ]]; then
    result=$(HOOKS_JSON_PATH="$HOOKS_JSON" python3 -c "
import json, os, sys
with open(os.environ['HOOKS_JSON_PATH']) as f:
    d = json.load(f)
agent_entries = [h for h in d.get('hooks', {}).get('PreToolUse', []) if h.get('matcher') == 'Agent']
if not agent_entries:
    print('no_agent_entry')
    sys.exit(0)
entry = agent_entries[0]
cmds = [h.get('command', '') for h in entry.get('hooks', [])]
if any('pre-agent.sh' in cmd for cmd in cmds):
    print('has_pre_agent')
else:
    print('missing_pre_agent')
" 2>&1)
    actual="$result"
else
    actual="missing_file"
fi
assert_eq "test_agent_entry_uses_pre_agent_sh" "has_pre_agent" "$actual"

# ─────────────────────────────────────────────────────────────
# test_agent_entry_uses_plugin_root
# The Agent PreToolUse command must use \${CLAUDE_PLUGIN_ROOT} (not hardcoded paths).
# ─────────────────────────────────────────────────────────────
if [[ -f "$HOOKS_JSON" ]]; then
    result=$(HOOKS_JSON_PATH="$HOOKS_JSON" python3 -c "
import json, os, sys
with open(os.environ['HOOKS_JSON_PATH']) as f:
    d = json.load(f)
agent_entries = [h for h in d.get('hooks', {}).get('PreToolUse', []) if h.get('matcher') == 'Agent']
if not agent_entries:
    print('no_agent_entry')
    sys.exit(0)
entry = agent_entries[0]
cmds = [h.get('command', '') for h in entry.get('hooks', [])]
if any('\${CLAUDE_PLUGIN_ROOT}' in cmd for cmd in cmds):
    print('uses_plugin_root')
else:
    print('missing_plugin_root')
" 2>&1)
    actual="$result"
else
    actual="missing_file"
fi
assert_eq "test_agent_entry_uses_plugin_root" "uses_plugin_root" "$actual"

# ─────────────────────────────────────────────────────────────
# test_all_expected_pretooluse_matchers_present
# All pre-existing PreToolUse hooks must still be present after adding Agent.
# ─────────────────────────────────────────────────────────────
if [[ -f "$HOOKS_JSON" ]]; then
    result=$(HOOKS_JSON_PATH="$HOOKS_JSON" python3 -c "
import json, os, sys
with open(os.environ['HOOKS_JSON_PATH']) as f:
    d = json.load(f)
expected = {'Bash', 'Edit', 'Write', 'ExitPlanMode', 'TaskOutput', 'Agent'}
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
