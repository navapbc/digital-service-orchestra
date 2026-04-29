#!/usr/bin/env bash
# tests/scripts/test-create-dso-app-broken-plugin-cache.sh
#
# RED test for bug d997-f7bf:
#   When detect_dso_plugin_root() accepts a partial plugin cache that has
#   .claude-plugin/plugin.json but is missing templates/host-project/dso,
#   the shim install fallback currently only WARNs and proceeds to exec claude.
#   After the fix, the script must EXIT NON-ZERO and never reach exec claude.
#
# Scenario: broken cache (plugin.json present, templates/host-project/dso absent)
#   - HOME is redirected to a temp dir containing the broken cache structure
#   - CLAUDE_PLUGIN_ROOT is cleared so only the cache probe (2b) fires
#   - MARKETPLACE_BASE is cleared so probe 2 (marketplace layout) does not fire
#   - _PLUGIN_ROOT is cleared so probe 3 (dev env) does not fire
#   - claude stub records invocation so the test can detect if exec claude was reached
#
# The test asserts:
#   1. Script exits non-zero
#   2. Error message mentions "shim", "templates", or "incomplete"
#   3. claude stub was NOT invoked (exec claude was not reached)
#
# RED: all three assertions fail before the fix (script WARNs and proceeds).
# GREEN: all three assertions pass after the fix.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRIPT_UNDER_TEST="$PLUGIN_ROOT/scripts/create-dso-app.sh"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

TMPDIRS=()
trap 'rm -rf "${TMPDIRS[@]}"' EXIT

echo "=== test-create-dso-app-broken-plugin-cache.sh ==="

# Helper: write a stub command to a dir
_write_stub() {
    local dir="$1" name="$2" body="$3"
    printf '#!/bin/sh\n%s\n' "$body" > "$dir/$name"
    chmod +x "$dir/$name"
}

# ── test_broken_plugin_cache_exits_nonzero ────────────────────────────────────
# When the plugin cache has .claude-plugin/plugin.json but is missing
# templates/host-project/dso, the script must exit non-zero with a diagnostic
# message — it must NOT proceed to exec claude.
#
# RED: fails before fix because shim fallback only WARNs and continues.
# GREEN: passes after fix adds exit 1 (or equivalent guard) in the shim path.
test_broken_plugin_cache_exits_nonzero() {
    local T
    T=$(mktemp -d)
    TMPDIRS+=("$T")

    # Build a fake HOME with a broken plugin cache:
    # Has .claude-plugin/plugin.json (so probe 2b accepts it as plugin_root)
    # but is MISSING templates/host-project/dso (so shim install fails)
    local fake_home="$T/fake_home"
    local cache_dir="$fake_home/.claude/plugins/cache/digital-service-orchestra/dso/1.0.0"
    mkdir -p "$cache_dir/.claude-plugin"
    printf '{"name":"dso","version":"1.0.0"}\n' > "$cache_dir/.claude-plugin/plugin.json"
    # Intentionally do NOT create templates/host-project/dso

    # Build the project directory the installer will target
    local project_dir="$T/my-project"
    # Pre-create minimal project structure (simulating post-clone state)
    # so the installer proceeds past clone and reaches the shim install step.
    mkdir -p "$project_dir/src/app"
    printf '{"name":"{{PROJECT_NAME}}","scripts":{"dev":"next dev"},"dependencies":{"next":"^14.0.0"}}\n' \
        > "$project_dir/package.json"
    touch "$project_dir/src/app/page.tsx"
    mkdir -p "$project_dir/.claude"
    touch "$project_dir/CLAUDE.md"

    # Sentinel file: written by the claude stub if exec claude is reached
    local claude_invoked_marker="$T/claude_was_invoked"

    # Build stub bin directory
    local stub_bin
    stub_bin=$(mktemp -d)
    TMPDIRS+=("$stub_bin")

    # node_prefix for brew --prefix node@20
    local node_prefix
    node_prefix=$(mktemp -d)
    TMPDIRS+=("$node_prefix")
    mkdir -p "$node_prefix/bin"

    # brew stub: all brew operations succeed (dependencies pass)
    cat > "$stub_bin/brew" <<BREWEOF
#!/bin/sh
case "\$*" in
  "--version"|"-v")         echo "Homebrew 4.0.0" ;;
  "install node@20")        : ;;
  "list node@20")           : ;;
  "--prefix node@20")       echo "$node_prefix" ;;
  "install --cask "*)       : ;;
  "shellenv")               echo "export PATH=\"\$PATH\"" ;;
  *)                        : ;;
