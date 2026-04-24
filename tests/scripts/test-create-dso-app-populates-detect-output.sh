#!/usr/bin/env bash
# tests/scripts/test-create-dso-app-populates-detect-output.sh
#
# RED-phase test for bug 2aef-d323:
#   create-dso-app.sh must invoke project-detect.sh and export DSO_DETECT_OUTPUT
#   (pointing at a non-empty file) into the environment passed to dso-setup.sh.
#
# Observable behavior tested:
#   After main() runs against a fixture project directory (template clone stubbed),
#   the stub dso-setup.sh captures the environment it receives. The test asserts:
#     (1) DSO_DETECT_OUTPUT is set in that captured environment, AND
#     (2) the file it points to exists and is non-empty (written by project-detect.sh).
#
# RED phase: both assertions FAIL because create-dso-app.sh never calls
#   project-detect.sh and never sets DSO_DETECT_OUTPUT before invoking dso-setup.sh.
#
# Usage:
#   bash tests/scripts/test-create-dso-app-populates-detect-output.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRIPT_UNDER_TEST="$REPO_ROOT/scripts/create-dso-app.sh"

source "$REPO_ROOT/tests/lib/assert.sh"

TMPDIRS=()
TMPFILES=()
trap 'rm -rf "${TMPDIRS[@]}" "${TMPFILES[@]}"' EXIT

echo "=== test-create-dso-app-populates-detect-output.sh ==="

# ── helpers ───────────────────────────────────────────────────────────────────

_make_tmp_dir() {
    local d
    d=$(mktemp -d)
    TMPDIRS+=("$d")
    echo "$d"
}

_make_tmp_file() {
    local f
    f=$(mktemp)
    TMPFILES+=("$f")
    echo "$f"
}

_write_stub() {
    local dir="$1" name="$2" body="$3"
    printf '#!/bin/sh\n%s\n' "$body" > "$dir/$name"
    chmod +x "$dir/$name"
}

# ── test ─────────────────────────────────────────────────────────────────────
#
# GIVEN  a stub plugin root where project-detect.sh writes a detection file
#        and dso-setup.sh captures its environment
# WHEN   create-dso-app.sh main() is invoked with a project name, stdin fed
#        with an Enter keystroke to pass the ack prompt, git clone stubbed to
#        create the project dir in-place
# THEN   the environment captured by dso-setup.sh contains DSO_DETECT_OUTPUT
#        pointing at a non-empty file produced by project-detect.sh

test_dso_setup_receives_dso_detect_output() {
    local target_dir env_capture stub_bin plugin_root project_name project_dir

    target_dir=$(_make_tmp_dir)
    env_capture=$(_make_tmp_file)
    project_name="testproj$$"
    project_dir="$target_dir/$project_name"

    # ── stub plugin root ──────────────────────────────────────────────────────
    plugin_root=$(_make_tmp_dir)
    mkdir -p "$plugin_root/.claude-plugin" "$plugin_root/scripts/onboarding"
    printf '{"name":"dso","version":"0.0.0-test"}\n' > "$plugin_root/.claude-plugin/plugin.json"

    # project-detect.sh stub: emits key=value detection lines to stdout.
    # Matches the real contract — the fix captures stdout into a file and exports
    # its path as DSO_DETECT_OUTPUT (consumed by dso-setup._run_ci_guard_analysis).
    cat > "$plugin_root/scripts/onboarding/project-detect.sh" <<'DETECT'
#!/usr/bin/env bash
set -eu
printf 'stack=nextjs\nstack_confidence=confirmed\nci_workflow_lint_guarded=true\n'
DETECT
    chmod +x "$plugin_root/scripts/onboarding/project-detect.sh"

    # dso-setup.sh stub: dump the full environment to env_capture, AND snapshot
    # the DSO_DETECT_OUTPUT file contents to a sentinel (so the assertion can
    # verify non-empty even after create-dso-app cleans up the tmp file).
    detect_snapshot=$(_make_tmp_dir)/detect-snapshot
    cat > "$plugin_root/scripts/onboarding/dso-setup.sh" <<SETUP
#!/usr/bin/env bash
env > "${env_capture}"
if [ -n "\${DSO_DETECT_OUTPUT:-}" ] && [ -f "\${DSO_DETECT_OUTPUT}" ]; then
    cp "\${DSO_DETECT_OUTPUT}" "${detect_snapshot}"
fi
exit 0
SETUP
    chmod +x "$plugin_root/scripts/onboarding/dso-setup.sh"

    # ── stub bin dir ──────────────────────────────────────────────────────────
    stub_bin=$(_make_tmp_dir)

    # git clone stub: create the project dir (simulating a successful clone)
    # so the script proceeds to Steps 4-5c without network access.
    cat > "$stub_bin/git" <<GIT
#!/usr/bin/env bash
# Uses bash-only array slice (\${@: -1}) to extract the destination arg; must be bash, not sh.
if [ "\$1" = "clone" ]; then
  # Last argument is the destination directory
  _dest="\${@: -1}"
  mkdir -p "\$_dest"
  printf '{}' > "\$_dest/package.json"
fi
exit 0
GIT
    chmod +x "$stub_bin/git"

    # npm install stub: no-op
    _write_stub "$stub_bin" "npm" "exit 0"

    # brew: stub for dependency checks in check_homebrew_deps
    cat > "$stub_bin/brew" <<'BREW'
#!/bin/sh
case "$*" in
  "--version"|"-v")  echo "Homebrew 4.0.0" ;;
  "--prefix node@20") echo "/usr/local" ;;
  "list node@20")    exit 0 ;;
  "install node@20") exit 0 ;;
  "install --cask "*)exit 0 ;;
  *) exit 0 ;;
