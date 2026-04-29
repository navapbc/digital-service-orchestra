#!/usr/bin/env bash
# tests/scripts/test-create-dso-app.sh
# Unit tests for create-dso-app.sh: Homebrew detection, Node 20.x PATH injection,
# and missing-deps accumulation.
#
# Tests use PATH-stubbing to mock brew, node, and other commands — no real
# Homebrew or Node installation is required. The script is always invoked via
# /bin/bash (not the PATH-resolved bash) to avoid stub-bash recursion; stub_bin
# is prepended to a minimal safe PATH (/usr/bin:/bin) so only stub commands shadow
# real ones.
#
# Usage:
#   bash tests/scripts/test-create-dso-app.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRIPT_UNDER_TEST="$PLUGIN_ROOT/scripts/create-dso-app.sh"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

TMPDIRS=()
trap 'rm -rf "${TMPDIRS[@]}"' EXIT

# Minimal safe PATH: real system commands only (no Homebrew, no user tools).
# Stubs are prepended to this base so they shadow real equivalents.
_BASE_PATH="/usr/bin:/bin"

echo "=== test-create-dso-app.sh ==="

# Helper: create a stub bin dir and register it for cleanup
_make_stub_bin() {
    local dir
    dir=$(mktemp -d)
    TMPDIRS+=("$dir")
    echo "$dir"
}

# Helper: write a stub command to a dir
_write_stub() {
    local dir="$1" name="$2" body="$3"
    printf '#!/bin/sh\n%s\n' "$body" > "$dir/$name"
    chmod +x "$dir/$name"
}

# Helper: run the script under test with an isolated PATH (stub_bin only).
# Always uses /bin/bash to avoid stub-bash recursion. grep/head stubs that
# proxy to /usr/bin are included in _all_deps_stub_bin; callers that need
# those commands in a minimal stub must add them manually.
_run_script() {
    local stub_bin="$1"
    shift
    PATH="$stub_bin" /bin/bash "$SCRIPT_UNDER_TEST" "$@" 2>&1
}

# Helper: build a "all deps present" stub bin with optional overrides.
# Returns the stub_bin path.
# Usage: _all_deps_stub_bin [node_version]
_all_deps_stub_bin() {
    local node_ver="${1:-v20.11.0}"
    local stub_bin node_prefix
    stub_bin=$(_make_stub_bin)
    node_prefix=$(mktemp -d)
    TMPDIRS+=("$node_prefix")
    mkdir -p "$node_prefix/bin"

    cat > "$stub_bin/brew" <<BREWEOF
#!/bin/sh
case "\$*" in
  "--version"|"-v")         echo "Homebrew 4.0.0" ;;
  "install node@20")        : ;;
  "list node@20")           : ;;
  "--prefix node@20")       echo "$node_prefix" ;;
  "install --cask "*)       : ;;
  *)                        : ;;
esac
exit 0
BREWEOF
    chmod +x "$stub_bin/brew"

    # bash: needed for `bash --version` call inside the script
    _write_stub "$stub_bin" "bash" "echo \"GNU bash, version 5.2.15(1)-release (x86_64)\"; exit 0"
    _write_stub "$stub_bin" "git" "exit 0"
    _write_stub "$stub_bin" "greadlink" "exit 0"
    _write_stub "$stub_bin" "pre-commit" "exit 0"
    _write_stub "$stub_bin" "python3" "exit 0"
    _write_stub "$stub_bin" "docker" "exit 0"
    _write_stub "$stub_bin" "node" "echo \"$node_ver\"; exit 0"
    _write_stub "$stub_bin" "claude" "exit 0"
    # Proxy stubs: the script calls grep/head/dirname/tr for version parsing
    # and path detection; proxy to /usr/bin so they work under isolated PATH.
    _write_stub "$stub_bin" "grep"    '/usr/bin/grep "$@"'
    _write_stub "$stub_bin" "head"    '/usr/bin/head "$@"'
    _write_stub "$stub_bin" "dirname" '/usr/bin/dirname "$@"'
    _write_stub "$stub_bin" "tr"      '/usr/bin/tr "$@"'
    # Stubs for plugin-prerequisites added in e8c4-d3ed fix
    _write_stub "$stub_bin" "uv"      "exit 0"
    _write_stub "$stub_bin" "sg"      "exit 0"
    _write_stub "$stub_bin" "semgrep" "exit 0"

    echo "$stub_bin"
}

# ── test_homebrew_not_installed_exits_1 ──────────────────────────────────────
# When `brew` is not on PATH AND the installer cannot be fetched (no curl),
# check_homebrew_deps must exit non-zero with a manual-install hint.
test_homebrew_not_installed_exits_1() {
    local stub_bin
    stub_bin=$(_make_stub_bin)
    # Intentionally do NOT add brew to stub_bin.
    # Intentionally do NOT add curl — the script should detect curl missing
    # before attempting the installer and exit with a clear error.
    _write_stub "$stub_bin" "dirname" '/usr/bin/dirname "$@"'

    local output exit_code
    output=$(_run_script "$stub_bin" 2>&1) && exit_code=0 || exit_code=$?

    assert_ne "homebrew absent + no curl: exits non-zero" "0" "$exit_code"

    local msg_found="no"
    if grep -qi "homebrew" <<< "$output"; then
        msg_found="yes"
    fi
    assert_eq "homebrew absent + no curl: prints hint" "yes" "$msg_found"
}

# ── test_all_deps_present_exits_0 ────────────────────────────────────────────
# When all deps are present and node@20 is installed/listed, script must exit 0
# and print "All dependencies satisfied".
test_all_deps_present_exits_0() {
    local stub_bin
    stub_bin=$(_all_deps_stub_bin "v20.11.0")

    local output exit_code
    output=$(_run_script "$stub_bin" 2>&1) && exit_code=0 || exit_code=$?

    assert_eq "all deps present: exit 0" "0" "$exit_code"

    local satisfied="no"
    if grep -q "All dependencies satisfied" <<< "$output"; then
        satisfied="yes"
    fi
    assert_eq "all deps present: satisfied message" "yes" "$satisfied"
}

# ── test_missing_git_accumulates_to_error ───────────────────────────────────
# When git is absent AND `brew install git` fails, the script must exit 1 and
# list git in the missing deps output. The script now auto-installs via brew;
# only a brew install failure should still produce a fatal error.
test_missing_git_accumulates_to_error() {
    local stub_bin node_prefix
    stub_bin=$(_make_stub_bin)
    node_prefix=$(mktemp -d)
    TMPDIRS+=("$node_prefix")
    mkdir -p "$node_prefix/bin"

    # brew stub: `brew install git` fails (exit 1) — simulates install failure
    cat > "$stub_bin/brew" <<BREWEOF
#!/bin/sh
case "\$*" in
  "install git")      exit 1 ;;
  "install node@20")  : ;;
  "list node@20")     : ;;
  "--prefix node@20") echo "$node_prefix" ;;
  "install --cask "*)  : ;;
  *)                  : ;;
esac
exit 0
BREWEOF
    chmod +x "$stub_bin/brew"

    # Provide bash stub (needed for `bash --version` in the script)
    _write_stub "$stub_bin" "bash" "echo \"GNU bash, version 5.2.15(1)-release\"; exit 0"
    # Intentionally omit git so it is not found and brew auto-install fires
    _write_stub "$stub_bin" "greadlink" "exit 0"
    _write_stub "$stub_bin" "pre-commit" "exit 0"
    _write_stub "$stub_bin" "node" "echo \"v20.11.0\"; exit 0"
    _write_stub "$stub_bin" "claude" "exit 0"
    # Proxy stubs needed for bash --version parsing and path detection
    _write_stub "$stub_bin" "grep"    '/usr/bin/grep "$@"'
    _write_stub "$stub_bin" "head"    '/usr/bin/head "$@"'
    _write_stub "$stub_bin" "dirname" '/usr/bin/dirname "$@"'
    _write_stub "$stub_bin" "tr"      '/usr/bin/tr "$@"'

    # Use isolated PATH (stub_bin only) so /usr/bin/git is not reachable
    local output exit_code
    output=$(PATH="$stub_bin" /bin/bash "$SCRIPT_UNDER_TEST" 2>&1) && exit_code=0 || exit_code=$?

    assert_ne "missing git (brew install fails): exits non-zero" "0" "$exit_code"

    local git_listed="no"
    if grep -qi "git" <<< "$output"; then
        git_listed="yes"
    fi
    assert_eq "missing git (brew install fails): listed in output" "yes" "$git_listed"
}

# ── test_node_below_20_triggers_install ─────────────────────────────────────
# When installed node reports v18, the script must attempt `brew install node@20`.
test_node_below_20_triggers_install() {
    local install_marker
    install_marker=$(mktemp)

    local stub_bin node_prefix
    stub_bin=$(_make_stub_bin)
    node_prefix=$(mktemp -d)
    TMPDIRS+=("$node_prefix")
    mkdir -p "$node_prefix/bin"

    cat > "$stub_bin/brew" <<BREWEOF
#!/bin/sh
case "\$*" in
  "install node@20") touch "$install_marker"; exit 0 ;;
  "list node@20")    exit 0 ;;
  "--prefix node@20") echo "$node_prefix"; exit 0 ;;
  "install --cask "*)  exit 0 ;;
  *)                 exit 0 ;;
