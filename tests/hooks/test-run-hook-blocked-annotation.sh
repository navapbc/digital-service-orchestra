#!/usr/bin/env bash
# tests/hooks/test-run-hook-blocked-annotation.sh
# Bug 8c3d-b5ac: Verifies run-hook.sh appends the resolved CLAUDE_PLUGIN_ROOT
# path to stderr when a hook exits with code 2 (BLOCKED), so agents get an
# actionable location even when the Claude Code harness shows the raw
# '${CLAUDE_PLUGIN_ROOT}' token in the error-message prefix.
#
# Usage: bash tests/hooks/test-run-hook-blocked-annotation.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git rev-parse --show-toplevel)"
DSO_PLUGIN_DIR="$REPO_ROOT/plugins/dso"
RUN_HOOK="$DSO_PLUGIN_DIR/hooks/run-hook.sh"

source "$REPO_ROOT/tests/lib/assert.sh"

TMPDIR_TEST=$(mktemp -d /tmp/test-run-hook-blocked.XXXXXX)
trap 'rm -rf "$TMPDIR_TEST"' EXIT

# Set up a minimal plugin-like directory structure so the fallback guard works
mkdir -p "$TMPDIR_TEST/hooks/lib" "$TMPDIR_TEST/hooks/dispatchers"
cp "$RUN_HOOK" "$TMPDIR_TEST/hooks/run-hook.sh"
chmod +x "$TMPDIR_TEST/hooks/run-hook.sh"

# ─────────────────────────────────────────────────────────────
# test_blocked_hook_annotates_stderr
# When a hook exits 2 (BLOCKED), run-hook.sh must append a
# '[hook location: <resolved-path>/hooks/run-hook.sh]' line to stderr.
# ─────────────────────────────────────────────────────────────
cat > "$TMPDIR_TEST/hooks/dispatchers/blocked-hook.sh" <<'HOOKEOF'
#!/usr/bin/env bash
echo "BLOCKED: test block reason" >&2
exit 2
HOOKEOF
chmod +x "$TMPDIR_TEST/hooks/dispatchers/blocked-hook.sh"

stderr_output=$(CLAUDE_PLUGIN_ROOT="$TMPDIR_TEST" \
    "$TMPDIR_TEST/hooks/run-hook.sh" "dispatchers/blocked-hook.sh" 2>&1 >/dev/null)
actual_exit=$?

if [[ "$stderr_output" == *"[hook location:"* && "$stderr_output" == *"$TMPDIR_TEST"* ]]; then
    actual="has_location_annotation"
else
    actual="missing_annotation (exit=$actual_exit, stderr=$stderr_output)"
fi
assert_eq "test_blocked_hook_annotates_stderr" "has_location_annotation" "$actual"

# ─────────────────────────────────────────────────────────────
# test_blocked_hook_exits_2
# run-hook.sh must pass through exit code 2 from a blocked hook.
# ─────────────────────────────────────────────────────────────
CLAUDE_PLUGIN_ROOT="$TMPDIR_TEST" \
    "$TMPDIR_TEST/hooks/run-hook.sh" "dispatchers/blocked-hook.sh" 2>/dev/null
actual_exit=$?
if [[ "$actual_exit" -eq 2 ]]; then
    actual="exit_2"
else
    actual="wrong_exit: $actual_exit"
fi
assert_eq "test_blocked_hook_exits_2" "exit_2" "$actual"

# ─────────────────────────────────────────────────────────────
# test_allowed_hook_no_annotation
# When a hook exits 0 (allowed), run-hook.sh must NOT add a
# '[hook location:]' annotation — only BLOCKED hooks get it.
# ─────────────────────────────────────────────────────────────
cat > "$TMPDIR_TEST/hooks/dispatchers/allowed-hook.sh" <<'HOOKEOF'
#!/usr/bin/env bash
echo "some stderr from allowed hook" >&2
exit 0
HOOKEOF
chmod +x "$TMPDIR_TEST/hooks/dispatchers/allowed-hook.sh"

stderr_output=$(CLAUDE_PLUGIN_ROOT="$TMPDIR_TEST" \
    "$TMPDIR_TEST/hooks/run-hook.sh" "dispatchers/allowed-hook.sh" 2>&1 >/dev/null)
if [[ "$stderr_output" != *"[hook location:"* ]]; then
    actual="no_annotation"
else
    actual="unexpected_annotation: $stderr_output"
fi
assert_eq "test_allowed_hook_no_annotation" "no_annotation" "$actual"

# ─────────────────────────────────────────────────────────────
# test_blocked_hook_body_preserved
# The original BLOCKED message body must still appear in stderr
# (annotation must not replace the hook's own output).
# ─────────────────────────────────────────────────────────────
stderr_output=$(CLAUDE_PLUGIN_ROOT="$TMPDIR_TEST" \
    "$TMPDIR_TEST/hooks/run-hook.sh" "dispatchers/blocked-hook.sh" 2>&1 >/dev/null)
if [[ "$stderr_output" == *"BLOCKED: test block reason"* ]]; then
    actual="body_preserved"
else
    actual="body_missing: $stderr_output"
fi
assert_eq "test_blocked_hook_body_preserved" "body_preserved" "$actual"

print_summary
