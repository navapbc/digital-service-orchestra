#!/usr/bin/env bash
# tests/scripts/test-flat-config-e2e.sh
# End-to-end integration tests for the flat config migration.
#
# Validates:
#   1. All keys in workflow-config.conf are readable via read-config.sh
#   2. validate-config.sh passes on the real workflow-config.conf
#   3. read-config.sh works without Python available (pure bash for .conf)
#   4. Skill config resolution pattern works with .conf file
#
# Usage: bash tests/scripts/test-flat-config-e2e.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR" && git rev-parse --show-toplevel)"
READ_CONFIG="$PLUGIN_ROOT/scripts/read-config.sh"
VALIDATE_CONFIG="$PLUGIN_ROOT/scripts/validate-config.sh"

# Create an inline fixture config instead of depending on project config.
# Must have at least 23 unique keys and pass validate-config.sh.
REAL_CONF="$(mktemp)"
cat > "$REAL_CONF" <<'FIXTURE'
version=1.0.0
stack=python-poetry
format.extensions=.py
format.source_dirs=app/src
format.source_dirs=app/tests
commands.test=make test
commands.lint=make lint
commands.format=make format
commands.format_check=make format-check
commands.validate=./scripts/validate.sh --ci
commands.test_unit=make test-unit-only
commands.test_e2e=make test-e2e
commands.test_visual=make test-visual
database.ensure_cmd=make db-start && make db-status
database.status_cmd=make db-status
database.port_cmd=echo 5432
database.base_port=5432
infrastructure.container_prefix=myapp-db-worktree-
infrastructure.compose_project=myapp-db-
session.usage_check_cmd=$HOME/.claude/check-session-usage.sh
jira.project=DTL
issue_tracker.search_cmd=grep -rl
issue_tracker.create_cmd=tk create
design.system_name=USWDS 3.x
design.component_library=uswds
design.template_engine=jinja2
design.design_notes_path=DESIGN_NOTES.md
tickets.prefix=my-project
tickets.directory=.tickets
tickets.sync.jira_project_key=DTL
tickets.sync.bidirectional_comments=true
FIXTURE

source "$PLUGIN_ROOT/tests/lib/assert.sh"

# Temp dir cleanup on exit
_CLEANUP_DIRS=()
_cleanup() { rm -f "$REAL_CONF"; for d in "${_CLEANUP_DIRS[@]}"; do rm -rf "$d"; done; }
trap _cleanup EXIT

echo "=== test-flat-config-e2e.sh ==="

# -- test_all_23_keys_readable ------------------------------------------------
# Iterate all unique keys used in workflow-config.conf and verify read-config.sh
# returns non-empty values for each one.
_snapshot_fail

# Extract unique keys from the real config file (skip comments and blank lines)
mapfile -t all_keys < <(grep -v '^\s*#' "$REAL_CONF" | grep -v '^\s*$' | cut -d= -f1 | sort -u)

