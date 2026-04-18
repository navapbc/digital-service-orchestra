#!/usr/bin/env bash
# tests/scripts/test-claude-md-hook-error-handler.sh
# Structural boundary tests verifying CLAUDE.md documents the hook error handler
# pattern and enforcement boundary convention.
#
# Tests only structural presence — not content quality or wording.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CLAUDE_MD="$PLUGIN_ROOT/CLAUDE.md"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

# test_claude_md_documents_register_hook_err_handler
# CLAUDE.md must reference _dso_register_hook_err_handler for new hook authors
_register_fn_present=0
grep -q "_dso_register_hook_err_handler" "$CLAUDE_MD" && _register_fn_present=1
assert_eq "test_claude_md_documents_register_hook_err_handler" "1" "$_register_fn_present"

# test_claude_md_documents_enforcement_boundary_header
# CLAUDE.md must reference the # hook-boundary: enforcement convention
_boundary_header_present=0
grep -q "hook-boundary.*enforcement" "$CLAUDE_MD" && _boundary_header_present=1
assert_eq "test_claude_md_documents_enforcement_boundary_header" "1" "$_boundary_header_present"

# test_claude_md_documents_canonical_log_path
# CLAUDE.md must reference the canonical log path dso-hook-errors.jsonl
_canonical_path_present=0
grep -q "dso-hook-errors.jsonl" "$CLAUDE_MD" && _canonical_path_present=1
assert_eq "test_claude_md_documents_canonical_log_path" "1" "$_canonical_path_present"

# test_claude_md_no_legacy_log_path
# CLAUDE.md must NOT reference the legacy hook-error-log.jsonl path
_legacy_path_absent=1
grep -q "hook-error-log.jsonl" "$CLAUDE_MD" && _legacy_path_absent=0
assert_eq "test_claude_md_no_legacy_log_path" "1" "$_legacy_path_absent"

# test_claude_md_hook_error_handler_path_correct
# The hook-error-handler.sh reference must use the full plugin path
_full_path_present=0
grep -q "plugins/dso/hooks/lib/hook-error-handler.sh" "$CLAUDE_MD" && _full_path_present=1
assert_eq "test_claude_md_hook_error_handler_path_correct" "1" "$_full_path_present"

print_summary