esac
BREWEOF
    chmod +x "$stub_bin/brew"

    _write_stub "$stub_bin" "bash" "echo \"GNU bash, version 5.2.15(1)-release\"; exit 0"
    _write_stub "$stub_bin" "git" "exit 0"
    _write_stub "$stub_bin" "greadlink" "exit 0"
    _write_stub "$stub_bin" "pre-commit" "exit 0"
    # node v18 — below required 20
    _write_stub "$stub_bin" "node" "echo \"v18.20.3\"; exit 0"
    _write_stub "$stub_bin" "claude" "exit 0"
    _write_stub "$stub_bin" "grep"    '/usr/bin/grep "$@"'
    _write_stub "$stub_bin" "head"    '/usr/bin/head "$@"'
    _write_stub "$stub_bin" "dirname" '/usr/bin/dirname "$@"'
    _write_stub "$stub_bin" "tr"      '/usr/bin/tr "$@"'

    _run_script "$stub_bin" >/dev/null 2>&1 || true

    local install_triggered="no"
    if [[ -f "$install_marker" ]]; then
        install_triggered="yes"
    fi
    assert_eq "node v18 triggers brew install node@20" "yes" "$install_triggered"
    rm -f "$install_marker"
}

# ── test_installer_writes_plugin_root_to_config ──────────────────────────────
# Verifies that detect_dso_plugin_root() writes the marketplace plugin path
# into dso-config.conf. RED: fails until detect_dso_plugin_root() is
# implemented in create-dso-app.sh (task 1d03-b29e). The test will fail with
# "detect_dso_plugin_root() not found or failed" until that task is complete.
test_installer_writes_plugin_root_to_config() {
    echo "=== test_installer_writes_plugin_root_to_config ==="

    local tmpdir
    tmpdir=$(mktemp -d)
    TMPDIRS+=("$tmpdir")

    local mock_marketplace="$tmpdir/mock-dso"
    local project_dir="$tmpdir/test-project"

    # Create mock marketplace sentinel at the real Claude Code layout:
    # <base>/digital-service-orchestra/plugins/dso/.claude-plugin/plugin.json
    mkdir -p "$mock_marketplace/digital-service-orchestra/plugins/dso/.claude-plugin" \
             "$mock_marketplace/digital-service-orchestra/plugins/dso/templates/host-project"
    echo '{"name":"dso"}' > "$mock_marketplace/digital-service-orchestra/plugins/dso/.claude-plugin/plugin.json"
    : > "$mock_marketplace/digital-service-orchestra/plugins/dso/templates/host-project/dso"

    # Create project with default dso.plugin_root
    mkdir -p "$project_dir/.claude"
    echo "dso.plugin_root=plugins/dso" > "$project_dir/.claude/dso-config.conf"

    # Invoke detect_dso_plugin_root (will fail if function doesn't exist yet — RED)
    local invoke_exit=0
    bash -c "
        MARKETPLACE_BASE='$mock_marketplace' \
        CLAUDE_PLUGIN_ROOT='' \
        source '$PLUGIN_ROOT/scripts/create-dso-app.sh'
        detect_dso_plugin_root '$project_dir'
    " 2>/dev/null || invoke_exit=$?

    # REVIEW-DEFENSE: early return only fires when invoke_exit != 0 (function missing/failed).
    # When invoke_exit == 0 (function exists and succeeded), we fall through to the
    # config assertion below — which correctly verifies the write side-effect.
    if [[ "$invoke_exit" -ne 0 ]]; then
        assert_eq "detect_dso_plugin_root() found and succeeded" "0" "$invoke_exit"
        return
    fi

    # Verify config was updated — only reached when invoke_exit == 0
    local actual_root
    actual_root=$(grep '^dso\.plugin_root=' "$project_dir/.claude/dso-config.conf" | cut -d= -f2-)
    local expected_root="$mock_marketplace/digital-service-orchestra/plugins/dso"

    assert_eq "dso.plugin_root written correctly" "$expected_root" "$actual_root"
}

# ── Run all tests ─────────────────────────────────────────────────────────────
test_homebrew_not_installed_exits_1
test_all_deps_present_exits_0
test_missing_git_accumulates_to_error
test_node_below_20_triggers_install
test_installer_writes_plugin_root_to_config

# ── _installer_stub_bin ───────────────────────────────────────────────────────
# Like _all_deps_stub_bin but replaces the git stub with one that creates a
# minimal project structure on `git clone` (needed for installer-phase tests).
_installer_stub_bin() {
    local node_ver="${1:-v20.11.0}"
    local stub_bin node_prefix
    stub_bin=$(_make_stub_bin)
    node_prefix=$(mktemp -d)
    TMPDIRS+=("$node_prefix")
    mkdir -p "$node_prefix/bin"

    cat > "$stub_bin/brew" <<BREWEOF
#!/bin/sh
case "\$*" in
  "--version"|"-v")         echo "Homebrew 4.0.0" ;;
  "install node@20")        : ;;
  "list node@20")           : ;;
  "--prefix node@20")       echo "$node_prefix" ;;
  "install --cask "*)       : ;;
  *)                        : ;;
esac
exit 0
BREWEOF
    chmod +x "$stub_bin/brew"

    # git stub: on clone, create minimal project structure in target dir
    cat > "$stub_bin/git" <<'GITSTUB'
#!/bin/sh
if [ "$1" = "clone" ]; then
    target=""
    for arg in "$@"; do
        case "$arg" in -*) ;; *) target="$arg" ;; esac
    done
    if [ -n "$target" ] && [ "$target" != "clone" ]; then
        # Mirror the real template structure: Next.js App Router under src/app/,
        # not a top-level app/ directory. See
        # docs/designs/create-dso-app-template-contract.md for the contract.
        mkdir -p "$target/src/app"
        printf '{"name":"{{PROJECT_NAME}}","scripts":{"dev":"next dev"},"dependencies":{"next":"^14.0.0"}}\n' \
            > "$target/package.json"
        touch "$target/src/app/page.tsx"
        mkdir -p "$target/.claude"
        touch "$target/CLAUDE.md"
    fi
    exit 0
fi
exit 0
GITSTUB
    chmod +x "$stub_bin/git"

    _write_stub "$stub_bin" "bash" "echo \"GNU bash, version 5.2.15(1)-release (x86_64)\"; exit 0"
    _write_stub "$stub_bin" "greadlink" "exit 0"
    _write_stub "$stub_bin" "pre-commit" "exit 0"
    _write_stub "$stub_bin" "python3" "exit 0"
    _write_stub "$stub_bin" "docker" "exit 0"
    _write_stub "$stub_bin" "npm" "exit 0"
    _write_stub "$stub_bin" "node" "echo \"$node_ver\"; exit 0"
    _write_stub "$stub_bin" "claude" "exit 0"
    _write_stub "$stub_bin" "grep"    '/usr/bin/grep "$@"'
    _write_stub "$stub_bin" "head"    '/usr/bin/head "$@"'
    _write_stub "$stub_bin" "dirname" '/usr/bin/dirname "$@"'
    _write_stub "$stub_bin" "tr"      '/usr/bin/tr "$@"'
    _write_stub "$stub_bin" "sed"     '/usr/bin/sed "$@"'
    _write_stub "$stub_bin" "find"    '/usr/bin/find "$@"'
    # mkdir and touch are used by the git clone stub; date is used for the sentinel timestamp
    _write_stub "$stub_bin" "mkdir"   '/bin/mkdir "$@"'
    _write_stub "$stub_bin" "touch"   '/usr/bin/touch "$@"'
    _write_stub "$stub_bin" "date"    '/bin/date "$@"'
    # rm is used by the partial-init start-fresh path and cleanup trap
    _write_stub "$stub_bin" "rm"      '/bin/rm "$@"'
    # Stubs for plugin-prerequisites added in e8c4-d3ed fix
    _write_stub "$stub_bin" "uv"      "exit 0"
    _write_stub "$stub_bin" "sg"      "exit 0"
    _write_stub "$stub_bin" "semgrep" "exit 0"
    # cp and chmod used by shim fallback install in Step 5c.5 (bug 14f9-060b fix)
    _write_stub "$stub_bin" "cp"      '/bin/cp "$@"'
    _write_stub "$stub_bin" "chmod"   '/bin/chmod "$@"'

    echo "$stub_bin"
}

# ── test_project_structure_created ───────────────────────────────────────────
# After a successful installer run, assert that package.json, app/ or pages/
# dir, and at least one DSO infrastructure file are present.
# RED: fails until clone+scaffold logic is implemented in create-dso-app.sh.
test_project_structure_created() {
    local stub_bin T project_dir
    stub_bin=$(_installer_stub_bin)
    T=$(mktemp -d)
    TMPDIRS+=("$T")
    project_dir="$T/my-project"

    PATH="$stub_bin" /bin/bash "$SCRIPT_UNDER_TEST" "my-project" "$T" <<< $'\n' >/dev/null 2>&1 || true

    local pkg_ok="no"
    [[ -f "$project_dir/package.json" ]] && pkg_ok="yes"
    assert_eq "project structure: package.json present" "yes" "$pkg_ok"

    # Accept all valid Next.js app entry-point layouts. The real DSO NextJS
    # template uses src/app/ (App Router with src/ convention). app/ and pages/
    # are accepted for templates that diverge from the src/ convention. See
    # docs/designs/create-dso-app-template-contract.md.
    local app_ok="no"
    { [[ -d "$project_dir/src/app" ]] || [[ -d "$project_dir/app" ]] || [[ -d "$project_dir/pages" ]]; } && app_ok="yes"
    assert_eq "project structure: src/app/, app/, or pages/ present" "yes" "$app_ok"

    local infra_ok="no"
    { [[ -d "$project_dir/.claude" ]] || [[ -f "$project_dir/CLAUDE.md" ]]; } && infra_ok="yes"
    assert_eq "project structure: DSO infra file present" "yes" "$infra_ok"
}