esac
exit 0
BREWEOF
    chmod +x "$stub_bin/brew"

    # git stub: on clone, return without creating project dir content
    # (project_dir is pre-created above so the installer proceeds past clone)
    cat > "$stub_bin/git" <<'GITSTUB'
#!/bin/sh
exit 0
GITSTUB
    chmod +x "$stub_bin/git"

    # claude stub: records invocation only for the final `exec claude` (no args).
    # The script's probe 4 calls `claude plugin install ...` and `claude plugin
    # marketplace add ...` — those are NOT what we want to detect. We want to
    # know specifically if the script reached `exec claude` at the end of main().
    cat > "$stub_bin/claude" <<CLAUDESTUB
#!/bin/sh
if [ "\$#" -eq 0 ]; then
    touch "$claude_invoked_marker"
fi
exit 0
CLAUDESTUB
    chmod +x "$stub_bin/claude"

    # Remaining dependency stubs
    _write_stub "$stub_bin" "bash"       "echo \"GNU bash, version 5.2.15(1)-release (x86_64)\"; exit 0"
    _write_stub "$stub_bin" "greadlink"  "exit 0"
    _write_stub "$stub_bin" "pre-commit" "exit 0"
    _write_stub "$stub_bin" "python3"    "exit 0"
    _write_stub "$stub_bin" "docker"     "exit 0"
    _write_stub "$stub_bin" "npm"        "exit 0"
    _write_stub "$stub_bin" "node"       "echo \"v20.11.0\"; exit 0"
    _write_stub "$stub_bin" "uv"         "exit 0"
    _write_stub "$stub_bin" "sg"         "exit 0"
    _write_stub "$stub_bin" "semgrep"    "exit 0"
    # Proxy stubs: real system commands needed for string/path operations
    _write_stub "$stub_bin" "grep"       '/usr/bin/grep "$@"'
    _write_stub "$stub_bin" "head"       '/usr/bin/head "$@"'
    _write_stub "$stub_bin" "dirname"    '/usr/bin/dirname "$@"'
    _write_stub "$stub_bin" "tr"         '/usr/bin/tr "$@"'
    _write_stub "$stub_bin" "sed"        '/usr/bin/sed "$@"'
    _write_stub "$stub_bin" "find"       '/usr/bin/find "$@"'
    _write_stub "$stub_bin" "mkdir"      '/bin/mkdir "$@"'
    _write_stub "$stub_bin" "touch"      '/usr/bin/touch "$@"'
    _write_stub "$stub_bin" "date"       '/bin/date "$@"'
    _write_stub "$stub_bin" "rm"         '/bin/rm "$@"'
    _write_stub "$stub_bin" "cp"         '/bin/cp "$@"'
    _write_stub "$stub_bin" "chmod"      '/bin/chmod "$@"'

    # Invoke the installer:
    #   - HOME=$fake_home  → cache probe 2b picks up the broken cache directory
    #   - CLAUDE_PLUGIN_ROOT=''  → probe 1 disabled
    #   - MARKETPLACE_BASE=/nonexistent  → probe 2 (marketplace layout) skipped
    #   - _PLUGIN_ROOT effectively unset because we source with an isolated env
    # Pipe newline to stdin to acknowledge the "press Enter to continue" prompt.
    local output exit_code=0
    output=$(HOME="$fake_home" \
             MARKETPLACE_BASE="/nonexistent_marketplace" \
             CLAUDE_PLUGIN_ROOT="" \
             PATH="$stub_bin" \
             /bin/bash "$SCRIPT_UNDER_TEST" "my-project" "$T" <<< $'\n' 2>&1) || exit_code=$?

    # Assertion 1: script must exit non-zero
    assert_ne "broken cache: script exits non-zero" "0" "$exit_code"

    # Assertion 2: error message must mention shim, templates, or incomplete
    local diag_found="no"
    if /usr/bin/grep -qiE 'shim|template|incomplete|not found|missing' <<< "$output"; then
        diag_found="yes"
    fi
    assert_eq "broken cache: diagnostic message about shim/templates" "yes" "$diag_found"

    # Assertion 3: claude must NOT have been invoked (exec claude not reached)
    local claude_reached="no"
    [[ -f "$claude_invoked_marker" ]] && claude_reached="yes"
    assert_eq "broken cache: claude stub was NOT invoked" "no" "$claude_reached"
}

# ── Run tests ─────────────────────────────────────────────────────────────────
test_broken_plugin_cache_exits_nonzero

print_summary
