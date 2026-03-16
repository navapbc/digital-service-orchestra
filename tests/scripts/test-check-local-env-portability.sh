#!/usr/bin/env bash
# tests/scripts/test-check-local-env-portability.sh
# Portability smoke test: verifies the generic check-local-env.sh works with
# no env_check_app configured (i.e., no project-specific callback).
#
# Core contract: when commands.env_check_app is absent from workflow-config.conf,
# the script must:
#   1. Exit 0 (healthy environment)
#   2. Emit a WARN about env_check_app being skipped
#   3. Not error out because the callback is missing
#
# All Docker/DB/pg_isready calls are intercepted via stub binaries injected into
# PATH so this test runs without a real Docker daemon or database.
#
# Usage: bash tests/scripts/test-check-local-env-portability.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

# REVIEW-DEFENSE: '-e' is intentionally omitted. The test harness captures
# non-zero exit codes from _run_script via || assignment. With '-e', expected
# non-zero exits would abort the script before assertions run.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR" && git rev-parse --show-toplevel)"
CANONICAL_SCRIPT="$PLUGIN_ROOT/scripts/check-local-env.sh"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-check-local-env-portability.sh ==="

# ── Setup: shared temp environment ───────────────────────────────────────────
TMPDIR_BASE="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_BASE"' EXIT

# Helper: create a minimal project skeleton with the given workflow-config.conf content.
# Mirrors the pattern from test-check-local-env-generic.sh.
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

# Helper: run the canonical script inside a skeleton directory with all docker/db
# calls replaced by stub binaries injected at the front of PATH.
# This ensures the test runs without a real Docker daemon or Postgres instance.
_run_script() {
    local skeleton_dir="$1"; shift
    # Remaining args are passed to the canonical script.

    # Create a unique stub bin dir for each invocation.
    # NOTE: _run_script is called via command substitution $(...), so $$ refers
    # to the subshell PID — each call gets a distinct directory automatically.
    local stub_bin="$TMPDIR_BASE/stub-bin-$$"
    rm -rf "$stub_bin"
    mkdir -p "$stub_bin"

    # stub docker: simulate a healthy daemon and running DB container
    cat > "$stub_bin/docker" <<'DOCKER_STUB'
#!/usr/bin/env bash
case "$*" in
    info*)       exit 0 ;;
    "ps --format"*)
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

    # stub pg_isready: always reports Postgres as ready
    cat > "$stub_bin/pg_isready" <<'PG_STUB'
#!/usr/bin/env bash
exit 0
PG_STUB
    chmod +x "$stub_bin/pg_isready"

    # stub curl: return 200 for health endpoint requests
    cat > "$stub_bin/curl" <<'CURL_STUB'
#!/usr/bin/env bash
if [[ "$*" == *"-w"* && "$*" == *"%{http_code}"* ]]; then
    printf "200"
    exit 0
fi
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

# ── test_no_env_check_app_exits_zero ─────────────────────────────────────────
# When no commands.env_check_app key is present in workflow-config.conf, the
# script must exit 0 (healthy) rather than failing or erroring.
_snapshot_fail
portability_skeleton=$(_make_skeleton "portability-no-callback" "$(cat <<'CONF'
stack=python-poetry
CONF
)")

portability_exit=0
portability_output=$(_run_script "$portability_skeleton" 2>&1) || portability_exit=$?
assert_eq "test_no_env_check_app_exits_zero: exit code" "0" "$portability_exit"
assert_pass_if_clean "test_no_env_check_app_exits_zero"

# ── test_no_env_check_app_emits_warn ─────────────────────────────────────────
# When no commands.env_check_app key is present, the script must emit a WARN
# message informing the user that project-specific checks were skipped.
# This verifies the portability contract: absent callback = warn, not error.
_snapshot_fail
assert_contains "test_no_env_check_app_emits_warn: WARN in output" "WARN" "$portability_output"
assert_contains "test_no_env_check_app_emits_warn: env_check_app in output" "env_check_app" "$portability_output"
assert_pass_if_clean "test_no_env_check_app_emits_warn"

# ── test_commands_section_no_env_check_app_exits_zero ────────────────────────
# When a commands section exists but env_check_app key is absent, the script
# must still exit 0 (no error because callback is missing).
_snapshot_fail
partial_commands_skeleton=$(_make_skeleton "portability-partial-commands" "$(cat <<'CONF'
stack=python-poetry
commands.test=make test
commands.lint=make lint
CONF
)")

partial_exit=0
partial_output=$(_run_script "$partial_commands_skeleton" 2>&1) || partial_exit=$?
assert_eq "test_commands_section_no_env_check_app_exits_zero: exit code" "0" "$partial_exit"
assert_contains "test_commands_section_no_env_check_app_exits_zero: WARN in output" "WARN" "$partial_output"
assert_pass_if_clean "test_commands_section_no_env_check_app_exits_zero"

print_summary
