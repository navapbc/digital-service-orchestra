#!/usr/bin/env bash
# tests/evals/run-evals.sh
# Eval runner: processes evals.json manifest and evaluates each suite entry.
#
# Usage: bash run-evals.sh [path/to/evals.json]
#   Defaults to evals.json in the same directory as this script.
#
# Exit codes:
#   0 — all entries passed
#   1 — one or more entries failed or runner error
#
# Assertion types supported (Phase 0):
#   exit_code           — compare actual exit code to expected
#   stdout_contains     — grep for expected string in stdout
#   stdout_not_contains — grep negation in stdout
#   stderr_empty        — verify stderr is empty string
#   file_exists         — verify a file exists at path (resolved from REPO_ROOT)
#
# Assertion types supported (Phase 2):
#   file_contains       — verify a file contains a pattern string (grep -qF)

set -euo pipefail

# Temp dir cleanup on exit
_CLEANUP_DIRS=()
_cleanup() { for d in "${_CLEANUP_DIRS[@]}"; do rm -rf "$d"; done; }
trap _cleanup EXIT

# --- Dependency check ---
if ! command -v jq &>/dev/null; then
    echo "ERROR: jq is required but not found. Install jq and retry." >&2
    exit 1
fi

# --- Paths ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Resolve REPO_ROOT: walk up from SCRIPT_DIR to find the git root.
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || true)"
if [[ -z "$REPO_ROOT" ]]; then
    # Fallback: assume script is at tests/evals/ inside the repo
    REPO_ROOT="$(cd "$SCRIPT_DIR" && git rev-parse --show-toplevel)"
fi

# evals.json path: first arg or default
EVALS_JSON="${1:-$SCRIPT_DIR/evals.json}"

if [[ ! -f "$EVALS_JSON" ]]; then
    echo "ERROR: evals.json not found at: $EVALS_JSON" >&2
    exit 1
fi

# --- Counters ---
TOTAL=0
PASSED=0
FAILED=0

# --- Process each suite entry ---
entry_count=$(jq '.suites | length' "$EVALS_JSON")

