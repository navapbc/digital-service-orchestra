#!/usr/bin/env bash
# tests/scripts/test-classify-epic-class.sh
# TDD tests for plugins/dso/scripts/classify-epic-class.sh
#
# Tests cover: script existence/executability, JSON output validity,
# keyword-based classification for each class, default fallback,
# and machine-readable JSON format.
#
# Usage: bash tests/scripts/test-classify-epic-class.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail
#
# RED STATE: All tests currently fail because classify-epic-class.sh does not
# yet exist. They will pass (GREEN) after the script is implemented.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRIPT="$REPO_ROOT/plugins/dso/scripts/classify-epic-class.sh"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-classify-epic-class.sh ==="

# ── Helper: build a minimal epic JSON stub ─────────────────────────────────
_make_epic_json() {
    local title="$1"
    local description="${2:-}"
    python3 -c "
import json
epic = {
    'id': 'test-epic-0001',
    'ticket_type': 'epic',
    'title': '$title',
    'description': '$description',
    'tags': [],
    'status': 'open'
}
print(json.dumps(epic))
"
}

# ── Helper: extract the 'class' field from JSON output ────────────────────
_get_class() {
    local json="$1"
    python3 -c "import sys,json; d=json.loads('$json'); print(d.get('class',''))" 2>/dev/null || echo ""
}

# ── test_script_exists ────────────────────────────────────────────────────────
# classify-epic-class.sh must exist at the expected path
test_script_exists() {
    _snapshot_fail
    if [[ -f "$SCRIPT" ]]; then
        assert_eq "test_script_exists: file found" "0" "0"
    else
        assert_eq "test_script_exists: classify-epic-class.sh must exist" "found" "not_found"
    fi
    assert_pass_if_clean "test_script_exists"
}

# ── test_script_executable ────────────────────────────────────────────────────
# classify-epic-class.sh must be executable
test_script_executable() {
    _snapshot_fail
    if [[ -x "$SCRIPT" ]]; then
        assert_eq "test_script_executable: is executable" "0" "0"
    else
        assert_eq "test_script_executable: classify-epic-class.sh must be executable" "executable" "not_executable"
    fi
    assert_pass_if_clean "test_script_executable"
}

# ── test_architectural_keywords ───────────────────────────────────────────────
# Epic with schema/migration/database keywords → class:architectural
test_architectural_keywords() {
    _snapshot_fail
    if [[ ! -x "$SCRIPT" ]]; then
        assert_eq "test_architectural_keywords: script must exist" "found" "not_found"
        assert_pass_if_clean "test_architectural_keywords"
        return
    fi

    local epic_json
    epic_json=$(_make_epic_json \
        "Add database schema migration for user entities" \
        "Requires data model changes and ORM updates for the new entity architecture")

    local output exit_code=0
    output=$(echo "$epic_json" | bash "$SCRIPT" 2>/dev/null) || exit_code=$?

    assert_eq "test_architectural_keywords: exit code 0" "0" "$exit_code"

    local class_val
    class_val=$(python3 -c "import json; d=json.loads('''$output'''); print(d.get('class',''))" 2>/dev/null || echo "")
    assert_eq "test_architectural_keywords: class is architectural" "class:architectural" "$class_val"

    assert_pass_if_clean "test_architectural_keywords"
}

# ── test_integration_keywords ─────────────────────────────────────────────────
# Epic with external API/service/webhook keywords → class:integration
test_integration_keywords() {
    _snapshot_fail
    if [[ ! -x "$SCRIPT" ]]; then
        assert_eq "test_integration_keywords: script must exist" "found" "not_found"
        assert_pass_if_clean "test_integration_keywords"
        return
    fi

    local epic_json
    epic_json=$(_make_epic_json \
        "Add third-party OAuth connector for external service" \
        "Requires webhook integration with an external API and bridge configuration")

    local output exit_code=0
    output=$(echo "$epic_json" | bash "$SCRIPT" 2>/dev/null) || exit_code=$?

    assert_eq "test_integration_keywords: exit code 0" "0" "$exit_code"

    local class_val
    class_val=$(python3 -c "import json; d=json.loads('''$output'''); print(d.get('class',''))" 2>/dev/null || echo "")
    assert_eq "test_integration_keywords: class is integration" "class:integration" "$class_val"

    assert_pass_if_clean "test_integration_keywords"
}

# ── test_infra_keywords ───────────────────────────────────────────────────────
# Epic with infrastructure/deploy/kubernetes keywords → class:infra
test_infra_keywords() {
    _snapshot_fail
    if [[ ! -x "$SCRIPT" ]]; then
        assert_eq "test_infra_keywords: script must exist" "found" "not_found"
        assert_pass_if_clean "test_infra_keywords"
        return
    fi

    local epic_json
    epic_json=$(_make_epic_json \
        "Deploy observability pipeline to kubernetes cluster" \
        "Infrastructure monitoring and container orchestration for CI/CD pipeline")

    local output exit_code=0
    output=$(echo "$epic_json" | bash "$SCRIPT" 2>/dev/null) || exit_code=$?

    assert_eq "test_infra_keywords: exit code 0" "0" "$exit_code"

    local class_val
    class_val=$(python3 -c "import json; d=json.loads('''$output'''); print(d.get('class',''))" 2>/dev/null || echo "")
    assert_eq "test_infra_keywords: class is infra" "class:infra" "$class_val"

    assert_pass_if_clean "test_infra_keywords"
}