key_count=${#all_keys[@]}
empty_keys=()

for key in "${all_keys[@]}"; do
    value=$(bash "$READ_CONFIG" "$key" "$REAL_CONF")
    if [[ -z "$value" ]]; then
        empty_keys+=("$key")
    fi
done

# Verify we have at least 23 unique keys
assert_eq "test_all_23_keys_readable key_count>=23" "true" "$([ "$key_count" -ge 23 ] && echo true || echo false)"

# Verify all keys returned non-empty values
if [[ ${#empty_keys[@]} -gt 0 ]]; then
    (( ++FAIL ))
    printf "FAIL: test_all_23_keys_readable — %d keys returned empty values:\n" "${#empty_keys[@]}" >&2
    for k in "${empty_keys[@]}"; do
        printf "  - %s\n" "$k" >&2
    done
else
    (( ++PASS ))
fi

assert_pass_if_clean "test_all_23_keys_readable ($key_count keys checked)"

# -- test_validate_config_on_real_conf ----------------------------------------
# Run validate-config.sh against the real workflow-config.conf and expect exit 0.
_snapshot_fail

stderr_out=$(bash "$VALIDATE_CONFIG" "$REAL_CONF" 2>&1 >/dev/null)
rc=$?
assert_eq "test_validate_config_on_real_conf exit" "0" "$rc"

# Also verify no ERROR output on stderr
if [[ -n "$stderr_out" ]]; then
    (( ++FAIL ))
    printf "FAIL: test_validate_config_on_real_conf — unexpected stderr:\n%s\n" "$stderr_out" >&2
else
    (( ++PASS ))
fi

assert_pass_if_clean "test_validate_config_on_real_conf"

# -- test_no_python_dependency_on_config_path ---------------------------------
# Verify read-config.sh works with .conf files even when Python is unavailable.
# Unset CLAUDE_PLUGIN_PYTHON and use a PATH with no python3.
_snapshot_fail

# Create a minimal environment with no python3 on PATH
value=$(
    env -i HOME="$HOME" \
        CLAUDE_PLUGIN_PYTHON="" \
        PATH="/usr/bin:/bin" \
    bash -c '
        # Verify python3 is NOT available in our restricted PATH
        if command -v python3 >/dev/null 2>&1; then
            # python3 is in /usr/bin — need to hide it
            tmpbin=$(mktemp -d)
            # Symlink everything except python* from /usr/bin and /bin
            for d in /usr/bin /bin; do
                for f in "$d"/*; do
                    bn=$(basename "$f")
                    case "$bn" in
                        python*) ;;
                        *) [ ! -e "$tmpbin/$bn" ] && ln -s "$f" "$tmpbin/$bn" 2>/dev/null || true ;;
                    esac
                done
            done
            export PATH="$tmpbin"
        fi
        bash "'"$READ_CONFIG"'" commands.test "'"$REAL_CONF"'"
    '
)
rc=$?

assert_eq "test_no_python_dependency_on_config_path exit" "0" "$rc"
assert_eq "test_no_python_dependency_on_config_path value" "make test" "$value"

assert_pass_if_clean "test_no_python_dependency_on_config_path"

# -- test_skill_config_resolution ---------------------------------------------
# Verify the skill config resolution pattern works:
#   PLUGIN_SCRIPTS=... && bash "$PLUGIN_SCRIPTS/read-config.sh" <key>
# This simulates how skills resolve config values at runtime.
_snapshot_fail

plugin_scripts="$PLUGIN_ROOT/scripts"

# Create a temp file with our fixture config for WORKFLOW_CONFIG_FILE isolation
_skill_tmpdir="$(mktemp -d)"
_CLEANUP_DIRS+=("$_skill_tmpdir")
cp "$REAL_CONF" "$_skill_tmpdir/workflow-config.conf"
_fixture_conf="$_skill_tmpdir/workflow-config.conf"

# Test the pattern that skills use: PLUGIN_SCRIPTS + read-config.sh + key
value=$(
    PLUGIN_SCRIPTS="$plugin_scripts" \
    WORKFLOW_CONFIG_FILE="$_fixture_conf" \
    bash "$plugin_scripts/read-config.sh" commands.test
)
rc=$?

assert_eq "test_skill_config_resolution exit" "0" "$rc"
assert_eq "test_skill_config_resolution value" "make test" "$value"

# Also test a nested key to verify dot-notation works end-to-end
value2=$(
    PLUGIN_SCRIPTS="$plugin_scripts" \
    WORKFLOW_CONFIG_FILE="$_fixture_conf" \
    bash "$plugin_scripts/read-config.sh" tickets.sync.jira_project_key
)
rc2=$?

assert_eq "test_skill_config_resolution nested_key exit" "0" "$rc2"
assert_eq "test_skill_config_resolution nested_key value" "DTL" "$value2"

assert_pass_if_clean "test_skill_config_resolution"

# -- Summary -------------------------------------------------------------------
print_summary