for i in $(seq 0 $(( entry_count - 1 ))); do
    entry=$(jq -c ".suites[$i]" "$EVALS_JSON")

    id=$(echo "$entry" | jq -r '.id')
    category=$(echo "$entry" | jq -r '.category')

    TOTAL=$(( TOTAL + 1 ))
    entry_pass=true

    # --- Handle skill-activation (file_exists) category ---
    # For skill-activation entries, assertions are all file_exists type.
    # No hook execution needed.

    # Set up environment variables from setup.env
    while IFS= read -r env_pair; do
        key=$(echo "$env_pair" | jq -r '.key')
        val=$(echo "$env_pair" | jq -r '.value')
        export "$key"="$val"
    done < <(echo "$entry" | jq -c '.setup.env // {} | to_entries[]' 2>/dev/null || true)

    # Write state files if provided (into a temp dir for test isolation)
    state_file_count=$(echo "$entry" | jq '.setup.state_files // {} | length')
    if [[ "$state_file_count" -gt 0 ]]; then
        _state_tmp=$(mktemp -d "${TMPDIR:-/tmp}/evals-state-XXXXXX")
        _CLEANUP_DIRS+=("$_state_tmp")
        while IFS= read -r sf_pair; do
            sf_path=$(echo "$sf_pair" | jq -r '.key')
            sf_content=$(echo "$sf_pair" | jq -r '.value')
            # Resolve relative paths into temp dir to avoid worktree writes
            if [[ "$sf_path" != /* ]]; then
                sf_path="$_state_tmp/$sf_path"
            fi
            sf_dir=$(dirname "$sf_path")
            mkdir -p "$sf_dir"
            printf '%s' "$sf_content" > "$sf_path"
        done < <(echo "$entry" | jq -c '.setup.state_files | to_entries[]')
    fi

    # Determine if this entry needs hook execution (non-file_exists/file_contains assertions present)
    needs_execution=false
    hook_assertion_count=$(echo "$entry" | jq '[.assertions[] | select(.type != "file_exists" and .type != "file_contains")] | length')
    if [[ "$hook_assertion_count" -gt 0 ]]; then
        needs_execution=true
    fi

    # Execute hook if needed
    actual_stdout=""
    actual_stderr=""
    actual_exit_code=0

    if [[ "$needs_execution" == "true" ]]; then
        hook_rel=$(echo "$entry" | jq -r '.hook')
        hook_path="$REPO_ROOT/$hook_rel"

        stdin_val=$(echo "$entry" | jq -r '.setup.stdin // ""')

        # Run hook, capturing stdout, stderr, exit code
        tmp_stderr=$(mktemp)
        _CLEANUP_DIRS+=("$tmp_stderr")
        set +e
        actual_stdout=$(printf '%s' "$stdin_val" | bash "$hook_path" 2>"$tmp_stderr")
        actual_exit_code=$?
        set -e
        actual_stderr=$(cat "$tmp_stderr")
        rm -f "$tmp_stderr"
    fi

    # --- Evaluate assertions ---
    assertion_count=$(echo "$entry" | jq '.assertions | length')
    for j in $(seq 0 $(( assertion_count - 1 ))); do
        assertion=$(echo "$entry" | jq -c ".assertions[$j]")
        atype=$(echo "$assertion" | jq -r '.type')

        case "$atype" in
            file_exists)
                file_path=$(echo "$assertion" | jq -r '.path')
                full_path="$REPO_ROOT/$file_path"
                if [[ ! -f "$full_path" ]]; then
                    echo "  FAIL [$id]: file_exists: $file_path — not found at $full_path" >&2
                    entry_pass=false
                fi
                ;;
            file_contains)
                file_path=$(echo "$assertion" | jq -r '.path')
                pattern=$(echo "$assertion" | jq -r '.pattern')
                full_path="$REPO_ROOT/$file_path"
                if [[ ! -f "$full_path" ]]; then
                    echo "  FAIL [$id]: file_contains: $file_path — file not found at $full_path" >&2
                    entry_pass=false
                elif ! grep -qF "$pattern" "$full_path"; then
                    echo "  FAIL [$id]: file_contains: $file_path — pattern '$pattern' not found" >&2
                    entry_pass=false
                fi
                ;;
            exit_code)
                expected_code=$(echo "$assertion" | jq -r '.expected')
                if [[ "$actual_exit_code" != "$expected_code" ]]; then
                    echo "  FAIL [$id]: exit_code: expected=$expected_code actual=$actual_exit_code" >&2
                    entry_pass=false
                fi
                ;;
            stdout_contains)
                expected_str=$(echo "$assertion" | jq -r '.expected')
                if ! echo "$actual_stdout" | grep -qF "$expected_str"; then
                    echo "  FAIL [$id]: stdout_contains: expected to contain '$expected_str'" >&2
                    entry_pass=false
                fi
                ;;
            stdout_not_contains)
                unexpected_str=$(echo "$assertion" | jq -r '.expected')
                if echo "$actual_stdout" | grep -qF "$unexpected_str"; then
                    echo "  FAIL [$id]: stdout_not_contains: expected NOT to contain '$unexpected_str'" >&2
                    entry_pass=false
                fi
                ;;
            stderr_empty)
                if [[ -n "$actual_stderr" ]]; then
                    echo "  FAIL [$id]: stderr_empty: stderr was not empty: $actual_stderr" >&2
                    entry_pass=false
                fi
                ;;
            *)
                echo "  WARN [$id]: unknown assertion type '$atype' — skipping" >&2
                ;;
        esac
    done

    # --- Print result ---
    if [[ "$entry_pass" == "true" ]]; then
        echo "PASS [$id]"
        PASSED=$(( PASSED + 1 ))
    else
        echo "FAIL [$id]"
        FAILED=$(( FAILED + 1 ))
    fi
done

# --- Summary ---
echo ""
echo "Results: $PASSED passed, $FAILED failed (total: $TOTAL)"

if [[ "$FAILED" -gt 0 ]]; then
    exit 1
fi

exit 0