# ── test_project_name_substitution ───────────────────────────────────────────
# Run installer with a project name containing special chars. Assert either
# (a) sanitized name used, or (b) exits non-zero with actionable error.
# RED: fails until substitution/sanitization logic is implemented.
test_project_name_substitution() {
    local stub_bin T output exit_code=0
    stub_bin=$(_installer_stub_bin)
    T=$(mktemp -d)
    TMPDIRS+=("$T")

    output=$(PATH="$stub_bin" /bin/bash "$SCRIPT_UNDER_TEST" 'my project $var *glob' "$T" <<< $'\n' 2>&1) || exit_code=$?

    local handled="no"
    if [[ "$exit_code" -ne 0 ]]; then
        # Rejected with error — check message is actionable
        grep -qiE 'sanitize|invalid|character|name' <<< "$output" && handled="yes"
    else
        # Sanitized — the project dir should NOT exist at the unsanitized path
        [[ ! -d "$T/my project \$var *glob" ]] && handled="yes"
    fi
    assert_eq "project name: special chars handled" "yes" "$handled"
}

# ── test_dso_init_complete_sentinel_created ───────────────────────────────────
# After successful installer run, assert .dso-init-complete is present.
# RED: fails until sentinel-write logic is implemented.
test_dso_init_complete_sentinel_created() {
    local stub_bin T project_dir
    stub_bin=$(_installer_stub_bin)
    T=$(mktemp -d)
    TMPDIRS+=("$T")
    project_dir="$T/my-project"

    PATH="$stub_bin" /bin/bash "$SCRIPT_UNDER_TEST" "my-project" "$T" <<< $'\n' >/dev/null 2>&1 || true

    local sentinel="no"
    [[ -f "$project_dir/.dso-init-complete" ]] && sentinel="yes"
    assert_eq "sentinel .dso-init-complete created" "yes" "$sentinel"
}

# ── test_exit_0_on_newline_ack ────────────────────────────────────────────────
# Pipe a newline to stdin and assert exit 0 (user acknowledged prompt).
# RED: fails until stdin acknowledgment is implemented.
test_exit_0_on_newline_ack() {
    local stub_bin T exit_code=0
    stub_bin=$(_installer_stub_bin)
    T=$(mktemp -d)
    TMPDIRS+=("$T")

    PATH="$stub_bin" /bin/bash "$SCRIPT_UNDER_TEST" "my-project" "$T" <<< $'\n' >/dev/null 2>&1 || exit_code=$?
    assert_eq "newline ack: exit 0" "0" "$exit_code"
}

# ── test_exit_1_on_stdin_eof ──────────────────────────────────────────────────
# Pipe /dev/null to stdin (EOF) at the acknowledgment prompt and assert exit 1
# plus message "Installation cancelled."
# RED: fails until stdin EOF handling is implemented.
test_exit_1_on_stdin_eof() {
    local stub_bin T exit_code=0 output
    stub_bin=$(_installer_stub_bin)
    T=$(mktemp -d)
    TMPDIRS+=("$T")

    output=$(PATH="$stub_bin" /bin/bash "$SCRIPT_UNDER_TEST" "my-project" "$T" </dev/null 2>&1) || exit_code=$?
    assert_ne "stdin EOF: exits non-zero" "0" "$exit_code"

    local cancelled="no"
    grep -q "Installation cancelled" <<< "$output" && cancelled="yes"
    assert_eq "stdin EOF: 'Installation cancelled' message" "yes" "$cancelled"
}

# ── test_idempotency_already_initialized ─────────────────────────────────────
# Pre-create .dso-init-complete in the target dir; assert exit 0 plus
# informative message when the installer is re-run.
# RED: fails until idempotency check is implemented.
test_idempotency_already_initialized() {
    local stub_bin T project_dir exit_code=0 output
    stub_bin=$(_installer_stub_bin)
    T=$(mktemp -d)
    TMPDIRS+=("$T")
    project_dir="$T/my-project"
    mkdir -p "$project_dir"
    touch "$project_dir/.dso-init-complete"

    output=$(PATH="$stub_bin" /bin/bash "$SCRIPT_UNDER_TEST" "my-project" "$T" <<< $'\n' 2>&1) || exit_code=$?
    assert_eq "idempotency: exit 0" "0" "$exit_code"

    local msg_ok="no"
    grep -qiE 'already|initialized|complete|exists' <<< "$output" && msg_ok="yes"
    assert_eq "idempotency: informative message" "yes" "$msg_ok"
}

# ── test_partial_init_start_fresh ────────────────────────────────────────────
# Pre-create project dir WITHOUT .dso-init-complete (partial install).
# Respond 'y' to start-fresh prompt; assert exit 0 and sentinel created.
test_partial_init_start_fresh() {
    local stub_bin T project_dir exit_code=0
    stub_bin=$(_installer_stub_bin)
    T=$(mktemp -d)
    TMPDIRS+=("$T")
    project_dir="$T/my-project"
    mkdir -p "$project_dir"
    # No .dso-init-complete — simulates a partial/interrupted install

    PATH="$stub_bin" /bin/bash "$SCRIPT_UNDER_TEST" "my-project" "$T" <<< $'s\n' >/dev/null 2>&1 || exit_code=$?
    assert_eq "partial init start-fresh: exit 0" "0" "$exit_code"

    local sentinel="no"
    [[ -f "$project_dir/.dso-init-complete" ]] && sentinel="yes"
    assert_eq "partial init start-fresh: sentinel created" "yes" "$sentinel"
}

# ── test_partial_init_cancel ──────────────────────────────────────────────────
# Pre-create project dir WITHOUT .dso-init-complete (partial install).
# Respond 'n' to start-fresh prompt; assert exit non-zero.
test_partial_init_cancel() {
    local stub_bin T project_dir exit_code=0
    stub_bin=$(_installer_stub_bin)
    T=$(mktemp -d)
    TMPDIRS+=("$T")
    project_dir="$T/my-project"
    mkdir -p "$project_dir"

    PATH="$stub_bin" /bin/bash "$SCRIPT_UNDER_TEST" "my-project" "$T" <<< $'n\n' >/dev/null 2>&1 || exit_code=$?
    assert_ne "partial init cancel: exits non-zero" "0" "$exit_code"
}

# ── test_partial_init_resume ─────────────────────────────────────────────────
# Pre-create project dir with content simulating a partial clone (no sentinel).
# Respond 'r' to the resume/start-fresh/cancel prompt; assert exit 0 and
# sentinel created (resume skips clone, runs remaining steps).
test_partial_init_resume() {
    local stub_bin T project_dir exit_code=0
    stub_bin=$(_installer_stub_bin)
    T=$(mktemp -d)
    TMPDIRS+=("$T")
    project_dir="$T/my-project"
    # Pre-create partial project dir with cloned content (simulates interrupted
    # install after clone but before npm/sentinel steps)
    mkdir -p "$project_dir/app"
    printf '{"name":"template","scripts":{"dev":"next dev"},"dependencies":{"next":"^14.0.0"}}\n' \
        > "$project_dir/package.json"
    touch "$project_dir/app/page.tsx"
    mkdir -p "$project_dir/.claude"

    PATH="$stub_bin" /bin/bash "$SCRIPT_UNDER_TEST" "my-project" "$T" <<< $'r\n' >/dev/null 2>&1 || exit_code=$?
    assert_eq "partial init resume: exit 0" "0" "$exit_code"

    local sentinel="no"
    [[ -f "$project_dir/.dso-init-complete" ]] && sentinel="yes"
    assert_eq "partial init resume: sentinel created" "yes" "$sentinel"
}

test_project_structure_created
test_project_name_substitution
test_dso_init_complete_sentinel_created
test_exit_0_on_newline_ack
test_exit_1_on_stdin_eof
test_idempotency_already_initialized
test_partial_init_start_fresh
test_partial_init_cancel
test_partial_init_resume

# ── test_missing_git_auto_installs_via_brew ───────────────────────────────────
# When git is absent from PATH but brew is present and functional, the script
# must call `brew install git` automatically (auto-install) and exit 0 with
# "All dependencies satisfied" — NOT exit 1 with "Run: brew install git".
#
# RED: fails until check_homebrew_deps() is fixed to call `brew install git`
# instead of adding git to missing[] and exiting 1.
test_missing_git_auto_installs_via_brew() {
    local install_marker
    install_marker=$(mktemp)
    rm -f "$install_marker"  # start absent; brew stub creates it on install git

    local stub_bin node_prefix
    stub_bin=$(_make_stub_bin)
    node_prefix=$(mktemp -d)
    TMPDIRS+=("$node_prefix")
    mkdir -p "$node_prefix/bin"

    cat > "$stub_bin/brew" <<BREWEOF
#!/bin/sh
case "\$*" in
  "install git")        /usr/bin/touch "$install_marker"; exit 0 ;;
  "install node@20")    exit 0 ;;
  "list node@20")       exit 0 ;;
  "--prefix node@20")   echo "$node_prefix"; exit 0 ;;
  "install --cask "*)   exit 0 ;;
  "--version"|"-v")     echo "Homebrew 4.0.0"; exit 0 ;;
  *)                    exit 0 ;;
esac
BREWEOF
    chmod +x "$stub_bin/brew"

    # Provide all deps EXCEPT git — git is intentionally absent so brew auto-install fires
    _write_stub "$stub_bin" "bash"       "echo \"GNU bash, version 5.2.15(1)-release\"; exit 0"
    _write_stub "$stub_bin" "greadlink"  "exit 0"
    _write_stub "$stub_bin" "pre-commit" "exit 0"
    _write_stub "$stub_bin" "node"       "echo \"v20.11.0\"; exit 0"
    _write_stub "$stub_bin" "claude"     "exit 0"
    _write_stub "$stub_bin" "grep"       '/usr/bin/grep "$@"'
    _write_stub "$stub_bin" "head"       '/usr/bin/head "$@"'
    _write_stub "$stub_bin" "dirname"    '/usr/bin/dirname "$@"'
    _write_stub "$stub_bin" "tr"         '/usr/bin/tr "$@"'

    # Run with strictly isolated PATH — /usr/bin/git must NOT be reachable
    local output exit_code=0
    output=$(PATH="$stub_bin" /bin/bash "$SCRIPT_UNDER_TEST" 2>&1) || exit_code=$?

    # Assert: brew install git was called (auto-install triggered)
    local install_triggered="no"
    [[ -f "$install_marker" ]] && install_triggered="yes"
    assert_eq "missing git: brew install git called automatically" "yes" "$install_triggered"

    # Assert: script exits 0 (auto-install succeeds, not a fatal missing dep)
    assert_eq "missing git: exits 0 after auto-install" "0" "$exit_code"

    # Assert: no "Run: brew install" manual instruction in output
    local manual_hint="no"
    grep -qi "Run: brew install git" <<< "$output" && manual_hint="yes"
    assert_eq "missing git: no manual install hint in output" "no" "$manual_hint"

    rm -f "$install_marker"
}

