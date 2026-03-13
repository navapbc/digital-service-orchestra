#!/usr/bin/env bash
# lockpick-workflow/tests/hooks/test-hooks-json-paths.sh
# Verifies hooks.json exists, is valid JSON, uses ${CLAUDE_PLUGIN_ROOT} paths,
# and that run-hook.sh copy contains the CLAUDE_PLUGIN_ROOT fallback guard.
#
# Usage:
#   bash lockpick-workflow/tests/hooks/test-hooks-json-paths.sh

REPO_ROOT="$(git rev-parse --show-toplevel)"

source "$REPO_ROOT/lockpick-workflow/tests/lib/assert.sh"

PLUGIN_ROOT="$REPO_ROOT/lockpick-workflow"
HOOKS_JSON="$PLUGIN_ROOT/hooks.json"

# ─────────────────────────────────────────────────────────────
# test_hooks_json_exists
# lockpick-workflow/hooks.json must exist.
# ─────────────────────────────────────────────────────────────
if [[ -f "$HOOKS_JSON" ]]; then
    actual="exists"
else
    actual="missing"
fi
assert_eq "test_hooks_json_exists" "exists" "$actual"

# ─────────────────────────────────────────────────────────────
# test_hooks_json_valid
# hooks.json must be valid JSON.
# ─────────────────────────────────────────────────────────────
if [[ -f "$HOOKS_JSON" ]] && python3 -m json.tool "$HOOKS_JSON" > /dev/null 2>&1; then
    actual="valid"
else
    actual="invalid"
fi
assert_eq "test_hooks_json_valid" "valid" "$actual"

