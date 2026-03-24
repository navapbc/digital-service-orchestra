#!/usr/bin/env bash
# tests/hooks/test-run-hook-relative-paths.sh
# Bug e724-31a3: Verifies run-hook.sh resolves relative dispatcher paths
# against its own hooks/ directory, so plugin.json can use relative paths
# to minimize ${CLAUDE_PLUGIN_ROOT} occurrences in error messages.
#
# Usage: bash tests/hooks/test-run-hook-relative-paths.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git rev-parse --show-toplevel)"
DSO_PLUGIN_DIR="$REPO_ROOT/plugins/dso"
RUN_HOOK="$DSO_PLUGIN_DIR/hooks/run-hook.sh"

source "$REPO_ROOT/tests/lib/assert.sh"

# ─────────────────────────────────────────────────────────────
# test_run_hook_resolves_relative_path
# run-hook.sh should resolve a relative path (e.g., "dispatchers/pre-bash.sh")
# against its hooks/ directory, just as it resolves absolute paths.
# We test this by creating a temp hook that echoes "OK" and passing it as
# a relative path.
# ─────────────────────────────────────────────────────────────
TMPDIR_TEST=$(mktemp -d /tmp/test-run-hook-rel.XXXXXX)
trap 'rm -rf "$TMPDIR_TEST"' EXIT

# Create a minimal hook script in a relative subdir mirroring the dispatcher pattern
mkdir -p "$TMPDIR_TEST/hooks/dispatchers"
cat > "$TMPDIR_TEST/hooks/dispatchers/test-echo.sh" <<'HOOKEOF'
#!/usr/bin/env bash
echo "RELATIVE_OK"
exit 0
HOOKEOF
chmod +x "$TMPDIR_TEST/hooks/dispatchers/test-echo.sh"

# Copy run-hook.sh to the temp hooks dir so it can resolve relative paths
cp "$RUN_HOOK" "$TMPDIR_TEST/hooks/run-hook.sh"
chmod +x "$TMPDIR_TEST/hooks/run-hook.sh"

# Also need the hooks/lib dir for CLAUDE_PLUGIN_ROOT resolution fallback
mkdir -p "$TMPDIR_TEST/hooks/lib"

# Test: run-hook.sh with a relative dispatcher path should work
output=$(CLAUDE_PLUGIN_ROOT="$TMPDIR_TEST" "$TMPDIR_TEST/hooks/run-hook.sh" "dispatchers/test-echo.sh" 2>&1)
actual_exit=$?

if [[ "$output" == *"RELATIVE_OK"* && "$actual_exit" -eq 0 ]]; then
    actual="resolved"
else
    actual="not_resolved (exit=$actual_exit, output=$output)"
fi
assert_eq "test_run_hook_resolves_relative_path" "resolved" "$actual"

# ─────────────────────────────────────────────────────────────
# test_run_hook_absolute_path_still_works
# Absolute paths must continue to work (backwards compatibility).
# ─────────────────────────────────────────────────────────────
output=$(CLAUDE_PLUGIN_ROOT="$TMPDIR_TEST" "$TMPDIR_TEST/hooks/run-hook.sh" "$TMPDIR_TEST/hooks/dispatchers/test-echo.sh" 2>&1)
actual_exit=$?

if [[ "$output" == *"RELATIVE_OK"* && "$actual_exit" -eq 0 ]]; then
    actual="works"
else
    actual="broken (exit=$actual_exit, output=$output)"
fi
assert_eq "test_run_hook_absolute_path_still_works" "works" "$actual"

print_summary
