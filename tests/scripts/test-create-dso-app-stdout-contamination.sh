#!/usr/bin/env bash
# tests/scripts/test-create-dso-app-stdout-contamination.sh
#
# Regression test for bug 6a05-4e22-b950-44cd:
#   detect_dso_plugin_root() runs `claude plugin install` and
#   `claude plugin marketplace add` during auto-install (probe 4). The function
#   is called via command substitution (resolved_plugin_root=$(detect...)), so
#   any stdout from claude contaminates the captured path. Real-world failure
#   showed marketplace progress messages prepended to the resolved path,
#   yielding "DSO shim template not found at Adding marketplace…[stdout
#   noise]…/path/to/plugin" downstream.
#
# Test approach:
#   Source the script with __DSO_DRY_RUN=1 (or simulate by extracting the
#   detect_dso_plugin_root function), provide a `claude` stub that emits
#   substantial stdout noise on `plugin install` / `plugin marketplace add`,
#   pre-populate the marketplace cache so detection succeeds, then assert
#   the captured path is the clean fixture path with no noise prefix.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRIPT_UNDER_TEST="$PLUGIN_ROOT/scripts/create-dso-app.sh"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-create-dso-app-stdout-contamination.sh ==="

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

# Build a fake HOME with NO plugin initially — forces probe 4 (auto-install).
fake_home="$T/fake_home"
mkdir -p "$fake_home/.claude/plugins/marketplaces"

# Path the noisy claude stub will materialize during `plugin install`
mp_target="$fake_home/.claude/plugins/marketplaces/digital-service-orchestra/plugins/dso"

# `claude` stub: emit substantial stdout noise on EVERY invocation AND, on
# `plugin install`, materialize the marketplace plugin so the function's
# post-install re-probe (still inside probe 4) finds it. If the function
# captures the install's stdout (no redirection), the noise contaminates
# the resolved path.
stub_bin="$T/bin"
mkdir -p "$stub_bin"
cat > "$stub_bin/claude" <<CLAUDE_STUB
#!/usr/bin/env bash
echo "Adding marketplace…Refreshing marketplace cache (timeout: 120s)…"
echo "Cloning repository (timeout: 120s): https://github.com/example/repo.git"
echo "Clone complete, validating marketplace…"
echo "✅ Successfully installed plugin: dso@digital-service-orchestra (scope: user)"
# On 'plugin install', materialize a complete marketplace plugin so the
# function's post-install re-probe succeeds.
if [ "\${1:-}" = "plugin" ] && [ "\${2:-}" = "install" ]; then
    mkdir -p "$mp_target/.claude-plugin" "$mp_target/templates/host-project"
    printf '{"name":"dso","version":"9.9.9"}\n' > "$mp_target/.claude-plugin/plugin.json"
    printf '#!/usr/bin/env bash\necho dso-shim\n' > "$mp_target/templates/host-project/dso"
    chmod +x "$mp_target/templates/host-project/dso"
fi
exit 0
CLAUDE_STUB
chmod +x "$stub_bin/claude"

# Pre-create the project dir so detect's `cd "$project_dir"` doesn't error
mkdir -p "$T/proj"

# Extract detect_dso_plugin_root into a sourceable shim. Force probe 2
# (marketplace) by pinning _DSO_MARKETPLACE_BASE to the fake home and
# leaving the load-time CLAUDE_PLUGIN_ROOT capture empty. This isolates
# the test from the developer's real plugin install.
DETECT_SHIM="$T/detect-shim.sh"
{
    echo "_DSO_CLAUDE_PLUGIN_ROOT_SET=1"  # explicitly disable probe 1
    echo "_DSO_CLAUDE_PLUGIN_ROOT=''"
    echo "_DSO_MARKETPLACE_BASE='$fake_home/.claude/plugins/marketplaces'"
    echo "_PLUGIN_ROOT=''"  # disable probe 3 (dev fallback)
    awk '/^detect_dso_plugin_root\(\)/{found=1} found{print; if(/^\}$/){exit}}' "$SCRIPT_UNDER_TEST"
} > "$DETECT_SHIM"

# Run detect_dso_plugin_root with the noisy claude on PATH; capture stdout
# the way create-dso-app.sh does (resolved_plugin_root=$(detect_dso_plugin_root ...)).
RESOLVED=$(
    HOME="$fake_home" \
    PATH="$stub_bin:/usr/bin:/bin" \
    bash -c "set -uo pipefail; source '$DETECT_SHIM'; detect_dso_plugin_root '$T/proj'"
)

# Behavioral assertion: the captured value MUST be exactly the clean plugin
# path. ANY stdout from `claude` would prepend noise. Pre-fix the noisy
# marketplace string would precede the path; post-fix, the redirects
# (`>/dev/null 2>&1` on `claude plugin marketplace add` and `claude plugin
# install`) prevent contamination.
EXPECTED="$mp_target"
assert_eq "test_resolved_plugin_root_has_no_stdout_noise" "$EXPECTED" "$RESOLVED"

# Also confirm the captured value cannot contain any line of the well-known
# noise patterns that bug 6a05 reported.
if echo "$RESOLVED" | grep -q "Adding marketplace\|Cloning repository\|Successfully installed"; then
    (( ++FAIL ))
    printf "FAIL: test_resolved_plugin_root_has_no_stdout_noise: noise leaked into path\n  got: %s\n" "$RESOLVED" >&2
else
    (( ++PASS ))
    echo "test_resolved_plugin_root_has_no_stdout_noise (no-noise verifier) ... PASS"
fi

print_summary
