#!/usr/bin/env bash
# tests/scripts/test-format-recipe-result.sh
# RED-phase tests for plugins/dso/scripts/sprint/format-recipe-result.sh.
#
# The script under test does NOT exist yet; all tests must FAIL.
#
# Usage: bash tests/scripts/test-format-recipe-result.sh
# Returns: exit 1 (all tests fail — RED phase)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR" && git rev-parse --show-toplevel)"

source "$REPO_ROOT/tests/lib/assert.sh"

SCRIPT_UNDER_TEST="$REPO_ROOT/plugins/dso/scripts/sprint/format-recipe-result.sh"

echo "=== test-format-recipe-result.sh ==="
echo "Script: $SCRIPT_UNDER_TEST"
echo ""

# ── (a) Success case ──────────────────────────────────────────────────────────
# exit_code=0, 2 transforms_applied, files_changed=["src/api.py","src/models.py"]
# Summary must contain: recipe name, SUCCESS status, both file names, transform count (2)

output_success=""
output_success="$(echo '{"exit_code":0,"transforms_applied":2,"files_changed":["src/api.py","src/models.py"],"errors":[],"degraded":false,"engine_name":"ast-grep"}' \
    | bash "$SCRIPT_UNDER_TEST" "add-parameter" 2>/dev/null)" || true

assert_contains \
    "success: recipe name present" \
    "add-parameter" \
    "$output_success"

assert_contains \
    "success: SUCCESS status present" \
    "SUCCESS" \
    "$output_success"

assert_contains \
    "success: first changed file present" \
    "src/api.py" \
    "$output_success"

assert_contains \
    "success: second changed file present" \
    "src/models.py" \
    "$output_success"

assert_contains \
    "success: transform count present" \
    "2" \
    "$output_success"

# ── (b) Failure case ─────────────────────────────────────────────────────────
# exit_code=1, errors=["function 'process_request' not found","signature mismatch"]
# Summary must contain: FAILED status, error messages, mention of git stash snapshot

output_failure=""
output_failure="$(echo '{"exit_code":1,"transforms_applied":0,"files_changed":[],"errors":["function '\''process_request'\'' not found","signature mismatch"],"degraded":false,"engine_name":"ast-grep"}' \
    | bash "$SCRIPT_UNDER_TEST" "add-parameter" 2>/dev/null)" || true

assert_contains \
    "failure: FAILED status present" \
    "FAILED" \
    "$output_failure"

assert_contains \
    "failure: first error message present" \
    "process_request" \
    "$output_failure"

assert_contains \
    "failure: second error message present" \
    "signature mismatch" \
    "$output_failure"

assert_contains \
    "failure: git stash snapshot mention present" \
    "stash" \
    "$output_failure"

# ── (c) Degraded case ────────────────────────────────────────────────────────
# exit_code=0, degraded=true, engine_name="ast-grep-fallback", 1 transforms_applied
# Summary must contain: DEGRADED label, engine name

output_degraded=""
output_degraded="$(echo '{"exit_code":0,"transforms_applied":1,"files_changed":["src/utils.py"],"errors":[],"degraded":true,"engine_name":"ast-grep-fallback"}' \
    | bash "$SCRIPT_UNDER_TEST" "add-parameter" 2>/dev/null)" || true

assert_contains \
    "degraded: DEGRADED label present" \
    "DEGRADED" \
    "$output_degraded"

assert_contains \
    "degraded: engine name present" \
    "ast-grep-fallback" \
    "$output_degraded"

# ── (d) Invalid JSON input ────────────────────────────────────────────────────
# Non-JSON string on stdin — script must exit non-zero, stderr must be non-empty

exit_code_invalid=0
stderr_invalid=""
stderr_invalid="$(echo 'this is not json at all' \
    | bash "$SCRIPT_UNDER_TEST" "add-parameter" 2>&1 >/dev/null)" \
    || exit_code_invalid=$?

assert_ne \
    "invalid_json: exits non-zero" \
    "0" \
    "$exit_code_invalid"

assert_ne \
    "invalid_json: stderr is non-empty" \
    "" \
    "$stderr_invalid"

# ── (e) Zero-file success ─────────────────────────────────────────────────────
# exit_code=0, transforms_applied=0, files_changed=[]
# Summary must contain SUCCESS; must NOT contain "null" or "None"

output_zero=""
output_zero="$(echo '{"exit_code":0,"transforms_applied":0,"files_changed":[],"errors":[],"degraded":false,"engine_name":"ast-grep"}' \
    | bash "$SCRIPT_UNDER_TEST" "add-parameter" 2>/dev/null)" || true

assert_contains \
    "zero_files: SUCCESS status present" \
    "SUCCESS" \
    "$output_zero"

assert_not_contains \
    "zero_files: output does not contain null" \
    "null" \
    "$output_zero"

assert_not_contains \
    "zero_files: output does not contain None" \
    "None" \
    "$output_zero"

print_summary