esac
BREW
    chmod +x "$stub_bin/brew"

    _write_stub "$stub_bin" "node"       'echo "v20.11.0"; exit 0'
    _write_stub "$stub_bin" "pre-commit" "exit 0"
    _write_stub "$stub_bin" "python3"    "exit 0"
    _write_stub "$stub_bin" "docker"     "exit 0"
    _write_stub "$stub_bin" "greadlink"  "exit 0"
    _write_stub "$stub_bin" "uv"         "exit 0"
    _write_stub "$stub_bin" "sg"         "exit 0"
    _write_stub "$stub_bin" "semgrep"    "exit 0"
    # claude: create-dso-app.sh ends with `exec claude`; stub exits 0
    _write_stub "$stub_bin" "claude"     "exit 0"
    # bash: forward to real bash (avoids stub-bash recursion via exec wrapper)
    _write_stub "$stub_bin" "bash"       'exec /bin/bash "$@"'

    # Proxy real system utilities used internally by the script
    for _cmd in grep head tr sed find cat date uname tput; do
        _write_stub "$stub_bin" "$_cmd" "exec /usr/bin/$_cmd \"\$@\" 2>/dev/null"
    done
    _write_stub "$stub_bin" "dirname"  "exec /usr/bin/dirname \"\$@\""
    _write_stub "$stub_bin" "readlink" "exec /usr/bin/readlink \"\$@\" 2>/dev/null || true"
    for _cmd in mkdir cp chmod rm; do
        _write_stub "$stub_bin" "$_cmd" "exec /bin/$_cmd \"\$@\""
    done

    # ── invoke main() ─────────────────────────────────────────────────────────
    # Feed a newline on stdin to pass the acknowledgement prompt ("Press Enter
    # to continue or Ctrl-C to cancel"). The project dir does NOT pre-exist so
    # the partial-install branch (which reads a second prompt) is never reached.
    local output exit_code
    output=$(
        printf '\n' | \
        PATH="$stub_bin:/usr/bin:/bin" \
        CLAUDE_PLUGIN_ROOT="$plugin_root" \
        /bin/bash "$SCRIPT_UNDER_TEST" "$project_name" "$target_dir" 2>&1
    ) && exit_code=0 || exit_code=$?

    # ── assertions ────────────────────────────────────────────────────────────

    # Assert 1: dso-setup.sh was invoked (env capture file is non-empty)
    local setup_called="no"
    if [[ -s "$env_capture" ]]; then
        setup_called="yes"
    fi
    assert_eq "dso-setup.sh was invoked (env capture written)" "yes" "$setup_called"

    # Short-circuit: remaining assertions require setup to have been called.
    if [[ "$setup_called" != "yes" ]]; then
        printf "DIAGNOSTIC: script output (last 20 lines):\n%s\n" \
            "$(printf '%s' "$output" | tail -20)" >&2
        return
    fi

    # Assert 2: DSO_DETECT_OUTPUT was present in the env passed to dso-setup.sh
    local raw_line
    raw_line=$(grep '^DSO_DETECT_OUTPUT=' "$env_capture" | head -1 || true)

    local var_set="no"
    if [[ -n "$raw_line" ]]; then
        var_set="yes"
    fi
    assert_eq "DSO_DETECT_OUTPUT is exported to dso-setup.sh environment" "yes" "$var_set"

    # Assert 3: dso-setup saw a non-empty detect file (content snapshot at
    # dso-setup invocation time — the real installer cleans up the tmp file
    # after dso-setup returns, so we must verify the content as observed by
    # the consumer, not post-cleanup).
    if [[ "$var_set" == "yes" ]]; then
        local file_nonempty="no"
        if [[ -s "$detect_snapshot" ]]; then
            file_nonempty="yes"
        fi
        assert_eq "DSO_DETECT_OUTPUT points to a non-empty detect file" "yes" "$file_nonempty"
    fi
}

# ── run ───────────────────────────────────────────────────────────────────────

test_dso_setup_receives_dso_detect_output

print_summary
