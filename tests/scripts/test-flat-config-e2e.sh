#!/usr/bin/env bash
# lockpick-workflow/tests/scripts/test-flat-config-e2e.sh
# End-to-end integration tests for the flat config migration.
#
# Validates:
#   1. All keys in workflow-config.conf are readable via read-config.sh
#   2. validate-config.sh passes on the real workflow-config.conf
#   3. read-config.sh works without Python available (pure bash for .conf)
#   4. Skill config resolution pattern works with .conf file
#
# Usage: bash lockpick-workflow/tests/scripts/test-flat-config-e2e.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
READ_CONFIG="$REPO_ROOT/lockpick-workflow/scripts/read-config.sh"
VALIDATE_CONFIG="$REPO_ROOT/lockpick-workflow/scripts/validate-config.sh"
REAL_CONF="$REPO_ROOT/workflow-config.conf"

source "$REPO_ROOT/lockpick-workflow/tests/lib/assert.sh"

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

plugin_scripts="$REPO_ROOT/lockpick-workflow/scripts"

# Test the pattern that skills use: PLUGIN_SCRIPTS + read-config.sh + key
value=$(
    PLUGIN_SCRIPTS="$plugin_scripts" \
    CLAUDE_PLUGIN_ROOT="$REPO_ROOT" \
    bash "$plugin_scripts/read-config.sh" commands.test
)
rc=$?

assert_eq "test_skill_config_resolution exit" "0" "$rc"
assert_eq "test_skill_config_resolution value" "make test" "$value"

# Also test a nested key to verify dot-notation works end-to-end
value2=$(
    PLUGIN_SCRIPTS="$plugin_scripts" \
    CLAUDE_PLUGIN_ROOT="$REPO_ROOT" \
    bash "$plugin_scripts/read-config.sh" tickets.sync.jira_project_key
)
rc2=$?

assert_eq "test_skill_config_resolution nested_key exit" "0" "$rc2"
assert_eq "test_skill_config_resolution nested_key value" "DTL" "$value2"

assert_pass_if_clean "test_skill_config_resolution"

# -- Summary -------------------------------------------------------------------
print_summary