# ── test_brew_shellenv_path_injection_prevents_false_missing ──────────────────
# When a dep (greadlink/coreutils) is installed by Homebrew but its bin dir is
# NOT on the initial PATH, the script must inject the Homebrew PATH via
# `brew shellenv` (or equivalent) before checking for deps, and then find the
# dep — rather than treating it as missing and exiting 1.
#
# Simulation: brew shellenv outputs "export PATH=<homebrew_bin>:$PATH".
# The homebrew_bin dir contains greadlink. The initial PATH does NOT contain it.
#
# RED: fails until check_homebrew_deps() calls `eval "$(brew shellenv)"` before
# running any `command -v` checks.
test_brew_shellenv_path_injection_prevents_false_missing() {
    local stub_bin homebrew_bin node_prefix
    stub_bin=$(_make_stub_bin)
    homebrew_bin=$(_make_stub_bin)  # simulates /opt/homebrew/bin — not on initial PATH
    node_prefix=$(mktemp -d)
    TMPDIRS+=("$node_prefix")
    mkdir -p "$node_prefix/bin"

    # greadlink lives ONLY in homebrew_bin (not in stub_bin)
    _write_stub "$homebrew_bin" "greadlink" "exit 0"

    cat > "$stub_bin/brew" <<BREWEOF
#!/bin/sh
case "\$*" in
  "shellenv")           echo "export PATH=\"$homebrew_bin:\$PATH\""; exit 0 ;;
  "install node@20")    exit 0 ;;
  "list node@20")       exit 0 ;;
  "--prefix node@20")   echo "$node_prefix"; exit 0 ;;
  "install --cask "*)   exit 0 ;;
  "--version"|"-v")     echo "Homebrew 4.0.0"; exit 0 ;;
  *)                    exit 0 ;;
esac
BREWEOF
    chmod +x "$stub_bin/brew"

    # All other deps present in stub_bin; greadlink intentionally absent from stub_bin
    _write_stub "$stub_bin" "bash"       "echo \"GNU bash, version 5.2.15(1)-release\"; exit 0"
    _write_stub "$stub_bin" "git"        "exit 0"
    _write_stub "$stub_bin" "pre-commit" "exit 0"
    _write_stub "$stub_bin" "node"       "echo \"v20.11.0\"; exit 0"
    _write_stub "$stub_bin" "claude"     "exit 0"
    _write_stub "$stub_bin" "grep"       '/usr/bin/grep "$@"'
    _write_stub "$stub_bin" "head"       '/usr/bin/head "$@"'
    _write_stub "$stub_bin" "dirname"    '/usr/bin/dirname "$@"'
    _write_stub "$stub_bin" "tr"         '/usr/bin/tr "$@"'

    # Run with initial PATH = stub_bin only (homebrew_bin reachable ONLY via brew shellenv)
    local output exit_code=0
    output=$(PATH="$stub_bin" /bin/bash "$SCRIPT_UNDER_TEST" 2>&1) || exit_code=$?

    # Assert: script exits 0 — greadlink found after shellenv injection, not treated as missing
    assert_eq "shellenv injection: exits 0 when dep is in homebrew PATH" "0" "$exit_code"

    # Assert: output contains "All dependencies satisfied" (not a missing-dep error)
    local satisfied="no"
    grep -q "All dependencies satisfied" <<< "$output" && satisfied="yes"
    assert_eq "shellenv injection: all deps satisfied message" "yes" "$satisfied"

    # Assert: no "coreutils" listed as missing in error output
    local coreutils_missing="no"
    grep -qi "coreutils" <<< "$output" && coreutils_missing="yes"
    assert_eq "shellenv injection: coreutils NOT listed as missing" "no" "$coreutils_missing"
}

test_missing_git_auto_installs_via_brew
test_brew_shellenv_path_injection_prevents_false_missing

# ── test_missing_python3_brew_failure_reports_missing ────────────────────────
# When python3 is absent from PATH AND `brew install python3` fails (exit 1),
# the script must exit non-zero and include "python3" in the error output.
#
# RED: fails before fix because check_homebrew_deps() has no python3 check at
# all — python3 absence is silently ignored, brew install python3 is never
# called, and the script exits 0 with "All dependencies satisfied".
#
# GREEN: after fix, the script detects missing python3, calls
# `brew install python3`, gets exit 1, accumulates python3 in missing[], and
# exits non-zero with "python3" in the error output.
test_missing_python3_brew_failure_reports_missing() {
    local stub_bin node_prefix
    stub_bin=$(_make_stub_bin)
    node_prefix=$(mktemp -d)
    TMPDIRS+=("$node_prefix")
    mkdir -p "$node_prefix/bin"

    # brew stub: `brew install python3` fails (exit 1) — simulates install failure
    cat > "$stub_bin/brew" <<BREWEOF
#!/bin/sh
case "\$*" in
  "install python3")    exit 1 ;;
  "install node@20")    exit 0 ;;
  "list node@20")       exit 0 ;;
  "--prefix node@20")   echo "$node_prefix"; exit 0 ;;
  "install --cask "*)   exit 0 ;;
  "--version"|"-v")     echo "Homebrew 4.0.0"; exit 0 ;;
  *)                    exit 0 ;;
esac
BREWEOF
    chmod +x "$stub_bin/brew"

    # Provide all deps EXCEPT python3 — python3 intentionally absent so brew
    # auto-install fires and fails, triggering the missing[] accumulation path
    _write_stub "$stub_bin" "bash"       "echo \"GNU bash, version 5.2.15(1)-release\"; exit 0"
    _write_stub "$stub_bin" "git"        "exit 0"
    _write_stub "$stub_bin" "greadlink"  "exit 0"
    _write_stub "$stub_bin" "pre-commit" "exit 0"
    _write_stub "$stub_bin" "node"       "echo \"v20.11.0\"; exit 0"
    _write_stub "$stub_bin" "claude"     "exit 0"
    # Proxy stubs for commands used in bash --version parsing and path detection
    _write_stub "$stub_bin" "grep"       '/usr/bin/grep "$@"'
    _write_stub "$stub_bin" "head"       '/usr/bin/head "$@"'
    _write_stub "$stub_bin" "dirname"    '/usr/bin/dirname "$@"'
    _write_stub "$stub_bin" "tr"         '/usr/bin/tr "$@"'

    # Run with strictly isolated PATH — /usr/bin/python3 must NOT be reachable
    local output exit_code=0
    output=$(PATH="$stub_bin" /bin/bash "$SCRIPT_UNDER_TEST" 2>&1) || exit_code=$?

    assert_ne "missing python3 (brew install fails): exits non-zero" "0" "$exit_code"

    local python3_listed="no"
    if grep -qi "python3" <<< "$output"; then
        python3_listed="yes"
    fi
    assert_eq "missing python3 (brew install fails): listed in output" "yes" "$python3_listed"
}

test_missing_python3_brew_failure_reports_missing

# ── test_missing_docker_colima_brew_failure_reports_missing ──────────────────
# When neither docker NOR colima is on PATH AND `brew install colima` fails
# (exit 1), the script must exit non-zero and include "colima" in the error
# output.
#
# RED: fails before fix because check_homebrew_deps() has no container runtime
# check at all — docker/colima absence is silently ignored, brew install colima
# is never called, and the script exits 0 with "All dependencies satisfied"
# even though no container runtime is present.
#
# GREEN: after fix, the script detects neither docker nor colima is present,
# calls `brew install colima`, gets exit 1, accumulates colima in missing[],
# and exits non-zero with "colima" in the error output.
test_missing_docker_colima_brew_failure_reports_missing() {
    local stub_bin node_prefix
    stub_bin=$(_make_stub_bin)
    node_prefix=$(mktemp -d)
    TMPDIRS+=("$node_prefix")
    mkdir -p "$node_prefix/bin"

    # brew stub: `brew install colima` fails (exit 1) — simulates install
    # failure; all other brew invocations succeed so they don't interfere
    cat > "$stub_bin/brew" <<BREWEOF
#!/bin/sh
case "\$*" in
  "install colima")    exit 1 ;;
  "install node@20")   exit 0 ;;
  "list node@20")      exit 0 ;;
  "--prefix node@20")  echo "$node_prefix"; exit 0 ;;
  "install --cask "*) exit 0 ;;
  "--version"|"-v")   echo "Homebrew 4.0.0"; exit 0 ;;
  *)                  exit 0 ;;
