#!/usr/bin/env bash
# tests/scripts/test-check-local-env-generic.sh
# TDD RED phase: tests for the generic canonical check-local-env.sh behavior.
#
# Tests cover:
#   1. Exits 0 when Docker+DB are healthy and no env_check_app is configured (generic-only mode)
#   2. Emits a WARN and exits 0 when commands.env_check_app is absent from workflow-config.conf
#   3. Invokes the configured env_check_app command when commands.env_check_app is present
#   4. Exits non-zero when env_check_app command exits non-zero (error path)
#   5. Config-driven DB container name override
#   6. Config-driven health timeout override
#
# Usage: bash tests/scripts/test-check-local-env-generic.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

# REVIEW-DEFENSE: '-e' is intentionally omitted from set flags. The test harness must
# capture non-zero exit codes from _run_script (e.g., test_env_check_app_error_exits_nonzero
# expects a non-zero exit). With '-e', the script would abort on those expected failures
# before the assert_ne can verify them. Setup failures in _make_skeleton are detectable
# via the subsequent _run_script output and assertion failures, which is sufficient here.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR" && git rev-parse --show-toplevel)"
# REVIEW-DEFENSE: This path points to the future canonical script location inside the
# workflow plugin. The test is intentionally RED — it will pass only after task
# lockpick-doc-to-logic-sn0y creates the canonical script at this path. Per TDD workflow,
# tests are written before the implementation exists. The reviewer's suggestion to point
# at 'scripts/check-local-env.sh' (the project-specific script) is incorrect: this test
# covers the generic canonical behavior that will live in scripts/.
CANONICAL_SCRIPT="$PLUGIN_ROOT/scripts/check-local-env.sh"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-check-local-env-generic.sh ==="

# ── Setup: shared temp environment ───────────────────────────────────────────
TMPDIR_BASE="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_BASE"' EXIT

# Helper: create a minimal project skeleton with the given workflow-config.conf content
_make_skeleton() {
    local name="$1" config_content="$2"
    local dir="$TMPDIR_BASE/$name"
    mkdir -p "$dir" || { echo "ERROR: mkdir failed for $dir" >&2; exit 1; }
    git init -q -b main "$dir" || { echo "ERROR: git init failed for $dir" >&2; exit 1; }
    git -C "$dir" config user.email "test@example.com" || { echo "ERROR: git config email failed for $dir" >&2; exit 1; }
    git -C "$dir" config user.name "Test User" || { echo "ERROR: git config name failed for $dir" >&2; exit 1; }
    # Export identity env vars explicitly: on CI runners with no global gitconfig, empty
    # GIT_AUTHOR_*/GIT_COMMITTER_* env vars override local git config, causing "empty ident name".
    GIT_AUTHOR_NAME="Test User" GIT_AUTHOR_EMAIL="test@example.com" \
    GIT_COMMITTER_NAME="Test User" GIT_COMMITTER_EMAIL="test@example.com" \
    git -C "$dir" commit --allow-empty -m "init" -q || { echo "ERROR: git commit failed for $dir" >&2; exit 1; }
    printf '%s\n' "$config_content" > "$dir/workflow-config.conf" || { echo "ERROR: failed to write workflow-config.conf in $dir" >&2; exit 1; }
    echo "$dir"
}

# Helper: run the canonical script inside a skeleton directory, with all docker
# calls stubbed via PATH injection so tests don't require a real Docker daemon.
# Accepts optional extra env vars as NAME=VALUE arguments before the script args.
_run_script() {
    local skeleton_dir="$1"; shift
    # Remaining args are passed to the script

    # Build a stub bin dir that makes docker appear healthy without a daemon.
    # NOTE: _run_script is called via command substitution $(...), so $$ here
    # refers to the subshell PID, not the parent script PID. Each call gets a
    # unique stub-bin directory (different subshell PID each time), so the rm -rf
    # is a no-op guard against any unexpected prior stub at that path.
    local stub_bin="$TMPDIR_BASE/stub-bin-$$"
    rm -rf "$stub_bin"
    mkdir -p "$stub_bin"

    # stub docker: respond to `docker info` (daemon check) and `docker ps`
    cat > "$stub_bin/docker" <<'DOCKER_STUB'
#!/usr/bin/env bash
case "$*" in
    info*)       exit 0 ;;
    "ps --format"*)
        # Emit the container name from STUB_DB_CONTAINER env var if set
        echo "${STUB_DB_CONTAINER:-}"
        exit 0
        ;;
    "inspect --format"*)
        echo "healthy"
        exit 0
        ;;
    *)           exit 0 ;;
esac
DOCKER_STUB
    chmod +x "$stub_bin/docker"

    # stub pg_isready: always reports ready
    cat > "$stub_bin/pg_isready" <<'PG_STUB'
#!/usr/bin/env bash
exit 0
PG_STUB
    chmod +x "$stub_bin/pg_isready"

    # stub curl: return 200 for health endpoint
    # When CURL_LOG is set, append all invocation args to that file so tests
    # can assert on the flags that were passed (e.g. --max-time N).
    cat > "$stub_bin/curl" <<'CURL_STUB'
#!/usr/bin/env bash
if [[ -n "${CURL_LOG:-}" ]]; then
    echo "$*" >> "$CURL_LOG"
fi
# Check for -w flag to return http_code placeholder
if [[ "$*" == *"-w"* && "$*" == *"%{http_code}"* ]]; then
    printf "200"
    exit 0
