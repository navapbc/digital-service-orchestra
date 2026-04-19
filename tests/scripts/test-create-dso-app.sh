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
    _write_stub "$stub_bin" "node" "echo \"$node_ver\"; exit 0"
    _write_stub "$stub_bin" "claude" "exit 0"
    # Proxy stubs: the script calls grep/head/dirname/tr for version parsing
    # and path detection; proxy to /usr/bin so they work under isolated PATH.
    _write_stub "$stub_bin" "grep"    '/usr/bin/grep "$@"'
    _write_stub "$stub_bin" "head"    '/usr/bin/head "$@"'
    _write_stub "$stub_bin" "dirname" '/usr/bin/dirname "$@"'
    _write_stub "$stub_bin" "tr"      '/usr/bin/tr "$@"'

    echo "$stub_bin"
}

# ── test_homebrew_not_installed_exits_1 ──────────────────────────────────────
# When `brew` is not on PATH, check_homebrew_deps must exit 1 and print an
# install hint.
test_homebrew_not_installed_exits_1() {
    local stub_bin
    stub_bin=$(_make_stub_bin)
    # Intentionally do NOT add brew to stub_bin.
    # Add proxy stubs for commands used before the brew check (path detection).
    _write_stub "$stub_bin" "dirname" '/usr/bin/dirname "$@"'

    local output exit_code
    output=$(_run_script "$stub_bin" 2>&1) && exit_code=0 || exit_code=$?

    assert_ne "homebrew absent exits non-zero" "0" "$exit_code"

    local msg_found="no"
    if echo "$output" | grep -qi "homebrew"; then
        msg_found="yes"
    fi
    assert_eq "homebrew absent prints hint" "yes" "$msg_found"
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
    if echo "$output" | grep -q "All dependencies satisfied"; then
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
    if echo "$output" | grep -qi "git"; then
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

    # Create mock marketplace sentinel
    mkdir -p "$mock_marketplace/digital-service-orchestra/.claude-plugin"
    echo '{"name":"dso"}' > "$mock_marketplace/digital-service-orchestra/.claude-plugin/plugin.json"

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
    local expected_root="$mock_marketplace/digital-service-orchestra"

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
        mkdir -p "$target/app"
        printf '{"name":"template","scripts":{"dev":"next dev"},"dependencies":{"next":"^14.0.0"}}\n' \
            > "$target/package.json"
        touch "$target/app/page.tsx"
        mkdir -p "$target/.claude"
    fi
    exit 0
fi
exit 0
GITSTUB
    chmod +x "$stub_bin/git"

    _write_stub "$stub_bin" "bash" "echo \"GNU bash, version 5.2.15(1)-release (x86_64)\"; exit 0"
    _write_stub "$stub_bin" "greadlink" "exit 0"
    _write_stub "$stub_bin" "pre-commit" "exit 0"
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

    local app_ok="no"
    { [[ -d "$project_dir/app" ]] || [[ -d "$project_dir/pages" ]]; } && app_ok="yes"
    assert_eq "project structure: app/ or pages/ present" "yes" "$app_ok"

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
        echo "$output" | grep -qiE 'sanitize|invalid|character|name' && handled="yes"
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
    echo "$output" | grep -q "Installation cancelled" && cancelled="yes"
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
    echo "$output" | grep -qiE 'already|initialized|complete|exists' && msg_ok="yes"
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
    echo "$output" | grep -qi "Run: brew install git" && manual_hint="yes"
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
    echo "$output" | grep -q "All dependencies satisfied" && satisfied="yes"
    assert_eq "shellenv injection: all deps satisfied message" "yes" "$satisfied"

    # Assert: no "coreutils" listed as missing in error output
    local coreutils_missing="no"
    echo "$output" | grep -qi "coreutils" && coreutils_missing="yes"
    assert_eq "shellenv injection: coreutils NOT listed as missing" "no" "$coreutils_missing"
}

test_missing_git_auto_installs_via_brew
test_brew_shellenv_path_injection_prevents_false_missing

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
    echo "$output" | grep -q "All dependencies satisfied" && satisfied="yes"
    assert_eq "no-arg no-tty: deps-satisfied message preserved" "yes" "$satisfied"

    # RED assertion: output must mention "project-name" so the user knows how
    # to re-invoke. Currently fails — script emits no usage hint.
    local has_hint="no"
    echo "$output" | grep -qi "project-name" && has_hint="yes"
    assert_eq "no-arg no-tty: usage hint mentions project-name" "yes" "$has_hint"
}

test_no_project_name_no_tty_prints_usage_hint

print_summary