esac
BREWEOF
    chmod +x "$stub_bin/brew"

    # Provide all deps EXCEPT docker and colima — both are intentionally absent
    # so the container runtime detection block fires and brew auto-install runs
    _write_stub "$stub_bin" "bash"       "echo \"GNU bash, version 5.2.15(1)-release\"; exit 0"
    _write_stub "$stub_bin" "git"        "exit 0"
    _write_stub "$stub_bin" "greadlink"  "exit 0"
    _write_stub "$stub_bin" "pre-commit" "exit 0"
    _write_stub "$stub_bin" "python3"    "exit 0"
    _write_stub "$stub_bin" "node"       "echo \"v20.11.0\"; exit 0"
    _write_stub "$stub_bin" "claude"     "exit 0"
    # Proxy stubs for commands used in bash --version parsing and path detection
    _write_stub "$stub_bin" "grep"       '/usr/bin/grep "$@"'
    _write_stub "$stub_bin" "head"       '/usr/bin/head "$@"'
    _write_stub "$stub_bin" "dirname"    '/usr/bin/dirname "$@"'
    _write_stub "$stub_bin" "tr"         '/usr/bin/tr "$@"'
    # NOTE: docker and colima are deliberately NOT added to stub_bin

    # Run with strictly isolated PATH — system docker/colima must NOT be reachable
    local output exit_code=0
    output=$(PATH="$stub_bin" /bin/bash "$SCRIPT_UNDER_TEST" 2>&1) || exit_code=$?

    assert_ne "missing docker+colima (brew install fails): exits non-zero" "0" "$exit_code"

    local colima_listed="no"
    if grep -qi "colima" <<< "$output"; then
        colima_listed="yes"
    fi
    assert_eq "missing docker+colima (brew install fails): colima listed in output" "yes" "$colima_listed"
}

test_missing_docker_colima_brew_failure_reports_missing

# ── test_colima_start_failure_emits_warning ───────────────────────────────────
# When colima is installed but `colima start` fails (exit 1), the script must
# NOT exit non-zero (start failures are non-fatal) but MUST emit a WARNING to
# stderr indicating manual intervention may be needed.
test_colima_start_failure_emits_warning() {
    local stub_bin node_prefix
    stub_bin=$(_make_stub_bin)
    node_prefix=$(mktemp -d)
    TMPDIRS+=("$node_prefix")
    mkdir -p "$node_prefix/bin"

    # colima stub: installed (command -v succeeds) but start fails, status shows not-Running
    cat > "$stub_bin/colima" <<'COLIMAEOF'
#!/bin/sh
case "$1" in
  status) echo "colima is stopped"; exit 0 ;;
  start)  exit 1 ;;
  *)      exit 0 ;;
esac
COLIMAEOF
    chmod +x "$stub_bin/colima"

    # brew stub: all installs succeed; --prefix returns node prefix
    cat > "$stub_bin/brew" <<BREWEOF
#!/bin/sh
case "\$*" in
  "install node@20")   exit 0 ;;
  "list node@20")      exit 0 ;;
  "--prefix node@20")  echo "$node_prefix"; exit 0 ;;
  "install --cask "*) exit 0 ;;
  "--version"|"-v")   echo "Homebrew 4.0.0"; exit 0 ;;
  *)                  exit 0 ;;
esac
BREWEOF
    chmod +x "$stub_bin/brew"

    # All deps present including colima; docker intentionally absent so start block fires
    _write_stub "$stub_bin" "bash"       "echo \"GNU bash, version 5.2.15(1)-release\"; exit 0"
    _write_stub "$stub_bin" "git"        "exit 0"
    _write_stub "$stub_bin" "greadlink"  "exit 0"
    _write_stub "$stub_bin" "pre-commit" "exit 0"
    _write_stub "$stub_bin" "python3"    "exit 0"
    _write_stub "$stub_bin" "node"       "echo \"v20.11.0\"; exit 0"
    _write_stub "$stub_bin" "claude"     "exit 0"
    _write_stub "$stub_bin" "grep"       '/usr/bin/grep "$@"'
    _write_stub "$stub_bin" "head"       '/usr/bin/head "$@"'
    _write_stub "$stub_bin" "dirname"    '/usr/bin/dirname "$@"'
    _write_stub "$stub_bin" "tr"         '/usr/bin/tr "$@"'
    # docker intentionally NOT added — triggers colima path

    local output exit_code=0
    output=$(PATH="$stub_bin" /bin/bash "$SCRIPT_UNDER_TEST" 2>&1) || exit_code=$?

    assert_eq "colima start failure: script exits 0 (start is non-fatal)" "0" "$exit_code"

    local warning_present="no"
    if grep -qi "WARNING" <<< "$output"; then
        warning_present="yes"
    fi
    assert_eq "colima start failure: WARNING emitted in output" "yes" "$warning_present"
}

test_colima_start_failure_emits_warning

# ── test_missing_uv_brew_failure_reports_missing ─────────────────────────────
# When uv is absent from PATH AND `brew install uv` fails (exit 1), the script
# must exit non-zero and include "uv" in the error output.
#
# RED: fails before fix because check_homebrew_deps() has no uv check at all —
# uv absence is silently ignored, brew install uv is never called, and the
# script exits 0 with "All dependencies satisfied".
#
# GREEN: after fix, the script detects missing uv, calls `brew install uv`,
# gets exit 1, accumulates uv in missing[], and exits non-zero with "uv" in
# the error output.
test_missing_uv_brew_failure_reports_missing() {
    local stub_bin node_prefix
    stub_bin=$(_make_stub_bin)
    node_prefix=$(mktemp -d)
    TMPDIRS+=("$node_prefix")
    mkdir -p "$node_prefix/bin"

    # brew stub: `brew install uv` fails (exit 1) — simulates install failure;
    # all other brew invocations succeed so they don't interfere
    cat > "$stub_bin/brew" <<BREWEOF
#!/bin/sh
case "\$*" in
  "install uv")          exit 1 ;;
  "install node@20")     exit 0 ;;
  "list node@20")        exit 0 ;;
  "--prefix node@20")    echo "$node_prefix"; exit 0 ;;
  "install --cask "*)    exit 0 ;;
  "--version"|"-v")      echo "Homebrew 4.0.0"; exit 0 ;;
  *)                     exit 0 ;;
esac
BREWEOF
    chmod +x "$stub_bin/brew"

    # Provide all deps EXCEPT uv — uv intentionally absent so brew auto-install
    # fires and fails, triggering the missing[] accumulation path
    _write_stub "$stub_bin" "bash"       "echo \"GNU bash, version 5.2.15(1)-release\"; exit 0"
    _write_stub "$stub_bin" "git"        "exit 0"
    _write_stub "$stub_bin" "greadlink"  "exit 0"
    _write_stub "$stub_bin" "pre-commit" "exit 0"
    _write_stub "$stub_bin" "python3"    "exit 0"
    _write_stub "$stub_bin" "docker"     "exit 0"
    _write_stub "$stub_bin" "node"       "echo \"v20.11.0\"; exit 0"
    _write_stub "$stub_bin" "claude"     "exit 0"
    _write_stub "$stub_bin" "sg"         "exit 0"
    _write_stub "$stub_bin" "semgrep"    "exit 0"
    # Proxy stubs for commands used in bash --version parsing and path detection
    _write_stub "$stub_bin" "grep"       '/usr/bin/grep "$@"'
    _write_stub "$stub_bin" "head"       '/usr/bin/head "$@"'
    _write_stub "$stub_bin" "dirname"    '/usr/bin/dirname "$@"'
    _write_stub "$stub_bin" "tr"         '/usr/bin/tr "$@"'
    # NOTE: uv is deliberately NOT added to stub_bin

    # Run with strictly isolated PATH — system uv must NOT be reachable
    local output exit_code=0
    output=$(PATH="$stub_bin" /bin/bash "$SCRIPT_UNDER_TEST" 2>&1) || exit_code=$?

    assert_ne "missing uv (brew install fails): exits non-zero" "0" "$exit_code"

    local uv_listed="no"
    if grep -qi "uv" <<< "$output"; then
        uv_listed="yes"
    fi
    assert_eq "missing uv (brew install fails): listed in output" "yes" "$uv_listed"
}

# ── test_missing_astgrep_brew_failure_reports_missing ────────────────────────
# When ast-grep (CLI binary: sg) is absent from PATH AND `brew install ast-grep`
# fails (exit 1), the script must exit non-zero and include "ast-grep" in the
# error output.
#
# RED: fails before fix because check_homebrew_deps() has no ast-grep check at
# all — sg absence is silently ignored, brew install ast-grep is never called,
# and the script exits 0 with "All dependencies satisfied".
#
# GREEN: after fix, the script detects missing sg (ast-grep), calls
# `brew install ast-grep`, gets exit 1, accumulates ast-grep in missing[], and
# exits non-zero with "ast-grep" in the error output.
test_missing_astgrep_brew_failure_reports_missing() {
    local stub_bin node_prefix
    stub_bin=$(_make_stub_bin)
    node_prefix=$(mktemp -d)
    TMPDIRS+=("$node_prefix")
    mkdir -p "$node_prefix/bin"

    # brew stub: `brew install ast-grep` fails (exit 1) — simulates install
    # failure; all other brew invocations succeed so they don't interfere
    cat > "$stub_bin/brew" <<BREWEOF
#!/bin/sh
case "\$*" in
  "install ast-grep")    exit 1 ;;
  "install node@20")     exit 0 ;;
  "list node@20")        exit 0 ;;
  "--prefix node@20")    echo "$node_prefix"; exit 0 ;;
  "install --cask "*)    exit 0 ;;
  "--version"|"-v")      echo "Homebrew 4.0.0"; exit 0 ;;
  *)                     exit 0 ;;
