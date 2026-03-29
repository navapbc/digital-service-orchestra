#!/usr/bin/env bash
# tests/scripts/test-check-local-env-docker-skip.sh
# TDD tests for graceful Docker/DB skip behavior in check-local-env.sh.
#
# Tests cover:
#   1. Docker CLI absent + no Docker config => zero error output, exit 0
#   2. Docker available but infrastructure.db_container not set => DB check skipped
#   3. Docker available + infrastructure.db_container set => DB check runs normally
#
# Usage: bash tests/scripts/test-check-local-env-docker-skip.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

# REVIEW-DEFENSE: '-e' is intentionally omitted. The test harness captures
# non-zero exit codes from _run_script via || assignment. With '-e', expected
# non-zero exits would abort the script before assertions run.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
REPO_ROOT="$(cd "$SCRIPT_DIR" && git rev-parse --show-toplevel)"
CANONICAL_SCRIPT="$DSO_PLUGIN_DIR/scripts/check-local-env.sh"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-check-local-env-docker-skip.sh ==="

# ── Setup: shared temp environment ───────────────────────────────────────────
TMPDIR_BASE="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_BASE"' EXIT

# Helper: create a minimal project skeleton with the given dso-config.conf content
_make_skeleton() {
    local name="$1" config_content="$2"
    local dir="$TMPDIR_BASE/$name"
    mkdir -p "$dir" || { echo "ERROR: mkdir failed for $dir" >&2; exit 1; }
    git init -q -b main "$dir" || { echo "ERROR: git init failed for $dir" >&2; exit 1; }
    git -C "$dir" config user.email "test@example.com" || { echo "ERROR: git config email failed for $dir" >&2; exit 1; }
    git -C "$dir" config user.name "Test User" || { echo "ERROR: git config name failed for $dir" >&2; exit 1; }
    GIT_AUTHOR_NAME="Test User" GIT_AUTHOR_EMAIL="test@example.com" \
    GIT_COMMITTER_NAME="Test User" GIT_COMMITTER_EMAIL="test@example.com" \
    git -C "$dir" commit --allow-empty -m "init" -q || { echo "ERROR: git commit failed for $dir" >&2; exit 1; }
    printf '%s\n' "$config_content" > "$dir/dso-config.conf" || { echo "ERROR: failed to write dso-config.conf in $dir" >&2; exit 1; }
    echo "$dir"
}

# Helper: run the canonical script inside a skeleton directory.
# When NO_DOCKER=1 is set, docker is NOT added to the stub PATH (simulates absent CLI).
# When NO_DOCKER is unset, docker stub is available.
_run_script() {
    local skeleton_dir="$1"; shift
    local no_docker="${NO_DOCKER:-}"

    local stub_bin="$TMPDIR_BASE/stub-bin-$$"
    rm -rf "$stub_bin"
    mkdir -p "$stub_bin"

    if [[ -z "$no_docker" ]]; then
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
    fi

    # stub pg_isready: always reports ready
    cat > "$stub_bin/pg_isready" <<'PG_STUB'
#!/usr/bin/env bash
exit 0
PG_STUB
    chmod +x "$stub_bin/pg_isready"

    # stub curl: return 200 for health endpoint
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

    if [[ -n "$no_docker" ]]; then
        # Create shadow dirs that symlink everything EXCEPT docker from dirs that have it
        local shadow_base="$TMPDIR_BASE/shadow-$$"
        rm -rf "$shadow_base"
        local filtered_path=""
        local IFS=:
        for _p in $PATH; do
            if [[ -x "$_p/docker" ]]; then
                local shadow_dir="$shadow_base/${_p//\//_}"
                mkdir -p "$shadow_dir"
                for f in "$_p"/*; do
                    local fname
                    fname="$(basename "$f")"
                    [[ "$fname" == "docker" ]] && continue
                    ln -sf "$f" "$shadow_dir/$fname" 2>/dev/null || true
                done
                filtered_path="${filtered_path:+$filtered_path:}$shadow_dir"
            else
                filtered_path="${filtered_path:+$filtered_path:}$_p"
            fi
        done
    else
        local filtered_path="$PATH"
    fi

    (
        export PATH="$stub_bin:$filtered_path"
        export WORKFLOW_CONFIG="$skeleton_dir/dso-config.conf"
        cd "$skeleton_dir"
        bash "$CANONICAL_SCRIPT" "$@"
    )
}

# ── test_docker_skip_when_cli_absent ─────────────────────────────────────────
# When docker CLI is not in PATH and no Docker config is set, the script should
# produce zero error output and exit 0.
_snapshot_fail
skeleton_no_docker=$(_make_skeleton "no-docker" "$(cat <<'CONF'
stack=python-poetry
CONF
)")

no_docker_exit=0
no_docker_stderr=""
# Capture stderr separately to assert zero error output
no_docker_stderr=$(NO_DOCKER=1 _run_script "$skeleton_no_docker" --quiet 2>&1 >/dev/null) || true
no_docker_exit=0
NO_DOCKER=1 _run_script "$skeleton_no_docker" --quiet >/dev/null 2>/dev/null || no_docker_exit=$?
assert_eq "test_docker_skip_when_cli_absent: exit code" "0" "$no_docker_exit"
assert_eq "test_docker_skip_when_cli_absent: zero stderr" "" "$no_docker_stderr"
assert_pass_if_clean "test_docker_skip_when_cli_absent"

# ── test_db_container_skip_when_unconfigured ─────────────────────────────────
# When Docker is available but infrastructure.db_container is NOT set in config,
# the DB container check should be skipped (no failure about missing container).
_snapshot_fail
skeleton_no_db_config=$(_make_skeleton "no-db-config" "$(cat <<'CONF'
stack=python-poetry
CONF
)")

no_db_exit=0
no_db_output=$(_run_script "$skeleton_no_db_config" 2>&1) || no_db_exit=$?
assert_eq "test_db_container_skip_when_unconfigured: exit code" "0" "$no_db_exit"
# Should NOT contain the "No Postgres container found" failure message
no_db_has_failure="0"
echo "$no_db_output" | grep -q "No Postgres container found" && no_db_has_failure="1"
assert_eq "test_db_container_skip_when_unconfigured: no postgres failure" "0" "$no_db_has_failure"
assert_pass_if_clean "test_db_container_skip_when_unconfigured"

# ── test_db_container_check_when_configured ──────────────────────────────────
# When Docker is available AND infrastructure.db_container is set in config,
# the DB container check should run normally.
_snapshot_fail
CUSTOM_CONTAINER="my-test-postgres"
skeleton_db_configured=$(_make_skeleton "db-configured" "$(cat <<CONF
stack=python-poetry
infrastructure.db_container=$CUSTOM_CONTAINER
CONF
)")

export STUB_DB_CONTAINER="$CUSTOM_CONTAINER"
db_configured_exit=0
db_configured_output=$(_run_script "$skeleton_db_configured" 2>&1) || db_configured_exit=$?
unset STUB_DB_CONTAINER
assert_eq "test_db_container_check_when_configured: exit code" "0" "$db_configured_exit"
assert_contains "test_db_container_check_when_configured: container name in output" "$CUSTOM_CONTAINER" "$db_configured_output"
assert_pass_if_clean "test_db_container_check_when_configured"

print_summary