# ── test_behavioral_keywords ──────────────────────────────────────────────────
# Epic with behavior/feature/skill/workflow/agent keywords → class:behavioral
test_behavioral_keywords() {
    _snapshot_fail
    if [[ ! -x "$SCRIPT" ]]; then
        assert_eq "test_behavioral_keywords: script must exist" "found" "not_found"
        assert_pass_if_clean "test_behavioral_keywords"
        return
    fi

    local epic_json
    epic_json=$(_make_epic_json \
        "Add new agent skill for workflow automation" \
        "Improves UX by adding a prompt-driven behavior for the brainstorm agent")

    local output exit_code=0
    output=$(echo "$epic_json" | bash "$SCRIPT" 2>/dev/null) || exit_code=$?

    assert_eq "test_behavioral_keywords: exit code 0" "0" "$exit_code"

    local class_val
    class_val=$(python3 -c "import json; d=json.loads('''$output'''); print(d.get('class',''))" 2>/dev/null || echo "")
    assert_eq "test_behavioral_keywords: class is behavioral" "class:behavioral" "$class_val"

    assert_pass_if_clean "test_behavioral_keywords"
}

# ── test_default_behavioral ───────────────────────────────────────────────────
# Epic with no recognizable keywords → class:behavioral (default)
test_default_behavioral() {
    _snapshot_fail
    if [[ ! -x "$SCRIPT" ]]; then
        assert_eq "test_default_behavioral: script must exist" "found" "not_found"
        assert_pass_if_clean "test_default_behavioral"
        return
    fi

    local epic_json
    epic_json=$(_make_epic_json \
        "Improve user experience for onboarding" \
        "Make the sign-up process faster and clearer")

    local output exit_code=0
    output=$(echo "$epic_json" | bash "$SCRIPT" 2>/dev/null) || exit_code=$?

    assert_eq "test_default_behavioral: exit code 0" "0" "$exit_code"

    local class_val
    class_val=$(python3 -c "import json; d=json.loads('''$output'''); print(d.get('class',''))" 2>/dev/null || echo "")
    assert_eq "test_default_behavioral: class defaults to behavioral" "class:behavioral" "$class_val"

    assert_pass_if_clean "test_default_behavioral"
}

# ── test_machine_readable_json_output ─────────────────────────────────────────
# Output must be valid JSON with a "class" key containing one of the 4 valid values
test_machine_readable_json_output() {
    _snapshot_fail
    if [[ ! -x "$SCRIPT" ]]; then
        assert_eq "test_machine_readable_json_output: script must exist" "found" "not_found"
        assert_pass_if_clean "test_machine_readable_json_output"
        return
    fi

    local epic_json
    epic_json=$(_make_epic_json \
        "Add database schema migration" \
        "Requires schema changes and ADR documentation")

    local output exit_code=0
    output=$(echo "$epic_json" | bash "$SCRIPT" 2>/dev/null) || exit_code=$?

    assert_eq "test_machine_readable_json_output: exit code 0" "0" "$exit_code"

    # Output must be valid JSON parseable by python3
    local is_valid_json
    is_valid_json=$(python3 -c "import json; json.loads('''$output'''); print('valid')" 2>/dev/null || echo "invalid")
    assert_eq "test_machine_readable_json_output: output is valid JSON" "valid" "$is_valid_json"

    # Must have exactly the 'class' key with one of the valid enum values
    local class_val
    class_val=$(python3 -c "import json; d=json.loads('''$output'''); print(d.get('class','missing'))" 2>/dev/null || echo "missing")
    local is_valid_class="no"
    case "$class_val" in
        "class:architectural"|"class:integration"|"class:infra"|"class:behavioral")
            is_valid_class="yes"
            ;;
    esac
    assert_eq "test_machine_readable_json_output: class is a valid enum value" "yes" "$is_valid_class"

    assert_pass_if_clean "test_machine_readable_json_output"
}

# ── test_always_exits_zero ────────────────────────────────────────────────────
# Script must always exit 0, even with unusual input
test_always_exits_zero() {
    _snapshot_fail
    if [[ ! -x "$SCRIPT" ]]; then
        assert_eq "test_always_exits_zero: script must exist" "found" "not_found"
        assert_pass_if_clean "test_always_exits_zero"
        return
    fi

    local exit_code=0
    echo '{}' | bash "$SCRIPT" >/dev/null 2>&1 || exit_code=$?
    assert_eq "test_always_exits_zero: exits 0 on empty JSON" "0" "$exit_code"

    exit_code=0
    echo '' | bash "$SCRIPT" >/dev/null 2>&1 || exit_code=$?
    assert_eq "test_always_exits_zero: exits 0 on empty stdin" "0" "$exit_code"

    assert_pass_if_clean "test_always_exits_zero"
}

# ── Run all tests ─────────────────────────────────────────────────────────────
test_script_exists
test_script_executable
test_architectural_keywords
test_integration_keywords
test_infra_keywords
test_behavioral_keywords
test_default_behavioral
test_machine_readable_json_output
test_always_exits_zero

print_summary