esac
BREWEOF
    chmod +x "$stub_bin/brew"

    # Provide all deps EXCEPT sg (the ast-grep CLI binary) — sg intentionally
    # absent so `command -v sg` fails and brew auto-install fires and fails
    _write_stub "$stub_bin" "bash"       "echo \"GNU bash, version 5.2.15(1)-release\"; exit 0"
    _write_stub "$stub_bin" "git"        "exit 0"
    _write_stub "$stub_bin" "greadlink"  "exit 0"
    _write_stub "$stub_bin" "pre-commit" "exit 0"
    _write_stub "$stub_bin" "python3"    "exit 0"
    _write_stub "$stub_bin" "docker"     "exit 0"
    _write_stub "$stub_bin" "node"       "echo \"v20.11.0\"; exit 0"
    _write_stub "$stub_bin" "claude"     "exit 0"
    _write_stub "$stub_bin" "uv"         "exit 0"
    _write_stub "$stub_bin" "semgrep"    "exit 0"
    # Proxy stubs for commands used in bash --version parsing and path detection
    _write_stub "$stub_bin" "grep"       '/usr/bin/grep "$@"'
    _write_stub "$stub_bin" "head"       '/usr/bin/head "$@"'
    _write_stub "$stub_bin" "dirname"    '/usr/bin/dirname "$@"'
    _write_stub "$stub_bin" "tr"         '/usr/bin/tr "$@"'
    # NOTE: sg (ast-grep binary) is deliberately NOT added to stub_bin

    # Run with strictly isolated PATH — system sg must NOT be reachable
    local output exit_code=0
    output=$(PATH="$stub_bin" /bin/bash "$SCRIPT_UNDER_TEST" 2>&1) || exit_code=$?

    assert_ne "missing ast-grep/sg (brew install fails): exits non-zero" "0" "$exit_code"

    local astgrep_listed="no"
    if grep -qi "ast-grep" <<< "$output"; then
        astgrep_listed="yes"
    fi
    assert_eq "missing ast-grep/sg (brew install fails): listed in output" "yes" "$astgrep_listed"
}

# ── test_missing_semgrep_brew_failure_reports_missing ────────────────────────
# When semgrep is absent from PATH AND `brew install semgrep` fails (exit 1),
# the script must exit non-zero and include "semgrep" in the error output.
#
# RED: fails before fix because check_homebrew_deps() has no semgrep check at
# all — semgrep absence is silently ignored, brew install semgrep is never
# called, and the script exits 0 with "All dependencies satisfied".
#
# GREEN: after fix, the script detects missing semgrep, calls
# `brew install semgrep`, gets exit 1, accumulates semgrep in missing[], and
# exits non-zero with "semgrep" in the error output.
test_missing_semgrep_brew_failure_reports_missing() {
    local stub_bin node_prefix
    stub_bin=$(_make_stub_bin)
    node_prefix=$(mktemp -d)
    TMPDIRS+=("$node_prefix")
    mkdir -p "$node_prefix/bin"

    # brew stub: `brew install semgrep` fails (exit 1) — simulates install
    # failure; all other brew invocations succeed so they don't interfere
    cat > "$stub_bin/brew" <<BREWEOF
#!/bin/sh
case "\$*" in
  "install semgrep")     exit 1 ;;
  "install node@20")     exit 0 ;;
  "list node@20")        exit 0 ;;
  "--prefix node@20")    echo "$node_prefix"; exit 0 ;;
  "install --cask "*)    exit 0 ;;
  "--version"|"-v")      echo "Homebrew 4.0.0"; exit 0 ;;
  *)                     exit 0 ;;
esac
BREWEOF
    chmod +x "$stub_bin/brew"

    # Provide all deps EXCEPT semgrep — semgrep intentionally absent so brew
    # auto-install fires and fails, triggering the missing[] accumulation path
    _write_stub "$stub_bin" "bash"       "echo \"GNU bash, version 5.2.15(1)-release\"; exit 0"
    _write_stub "$stub_bin" "git"        "exit 0"
    _write_stub "$stub_bin" "greadlink"  "exit 0"
    _write_stub "$stub_bin" "pre-commit" "exit 0"
    _write_stub "$stub_bin" "python3"    "exit 0"
    _write_stub "$stub_bin" "docker"     "exit 0"
    _write_stub "$stub_bin" "node"       "echo \"v20.11.0\"; exit 0"
    _write_stub "$stub_bin" "claude"     "exit 0"
    _write_stub "$stub_bin" "uv"         "exit 0"
    _write_stub "$stub_bin" "sg"         "exit 0"
    # Proxy stubs for commands used in bash --version parsing and path detection
    _write_stub "$stub_bin" "grep"       '/usr/bin/grep "$@"'
    _write_stub "$stub_bin" "head"       '/usr/bin/head "$@"'
    _write_stub "$stub_bin" "dirname"    '/usr/bin/dirname "$@"'
    _write_stub "$stub_bin" "tr"         '/usr/bin/tr "$@"'
    # NOTE: semgrep is deliberately NOT added to stub_bin

    # Run with strictly isolated PATH — system semgrep must NOT be reachable
    local output exit_code=0
    output=$(PATH="$stub_bin" /bin/bash "$SCRIPT_UNDER_TEST" 2>&1) || exit_code=$?

    assert_ne "missing semgrep (brew install fails): exits non-zero" "0" "$exit_code"

    local semgrep_listed="no"
    if grep -qi "semgrep" <<< "$output"; then
        semgrep_listed="yes"
    fi
    assert_eq "missing semgrep (brew install fails): listed in output" "yes" "$semgrep_listed"
}

test_missing_uv_brew_failure_reports_missing
test_missing_astgrep_brew_failure_reports_missing
test_missing_semgrep_brew_failure_reports_missing

# ── test_colima_installs_docker_cli ──────────────────────────────────────────
# When colima is installed (or already present) but the docker CLI is absent,
# check_homebrew_deps() must call `brew install docker` so that the docker CLI
# is available on PATH after colima provides the Docker daemon.
#
# RED: fails before fix because the script only calls `brew install colima` —
# it never installs the docker CLI, so `command -v docker` still fails after
# colima is set up and subsequent tooling (e.g. dependency checks) reports
# "docker not found".
#
# GREEN: after fix, when docker CLI is absent and colima is present (installed
# or already on PATH), the script calls `brew install docker`; the brew stub
# records the call and the test asserts it was made.
test_colima_installs_docker_cli() {
    local stub_bin node_prefix brew_log
    stub_bin=$(_make_stub_bin)
    node_prefix=$(mktemp -d)
    brew_log=$(mktemp)
    TMPDIRS+=("$node_prefix" "$brew_log")
    mkdir -p "$node_prefix/bin"

    # brew stub: records every invocation to brew_log; all installs succeed
    cat > "$stub_bin/brew" <<BREWEOF
#!/bin/sh
echo "\$*" >> "$brew_log"
case "\$*" in
  "install node@20")   exit 0 ;;
  "list node@20")      exit 0 ;;
  "--prefix node@20")  echo "$node_prefix"; exit 0 ;;
  "install --cask "*)  exit 0 ;;
  "--version"|"-v")    echo "Homebrew 4.0.0"; exit 0 ;;
  *)                   exit 0 ;;
esac
BREWEOF
    chmod +x "$stub_bin/brew"

    # colima stub: already installed and running — no start needed
    cat > "$stub_bin/colima" <<'COLIMAEOF'
#!/bin/sh
case "$1" in
  status) echo "colima is running"; exit 0 ;;
  *)      exit 0 ;;
esac
COLIMAEOF
    chmod +x "$stub_bin/colima"

    # Provide all deps EXCEPT docker — docker intentionally absent so the
    # colima path fires and brew install docker should be called
    _write_stub "$stub_bin" "bash"       "echo \"GNU bash, version 5.2.15(1)-release\"; exit 0"
    _write_stub "$stub_bin" "git"        "exit 0"
    _write_stub "$stub_bin" "greadlink"  "exit 0"
    _write_stub "$stub_bin" "pre-commit" "exit 0"
    _write_stub "$stub_bin" "python3"    "exit 0"
    _write_stub "$stub_bin" "node"       "echo \"v20.11.0\"; exit 0"
    _write_stub "$stub_bin" "claude"     "exit 0"
    _write_stub "$stub_bin" "uv"         "exit 0"
    _write_stub "$stub_bin" "sg"         "exit 0"
    _write_stub "$stub_bin" "semgrep"    "exit 0"
    _write_stub "$stub_bin" "grep"       '/usr/bin/grep "$@"'
    _write_stub "$stub_bin" "head"       '/usr/bin/head "$@"'
    _write_stub "$stub_bin" "dirname"    '/usr/bin/dirname "$@"'
    _write_stub "$stub_bin" "tr"         '/usr/bin/tr "$@"'
    # NOTE: docker is deliberately NOT added to stub_bin

    local output exit_code=0
    output=$(PATH="$stub_bin" /bin/bash "$SCRIPT_UNDER_TEST" 2>&1) || exit_code=$?

    # Script must exit 0 — docker CLI install success is not fatal
    assert_eq "colima present, docker CLI missing: script exits 0" "0" "$exit_code"

    # brew must have been called with "install docker"
    local docker_install_called="no"
    if grep -q "install docker" "$brew_log" 2>/dev/null; then
        docker_install_called="yes"
    fi
    assert_eq "colima present, docker CLI missing: brew install docker was called" "yes" "$docker_install_called"
}

test_colima_installs_docker_cli