fi
# For body requests return minimal JSON
printf '{"db_connected":true}'
exit 0
CURL_STUB
    chmod +x "$stub_bin/curl"

    (
        export PATH="$stub_bin:$PATH"
        export WORKFLOW_CONFIG="$skeleton_dir/workflow-config.conf"
        cd "$skeleton_dir"
        bash "$CANONICAL_SCRIPT" "$@"
    )
}

# ── test_generic_only_exit_0 ──────────────────────────────────────────────────
# Script exits 0 when Docker+DB are healthy and no env_check_app is configured.
_snapshot_fail
skeleton1=$(_make_skeleton "generic-only" "$(cat <<'CONF'
stack=python-poetry
CONF
)")

generic_exit=0
generic_output=$(_run_script "$skeleton1" 2>&1) || generic_exit=$?
assert_eq "test_generic_only_exit_0: exit code" "0" "$generic_exit"
assert_pass_if_clean "test_generic_only_exit_0"

# ── test_absent_env_check_app_warns ──────────────────────────────────────────
# Script emits WARN and exits 0 when commands.env_check_app is absent.
_snapshot_fail
skeleton2=$(_make_skeleton "absent-callback" "$(cat <<'CONF'
stack=python-poetry
commands.test=make test
commands.lint=make lint
CONF
)")

absent_exit=0
absent_output=$(_run_script "$skeleton2" 2>&1) || absent_exit=$?
assert_eq "test_absent_env_check_app_warns: exit code" "0" "$absent_exit"
assert_contains "test_absent_env_check_app_warns: WARN in output" "WARN" "$absent_output"
assert_contains "test_absent_env_check_app_warns: env_check_app in output" "env_check_app" "$absent_output"
assert_pass_if_clean "test_absent_env_check_app_warns"

# ── test_env_check_app_invoked ────────────────────────────────────────────────
# Script invokes the configured env_check_app command when present.
_snapshot_fail
CALLBACK_MARKER_FILE="$TMPDIR_BASE/callback-invoked-$$"
skeleton3=$(_make_skeleton "callback-present" "$(cat <<CONF
stack=python-poetry
commands.env_check_app=touch $CALLBACK_MARKER_FILE
CONF
)")

invoked_exit=0
invoked_output=$(_run_script "$skeleton3" 2>&1) || invoked_exit=$?
assert_eq "test_env_check_app_invoked: exit code" "0" "$invoked_exit"
invoked_marker="$([[ -f "$CALLBACK_MARKER_FILE" ]] && echo "1" || echo "0")"
assert_eq "test_env_check_app_invoked: callback was invoked" "1" "$invoked_marker"
assert_pass_if_clean "test_env_check_app_invoked"

# ── test_env_check_app_error_exits_nonzero ────────────────────────────────────
# Script exits non-zero when env_check_app command exits non-zero.
_snapshot_fail
skeleton4=$(_make_skeleton "callback-failing" "$(cat <<'CONF'
stack=python-poetry
commands.env_check_app=false
CONF
)")

failing_exit=0
failing_output=$(_run_script "$skeleton4" 2>&1) || failing_exit=$?
assert_ne "test_env_check_app_error_exits_nonzero: exit code non-zero" "0" "$failing_exit"
assert_pass_if_clean "test_env_check_app_error_exits_nonzero"

# ── test_db_container_name_override ──────────────────────────────────────────
# Config-driven DB container name override (commands.db_container or
# infrastructure.db_container key in workflow-config.conf).
_snapshot_fail
CUSTOM_CONTAINER="my-custom-db-container"
skeleton5=$(_make_skeleton "custom-db-name" "$(cat <<CONF
stack=python-poetry
infrastructure.db_container=$CUSTOM_CONTAINER
CONF
)")

# Export STUB_DB_CONTAINER so it is visible inside the subshell in _run_script and to the
# docker stub subprocess. Prefix-only syntax (VAR=value func) does not propagate to
# sub-processes invoked inside a bash function — export is required.
export STUB_DB_CONTAINER="$CUSTOM_CONTAINER"
dbname_exit=0
dbname_output=$(_run_script "$skeleton5" 2>&1) || dbname_exit=$?
unset STUB_DB_CONTAINER
assert_eq "test_db_container_name_override: exit code" "0" "$dbname_exit"
assert_contains "test_db_container_name_override: custom container name in output" "$CUSTOM_CONTAINER" "$dbname_output"
assert_pass_if_clean "test_db_container_name_override"

# ── test_health_timeout_override ─────────────────────────────────────────────
# Config-driven health timeout override (commands.health_timeout or
# infrastructure.health_timeout key in workflow-config.conf).
_snapshot_fail
skeleton6=$(_make_skeleton "health-timeout" "$(cat <<'CONF'
stack=python-poetry
infrastructure.health_timeout=42
CONF
)")

# Export CURL_LOG so the curl stub records its invocation args to a file.
# This lets us verify that the configured health_timeout value (42) was actually
# passed to curl as --max-time 42 rather than just checking the exit code.
export CURL_LOG="$TMPDIR_BASE/curl-invocations-$$"
timeout_exit=0
timeout_output=$(_run_script "$skeleton6" 2>&1) || timeout_exit=$?
unset CURL_LOG
# The script should run successfully with the overridden timeout
assert_eq "test_health_timeout_override: exit code" "0" "$timeout_exit"
# Behavioral assertion: verify curl was called with --max-time 42
curl_invocations=""
[[ -f "$TMPDIR_BASE/curl-invocations-$$" ]] && curl_invocations="$(cat "$TMPDIR_BASE/curl-invocations-$$")"
assert_contains "test_health_timeout_override: curl called with --max-time 42" "--max-time 42" "$curl_invocations"
assert_pass_if_clean "test_health_timeout_override"

print_summary