# ─────────────────────────────────────────────────────────────
# test_hooks_json_plugin_root_refs
# All 'command' values in hooks.json must contain '${CLAUDE_PLUGIN_ROOT}'.
# ─────────────────────────────────────────────────────────────
if [[ -f "$HOOKS_JSON" ]]; then
    # Extract all command values and check each contains ${CLAUDE_PLUGIN_ROOT}
    bad_cmds=$(HOOKS_JSON_PATH="$HOOKS_JSON" python3 -c "
import json, os, sys

hooks_json_path = os.environ['HOOKS_JSON_PATH']
with open(hooks_json_path) as f:
    d = json.load(f)

bad = []
hooks_section = d.get('hooks', {})
for event, groups in hooks_section.items():
    for group in groups:
        for h in group.get('hooks', []):
            cmd = h.get('command', '')
            # Only check commands that call hook scripts (skip non-hook commands like 'bd prime')
            if '/hooks/' in cmd and '\${CLAUDE_PLUGIN_ROOT}' not in cmd:
                bad.append(cmd)

if bad:
    for b in bad:
        print(b)
    sys.exit(1)
sys.exit(0)
" 2>&1)
    if [[ $? -eq 0 ]]; then
        actual="all_have_plugin_root"
    else
        actual="missing_plugin_root: $bad_cmds"
    fi
else
    actual="missing_file"
fi
assert_eq "test_hooks_json_plugin_root_refs" "all_have_plugin_root" "$actual"

# ─────────────────────────────────────────────────────────────
# test_hooks_json_no_absolute_paths
# No 'command' values in hooks.json may contain '/Users/' or '/home/'.
# ─────────────────────────────────────────────────────────────
if [[ -f "$HOOKS_JSON" ]]; then
    abs_cmds=$(HOOKS_JSON_PATH="$HOOKS_JSON" python3 -c "
import json, os, sys

hooks_json_path = os.environ['HOOKS_JSON_PATH']
with open(hooks_json_path) as f:
    d = json.load(f)

bad = []
hooks_section = d.get('hooks', {})
for event, groups in hooks_section.items():
    for group in groups:
        for h in group.get('hooks', []):
            cmd = h.get('command', '')
            if '/Users/' in cmd or '/home/' in cmd:
                bad.append(cmd)

if bad:
    for b in bad:
        print(b)
    sys.exit(1)
sys.exit(0)
" 2>&1)
    if [[ $? -eq 0 ]]; then
        actual="no_absolute_paths"
    else
        actual="has_absolute_paths: $abs_cmds"
    fi
else
    actual="missing_file"
fi
assert_eq "test_hooks_json_no_absolute_paths" "no_absolute_paths" "$actual"

# ─────────────────────────────────────────────────────────────
# test_run_hook_fallback_guard
# lockpick-workflow/hooks/run-hook.sh must contain CLAUDE_PLUGIN_ROOT fallback logic.
# ─────────────────────────────────────────────────────────────
RUN_HOOK_COPY="$PLUGIN_ROOT/hooks/run-hook.sh"
if [[ -f "$RUN_HOOK_COPY" ]] && grep -q "CLAUDE_PLUGIN_ROOT" "$RUN_HOOK_COPY"; then
    actual="has_fallback_guard"
else
    actual="missing_fallback_guard"
fi
assert_eq "test_run_hook_fallback_guard" "has_fallback_guard" "$actual"

# ─────────────────────────────────────────────────────────────
# test_settings_json_no_empty_matcher_pre
# settings.json must NOT have an empty-matcher PreToolUse entry.
# (Removed to reduce process count per tool call.)
# ─────────────────────────────────────────────────────────────
SETTINGS_JSON="$REPO_ROOT/.claude/settings.json"
if [[ -f "$SETTINGS_JSON" ]]; then
    empty_pre=$(SETTINGS_JSON_PATH="$SETTINGS_JSON" python3 -c "
import json, os, sys
with open(os.environ['SETTINGS_JSON_PATH']) as f:
    d = json.load(f)
entries = [h for h in d.get('hooks', {}).get('PreToolUse', []) if h.get('matcher') == '']
sys.exit(0 if not entries else 1)
" 2>&1) && actual="no_empty_matcher_pre" || actual="has_empty_matcher_pre"
else
    actual="missing_file"
fi
assert_eq "test_settings_json_no_empty_matcher_pre" "no_empty_matcher_pre" "$actual"

# ─────────────────────────────────────────────────────────────
# test_settings_json_no_empty_matcher_post
# settings.json must NOT have an empty-matcher PostToolUse entry.
# (Removed to reduce process count per tool call.)
# ─────────────────────────────────────────────────────────────
if [[ -f "$SETTINGS_JSON" ]]; then
    empty_post=$(SETTINGS_JSON_PATH="$SETTINGS_JSON" python3 -c "
import json, os, sys
with open(os.environ['SETTINGS_JSON_PATH']) as f:
    d = json.load(f)
entries = [h for h in d.get('hooks', {}).get('PostToolUse', []) if h.get('matcher') == '']
sys.exit(0 if not entries else 1)
" 2>&1) && actual="no_empty_matcher_post" || actual="has_empty_matcher_post"
else
    actual="missing_file"
fi
assert_eq "test_settings_json_no_empty_matcher_post" "no_empty_matcher_post" "$actual"

# ─────────────────────────────────────────────────────────────
# test_bash_only_two_hook_entries
# settings.json must have exactly 1 PreToolUse Bash entry and 1 PostToolUse Bash entry.
# ─────────────────────────────────────────────────────────────
if [[ -f "$SETTINGS_JSON" ]]; then
    bash_counts=$(SETTINGS_JSON_PATH="$SETTINGS_JSON" python3 -c "
import json, os, sys
with open(os.environ['SETTINGS_JSON_PATH']) as f:
    d = json.load(f)
pre = [h for h in d.get('hooks', {}).get('PreToolUse', []) if h.get('matcher') == 'Bash']
post = [h for h in d.get('hooks', {}).get('PostToolUse', []) if h.get('matcher') == 'Bash']
if len(pre) == 1 and len(post) == 1:
    sys.exit(0)
else:
    print(f'pre={len(pre)} post={len(post)}')
    sys.exit(1)
" 2>&1) && actual="bash_two_entries" || actual="wrong_count: $bash_counts"
else
    actual="missing_file"
fi
assert_eq "test_bash_only_two_hook_entries" "bash_two_entries" "$actual"

print_summary