# ── test_installer_configures_dso_shim_after_deps ────────────────────────────
# After a successful install, the DSO shim must exist at .claude/scripts/dso
# in the project directory (placed there by dso-setup.sh invocation).
#
# RED: fails before fix because create-dso-app.sh never calls dso-setup.sh —
# it installs deps and immediately writes the sentinel and launches Claude Code
# without running any project configuration step.
#
# GREEN: after fix, main() calls dso-setup.sh after detect_dso_plugin_root,
# the stub dso-setup.sh creates .claude/scripts/dso, assertion passes.
test_installer_configures_dso_shim_after_deps() {
    local stub_bin T project_dir fake_plugin_root
    T=$(mktemp -d)
    TMPDIRS+=("$T")
    project_dir="$T/my-project"
    fake_plugin_root="$T/fake-plugin"

    # Fake plugin root: plugin.json sentinel + stub dso-setup.sh that creates the shim
    mkdir -p "$fake_plugin_root/.claude-plugin" "$fake_plugin_root/scripts/onboarding" \
             "$fake_plugin_root/templates/host-project"
    echo '{"name":"dso","version":"1.0.0"}' > "$fake_plugin_root/.claude-plugin/plugin.json"
    : > "$fake_plugin_root/templates/host-project/dso"
    cat > "$fake_plugin_root/scripts/onboarding/dso-setup.sh" <<'SETUPEOF'
#!/bin/sh
target="${1:-}"
if [ -n "$target" ]; then
    /bin/mkdir -p "$target/.claude/scripts"
    printf '#!/bin/sh\nexec dso "$@"\n' > "$target/.claude/scripts/dso"
    /bin/chmod +x "$target/.claude/scripts/dso"
fi
exit 0
SETUPEOF
    chmod +x "$fake_plugin_root/scripts/onboarding/dso-setup.sh"

    stub_bin=$(_installer_stub_bin)
    # Override bash stub: handle --version (returns >=4 for version check) but
    # pass all other calls through to real /bin/bash so dso-setup.sh stub runs
    cat > "$stub_bin/bash" <<'BASHEOF'
#!/bin/sh
case "$1" in
  --version|-v) echo "GNU bash, version 5.2.15(1)-release (x86_64-pc-linux-gnu)"; exit 0 ;;
  *) exec /bin/bash "$@" ;;
esac
BASHEOF
    chmod +x "$stub_bin/bash"

    CLAUDE_PLUGIN_ROOT="$fake_plugin_root" \
    PATH="$stub_bin" /bin/bash "$SCRIPT_UNDER_TEST" "my-project" "$T" <<< $'\n' >/dev/null 2>&1 || true

    local shim_ok="no"
    [[ -f "$project_dir/.claude/scripts/dso" ]] && [[ -x "$project_dir/.claude/scripts/dso" ]] && shim_ok="yes"
    assert_eq "installer runs dso-setup: .claude/scripts/dso shim installed" "yes" "$shim_ok"
}

test_installer_configures_dso_shim_after_deps

# ── test_installer_shim_installed_even_when_dso_setup_fails ──────────────────
# Bug 14f9-060b: when dso-setup.sh exits non-zero (e.g., missing timeout,
# bash < 4, or artifact-merge-lib.sh failure), create-dso-app.sh swallows the
# error via '|| echo WARNING' — but the shim was never created, so
# .claude/scripts/dso is absent after a nominally-successful install.
#
# Fix (Step 5c.5): after dso-setup.sh returns, if .claude/scripts/dso is
# missing, copy it directly from $resolved_plugin_root/templates/host-project/dso.
#
# GREEN: after fix, even with a failing dso-setup.sh, the shim is present.
test_installer_shim_installed_even_when_dso_setup_fails() {
    local stub_bin T project_dir fake_plugin_root
    T=$(mktemp -d)
    TMPDIRS+=("$T")
    project_dir="$T/my-project"
    fake_plugin_root="$T/fake-plugin"

    # Fake plugin root: plugin.json sentinel + FAILING dso-setup.sh + shim template
    mkdir -p "$fake_plugin_root/.claude-plugin" "$fake_plugin_root/scripts/onboarding" \
             "$fake_plugin_root/templates/host-project"
    echo '{"name":"dso","version":"1.0.0"}' > "$fake_plugin_root/.claude-plugin/plugin.json"
    # dso-setup.sh that exits 1 (simulates detect_prerequisites failure)
    cat > "$fake_plugin_root/scripts/onboarding/dso-setup.sh" <<'SETUPEOF'
#!/bin/sh
exit 1
SETUPEOF
    chmod +x "$fake_plugin_root/scripts/onboarding/dso-setup.sh"
    # Shim template that the fallback should copy
    printf '#!/bin/sh\n# DSO shim\nexec dso "$@"\n' \
        > "$fake_plugin_root/templates/host-project/dso"
    chmod +x "$fake_plugin_root/templates/host-project/dso"

    stub_bin=$(_installer_stub_bin)
    # Override bash stub: handle --version but pass other calls to real /bin/bash
    cat > "$stub_bin/bash" <<'BASHEOF'
#!/bin/sh
case "$1" in
  --version|-v) echo "GNU bash, version 5.2.15(1)-release (x86_64-pc-linux-gnu)"; exit 0 ;;
  *) exec /bin/bash "$@" ;;
esac
BASHEOF
    chmod +x "$stub_bin/bash"

    CLAUDE_PLUGIN_ROOT="$fake_plugin_root" \
    PATH="$stub_bin" /bin/bash "$SCRIPT_UNDER_TEST" "my-project" "$T" <<< $'\n' >/dev/null 2>&1 || true

    local shim_ok="no"
    [[ -f "$project_dir/.claude/scripts/dso" ]] && [[ -x "$project_dir/.claude/scripts/dso" ]] && shim_ok="yes"
    assert_eq "shim fallback: .claude/scripts/dso installed even when dso-setup.sh fails" "yes" "$shim_ok"
}

test_installer_shim_installed_even_when_dso_setup_fails

# ── test_no_project_name_no_tty_prints_usage_hint ────────────────────────────
# Bug 3ce2-f279: running the script with no positional arg and no tty silently
# exits 0 after "All dependencies satisfied." — user gets no hint about how to
# invoke it. Fix: when non-interactive and no project name, print usage hint to
# stderr before exit 0. Test harness has no controlling tty, so [ -t 0 ] is
# false and the non-interactive branch is exercised.
test_no_project_name_no_tty_prints_usage_hint() {
    echo ""
    echo "→ test_no_project_name_no_tty_prints_usage_hint"

    local stub_bin output exit_code
    stub_bin=$(_all_deps_stub_bin)

    # Run with NO positional argument. Redirect stdin from /dev/null so
    # [ -t 0 ] is false inside the script (no tty path).
    output=$(PATH="$stub_bin" /bin/bash "$SCRIPT_UNDER_TEST" </dev/null 2>&1)
    exit_code=$?

    # Backward-compat: still exits 0
    assert_eq "no-arg no-tty: exit 0 preserved" "0" "$exit_code"

    # Backward-compat: still prints deps-satisfied message
    local satisfied="no"
    grep -q "All dependencies satisfied" <<< "$output" && satisfied="yes"
    assert_eq "no-arg no-tty: deps-satisfied message preserved" "yes" "$satisfied"

    # RED assertion: output must mention "project-name" so the user knows how
    # to re-invoke. Currently fails — script emits no usage hint.
    local has_hint="no"
    grep -qi "project-name" <<< "$output" && has_hint="yes"
    assert_eq "no-arg no-tty: usage hint mentions project-name" "yes" "$has_hint"
}

test_no_project_name_no_tty_prints_usage_hint

# ── test_detect_dso_plugin_root_marketplace_internal_layout ──────────────────
# RED: detect_dso_plugin_root() must find plugin.json at the real Claude Code
# marketplace-internal layout: <base>/digital-service-orchestra/plugins/dso/
# .claude-plugin/plugin.json. The old code probed the wrong path
# (<base>/digital-service-orchestra/.claude-plugin/plugin.json) — this test
# asserts the correct layout is detected (bug 17d3-e2c8).
test_detect_dso_plugin_root_marketplace_internal_layout() {
    echo ""
    echo "→ test_detect_dso_plugin_root_marketplace_internal_layout"

    local T mock_base detected exit_code
    T=$(mktemp -d)
    TMPDIRS+=("$T")
    mock_base="$T/marketplaces"

    # Correct layout: <base>/digital-service-orchestra/plugins/dso/.claude-plugin/plugin.json
    mkdir -p "$mock_base/digital-service-orchestra/plugins/dso/.claude-plugin" \
             "$mock_base/digital-service-orchestra/plugins/dso/templates/host-project"
    echo '{"name":"dso","version":"1.0.0"}' \
        > "$mock_base/digital-service-orchestra/plugins/dso/.claude-plugin/plugin.json"
    : > "$mock_base/digital-service-orchestra/plugins/dso/templates/host-project/dso"

    detected=$(
        MARKETPLACE_BASE="$mock_base" \
        CLAUDE_PLUGIN_ROOT='' \
        /bin/bash -c "
            source '$PLUGIN_ROOT/scripts/create-dso-app.sh'
            detect_dso_plugin_root ''
        " 2>/dev/null
    ) || exit_code=$?
    exit_code=${exit_code:-0}

    assert_eq "detect_dso_plugin_root: marketplace-internal layout resolves" \
        "$mock_base/digital-service-orchestra/plugins/dso" "$detected"
    assert_eq "detect_dso_plugin_root: exits 0" "0" "$exit_code"
}

# ── test_detect_dso_plugin_root_auto_installs_when_missing ───────────────────
# RED: when no plugin is found via static paths, detect_dso_plugin_root() must
# invoke `claude plugin marketplace add` and `claude plugin install dso`, then
# re-detect successfully rather than exiting 1 with an error (bug 17d3-e2c8).
test_detect_dso_plugin_root_auto_installs_when_missing() {
    echo ""
    echo "→ test_detect_dso_plugin_root_auto_installs_when_missing"

    local T stub_bin mock_base installed_path detected exit_code
    T=$(mktemp -d)
    TMPDIRS+=("$T")
    stub_bin=$(mktemp -d)
    TMPDIRS+=("$stub_bin")
    mock_base="$T/marketplaces"
    # Stub `claude` to simulate `plugin marketplace add` + `plugin install dso`:
    # writes plugin.json into the mock marketplace base so the re-probe finds it.
    cat > "$stub_bin/claude" <<CLAUDEOF
#!/bin/sh
case "\$*" in
  "plugin marketplace add"*) exit 0 ;;
  "plugin install dso"*)
    mkdir -p "$mock_base/digital-service-orchestra/plugins/dso/.claude-plugin" \
             "$mock_base/digital-service-orchestra/plugins/dso/templates/host-project"
    echo '{"name":"dso","version":"1.0.0"}' > "$mock_base/digital-service-orchestra/plugins/dso/.claude-plugin/plugin.json"
    : > "$mock_base/digital-service-orchestra/plugins/dso/templates/host-project/dso"
    exit 0 ;;
  *) exit 0 ;;
esac
CLAUDEOF
    chmod +x "$stub_bin/claude"

    # Use an isolated HOME so probe 2b (cache scan) finds no real installation,
    # forcing the auto-install code path to be exercised.
    local fake_home="$T/fakehome"
    mkdir -p "$fake_home"

    detected=$(
        PATH="$stub_bin:/usr/bin:/bin" \
        HOME="$fake_home" \
        MARKETPLACE_BASE="$mock_base" \
        CLAUDE_PLUGIN_ROOT='' \
        /bin/bash -c "
            source '$PLUGIN_ROOT/scripts/create-dso-app.sh'
            detect_dso_plugin_root ''
        " 2>/dev/null
    ) || exit_code=$?
    exit_code=${exit_code:-0}

    assert_eq "detect_dso_plugin_root: auto-install invoked, exits 0" "0" "$exit_code"
    local has_path="no"
    [[ "$detected" == *"$mock_base"* ]] && has_path="yes"
    assert_eq "detect_dso_plugin_root: returns a path after auto-install" "yes" "$has_path"
}

# ── test_detect_dso_plugin_root_bash_source_guard ────────────────────────────
# RED: when BASH_SOURCE[0] is a /dev/fd/* path (process substitution, as with
# `bash <(curl ...)`), _PLUGIN_ROOT must not be set to a /dev/* path. The
# guard should fall through to the DSO_PLUGIN_ROOT env var fallback instead
# (bug 17d3-e2c8).
test_detect_dso_plugin_root_bash_source_guard() {
    echo ""
    echo "→ test_detect_dso_plugin_root_bash_source_guard"

    local T mock_base detected
    T=$(mktemp -d)
    TMPDIRS+=("$T")
    mock_base="$T/marketplaces"

    # Provide plugin via marketplace so re-detection after bad _PLUGIN_ROOT succeeds
    mkdir -p "$mock_base/digital-service-orchestra/plugins/dso/.claude-plugin" \
             "$mock_base/digital-service-orchestra/plugins/dso/templates/host-project"
    echo '{"name":"dso","version":"1.0.0"}' \
        > "$mock_base/digital-service-orchestra/plugins/dso/.claude-plugin/plugin.json"
    : > "$mock_base/digital-service-orchestra/plugins/dso/templates/host-project/dso"

    # Simulate a stdin/pipe BASH_SOURCE path (e.g. bash -s or bash <(curl ...)):
    # source the script via a heredoc so BASH_SOURCE[0] is not a real file path.
    # The same guard applies to /dev/fd/N (process substitution) and /dev/stdin
    # (pipe) — both fail the `[ -f ]` check, causing _PLUGIN_ROOT to be unset
    # and falling through to the marketplace probe. Verify two things:
    # (1) _PLUGIN_ROOT is not set to a /dev* path (negative: guard is effective)
    # (2) detect_dso_plugin_root() still succeeds and returns the mock_base path
    #     (positive: fallback probe works after guard clears _PLUGIN_ROOT)
    local plugin_root_leaked="no"
    local output exit_code
    output=$(
        MARKETPLACE_BASE="$mock_base" \
        CLAUDE_PLUGIN_ROOT='' \
        /bin/bash -s <<HEREDOC 2>&1
source "$PLUGIN_ROOT/scripts/create-dso-app.sh"
# After source, _PLUGIN_ROOT should NOT be /dev or /dev/fd/*
if [[ "\${_PLUGIN_ROOT:-}" == /dev* ]]; then
    echo "LEAKED:/dev"
fi
detect_dso_plugin_root ''
HEREDOC
    ); exit_code=$?

    grep -q "LEAKED:/dev" <<< "$output" && plugin_root_leaked="yes"
    assert_eq "_PLUGIN_ROOT not set to /dev* when sourced via heredoc/pipe" "no" "$plugin_root_leaked"

    local returned_path_ok="no"
    [[ "$output" == *"$mock_base"* ]] && returned_path_ok="yes"
    assert_eq "detect_dso_plugin_root() succeeds and returns mock_base path" "yes" "$returned_path_ok"
    assert_eq "detect_dso_plugin_root() exits 0" "0" "$exit_code"
}

test_detect_dso_plugin_root_marketplace_internal_layout
test_detect_dso_plugin_root_auto_installs_when_missing
test_detect_dso_plugin_root_bash_source_guard

# ── test_detect_dso_plugin_root_registers_plugin_even_when_probe_matches ─────
# RED: when a filesystem probe (probe 2 — marketplace stale files) matches and
# returns plugin_root, detect_dso_plugin_root() must STILL invoke
#   claude plugin install dso@digital-service-orchestra --scope project
# from inside $project_dir so the plugin is registered/enabled for the newly
# created project. The current code only runs `claude plugin install` inside the
# `[ -z "$plugin_root" ]` guard (probe 4), so when probe 2 matches early the
# install is never called and /dso:* commands are unavailable in the new project.
#
# Observable behavior: after detect_dso_plugin_root "$project_dir" completes,
# the capture log written by the stubbed `claude` CLI must contain a line that
# includes all three of: "plugin install", "dso@", and "--scope project",
# and the pwd for that invocation must equal $project_dir.
test_detect_dso_plugin_root_registers_plugin_even_when_probe_matches() {
    echo ""
    echo "→ test_detect_dso_plugin_root_registers_plugin_even_when_probe_matches"

    local T stub_bin mock_base capture_log project_dir exit_code output
    T=$(mktemp -d)
    TMPDIRS+=("$T")
    stub_bin=$(mktemp -d)
    TMPDIRS+=("$stub_bin")

    # ── fake marketplace layout so probe 2 succeeds immediately ──────────────
    # This is the "stale files from prior install" scenario — probe 2 matches,
    # so the real code short-circuits probe 4 and never calls claude plugin install.
    mock_base="$T/marketplaces"
    mkdir -p "$mock_base/digital-service-orchestra/plugins/dso/.claude-plugin" \
             "$mock_base/digital-service-orchestra/plugins/dso/templates/host-project"
    printf '{"name":"dso","version":"1.0.0-stale"}\n' \
        > "$mock_base/digital-service-orchestra/plugins/dso/.claude-plugin/plugin.json"
    : > "$mock_base/digital-service-orchestra/plugins/dso/templates/host-project/dso"

    # ── fixture project dir with dso-config.conf (required for config write) ─
    project_dir="$T/myproject"
    mkdir -p "$project_dir/.claude"
    printf 'dso.plugin_root=\n' > "$project_dir/.claude/dso-config.conf"

    # ── claude stub: logs every invocation's argv + pwd to capture_log ───────
    capture_log="$T/claude-invocations.log"
    cat > "$stub_bin/claude" <<CLAUDESTUB
#!/bin/sh
# Record argv (space-joined) and cwd for every invocation
printf 'argv=%s\tpwd=%s\n' "\$*" "\$(pwd)" >> "$capture_log"
exit 0
CLAUDESTUB
    chmod +x "$stub_bin/claude"

    # Stub dso shim (smoke test calls dso ticket show --help inside project_dir)
    mkdir -p "$project_dir/.claude/scripts"
    cat > "$project_dir/.claude/scripts/dso" <<'SHIMSTUB'
#!/bin/sh
exit 0
SHIMSTUB
    chmod +x "$project_dir/.claude/scripts/dso"

    # ── invoke detect_dso_plugin_root with probe-2-matching marketplace ───────
    output=$(
        PATH="$stub_bin:/usr/bin:/bin" \
        MARKETPLACE_BASE="$mock_base" \
        CLAUDE_PLUGIN_ROOT='' \
        /bin/bash -c "
            source '$PLUGIN_ROOT/scripts/create-dso-app.sh'
            detect_dso_plugin_root '$project_dir'
        " 2>&1
    ) && exit_code=0 || exit_code=$?

    # ── assertions ────────────────────────────────────────────────────────────

    # Assert 1: detect_dso_plugin_root exits 0 (probe 2 matched — no regression)
    assert_eq "detect_dso_plugin_root exits 0 when probe 2 matches" "0" "$exit_code"

    # Assert 2: claude was invoked at all (capture log exists and is non-empty)
    local claude_called="no"
    [[ -s "$capture_log" ]] && claude_called="yes"
    assert_eq "claude CLI was invoked at least once" "yes" "$claude_called"

    if [[ "$claude_called" != "yes" ]]; then
        printf "DIAGNOSTIC: script output:\n%s\n" "$output" >&2
        return
    fi

    # Assert 3: one of those invocations was 'plugin install dso@... --scope project'
    local install_called="no"
    local install_line
    install_line=$(grep 'plugin install' "$capture_log" | grep 'dso@' | grep -- '--scope project' || true)
    [[ -n "$install_line" ]] && install_called="yes"
    assert_eq "claude plugin install dso@... --scope project was invoked" "yes" "$install_called"

    # Assert 4: that invocation's pwd equals project_dir
    if [[ "$install_called" == "yes" ]]; then
        local install_pwd
        install_pwd=$(printf '%s' "$install_line" | cut -f2 | sed 's/^pwd=//')
        assert_eq "plugin install was run from inside project_dir" "$project_dir" "$install_pwd"
    fi
}

test_detect_dso_plugin_root_registers_plugin_even_when_probe_matches

print_summary
