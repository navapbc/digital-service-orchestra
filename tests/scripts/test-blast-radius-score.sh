#!/usr/bin/env bash
# tests/scripts/test-blast-radius-score.sh
# TDD tests for plugins/dso/scripts/blast-radius-score.py
#
# Tests cover: script existence/executability, JSON output validity,
# scoring behavior, output field correctness, and cross-stack fixtures
# (Go/kubernetes-style, TypeScript/next.js-style, Python/pyproject-style,
# Rust/cargo-style).
#
# Usage: bash tests/scripts/test-blast-radius-score.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail
#
# RED STATE: All tests currently fail because blast-radius-score.py does not
# yet exist. They will pass (GREEN) after the script is implemented.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRIPT="$PLUGIN_ROOT/plugins/dso/scripts/blast-radius-score.py"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

# Temp dir cleanup on exit
_CLEANUP_DIRS=()
_cleanup() { for d in "${_CLEANUP_DIRS[@]}"; do rm -rf "$d"; done; }
trap _cleanup EXIT

echo "=== test-blast-radius-score.sh ==="

# ── Helper: parse a JSON field from output ────────────────────────────────────
_get_field() {
    local json="$1" field="$2"
    python3 -c "import sys,json; d=json.loads(sys.stdin.read()); print(d.get('$field',''))" <<< "$json" 2>/dev/null || echo ""
}

# ── test_script_exists ────────────────────────────────────────────────────────
# blast-radius-score.py must exist at the expected path
test_script_exists() {
    _snapshot_fail
    if [[ -f "$SCRIPT" ]]; then
        assert_eq "test_script_exists: file found" "0" "0"
    else
        assert_eq "test_script_exists: blast-radius-score.py must exist" "found" "not_found"
    fi
    assert_pass_if_clean "test_script_exists"
}

# ── test_script_executable ────────────────────────────────────────────────────
# blast-radius-score.py must be executable
test_script_executable() {
    _snapshot_fail
    if [[ -x "$SCRIPT" ]]; then
        assert_eq "test_script_executable: is executable" "0" "0"
    else
        assert_eq "test_script_executable: blast-radius-score.py must be executable" "executable" "not_executable"
    fi
    assert_pass_if_clean "test_script_executable"
}

# ── test_outputs_valid_json ───────────────────────────────────────────────────
# Piping a file list to the script must produce valid JSON with required fields
test_outputs_valid_json() {
    _snapshot_fail
    local tmpdir
    tmpdir="$(mktemp -d)"
    _CLEANUP_DIRS+=("$tmpdir")

    # Create a minimal fixture with a few files
    local file_list
    file_list="$(printf 'src/main.py\nsrc/routes.py\ntests/test_main.py\n')"

    local output exit_code=0
    output=$(echo "$file_list" | python3 "$SCRIPT" 2>/dev/null) || exit_code=$?

    # Must exit 0
    assert_eq "test_outputs_valid_json: exit code is 0" "0" "$exit_code"

    # Output must be valid JSON with required top-level keys
    local has_score has_complex_override has_layer_count has_change_type has_signals
    has_score=$(python3 -c "import sys,json; d=json.loads('''$output'''); print('yes' if 'score' in d else 'no')" 2>/dev/null) || has_score="no"
    has_complex_override=$(python3 -c "import sys,json; d=json.loads('''$output'''); print('yes' if 'complex_override' in d else 'no')" 2>/dev/null) || has_complex_override="no"
    has_layer_count=$(python3 -c "import sys,json; d=json.loads('''$output'''); print('yes' if 'layer_count' in d else 'no')" 2>/dev/null) || has_layer_count="no"
    has_change_type=$(python3 -c "import sys,json; d=json.loads('''$output'''); print('yes' if 'change_type' in d else 'no')" 2>/dev/null) || has_change_type="no"
    has_signals=$(python3 -c "import sys,json; d=json.loads('''$output'''); print('yes' if 'signals' in d else 'no')" 2>/dev/null) || has_signals="no"

    assert_eq "test_outputs_valid_json: output has 'score' field" "yes" "$has_score"
    assert_eq "test_outputs_valid_json: output has 'complex_override' field" "yes" "$has_complex_override"
    assert_eq "test_outputs_valid_json: output has 'layer_count' field" "yes" "$has_layer_count"
    assert_eq "test_outputs_valid_json: output has 'change_type' field" "yes" "$has_change_type"
    assert_eq "test_outputs_valid_json: output has 'signals' field" "yes" "$has_signals"

    assert_pass_if_clean "test_outputs_valid_json"
}

# ── test_known_config_files_score_higher ──────────────────────────────────────
# Known high-weight config/entry/wiring files (main.py, routes.py) must produce
# a non-zero score
test_known_config_files_score_higher() {
    _snapshot_fail
    local file_list
    file_list="$(printf 'src/main.py\nsrc/routes.py\nconfig/settings.py\n')"

    local output exit_code=0
    output=$(echo "$file_list" | python3 "$SCRIPT" 2>/dev/null) || exit_code=$?

    assert_eq "test_known_config_files_score_higher: exits 0" "0" "$exit_code"

    local score
    score=$(python3 -c "import sys,json; d=json.loads('''$output'''); print(d.get('score',0))" 2>/dev/null) || score="0"

    # Known config/entry files must score > 0
    local score_positive
    score_positive=$(python3 -c "print('yes' if $score > 0 else 'no')" 2>/dev/null) || score_positive="no"
    assert_eq "test_known_config_files_score_higher: score > 0 for config/entry files" "yes" "$score_positive"

    assert_pass_if_clean "test_known_config_files_score_higher"
}

# ── test_deep_paths_score_lower ───────────────────────────────────────────────
# Deeply nested paths with no config/wiring patterns should score lower than
# shallow config files
test_deep_paths_score_lower() {
    _snapshot_fail

    # Config-heavy files
    local config_list
    config_list="$(printf 'main.py\nroutes.py\nconfig.py\nsettings.py\napp.py\nwsgi.py\n')"

    # Deep utility files only
    local deep_list
    deep_list="$(printf 'src/utils/internal/helpers/string_util.py\nsrc/utils/internal/helpers/date_util.py\nsrc/utils/internal/helpers/math_util.py\n')"

    local config_output deep_output
    config_output=$(echo "$config_list" | python3 "$SCRIPT" 2>/dev/null) || config_output="{}"
    deep_output=$(echo "$deep_list" | python3 "$SCRIPT" 2>/dev/null) || deep_output="{}"

    local config_score deep_score
    config_score=$(python3 -c "import json; print(json.loads('''$config_output''').get('score', 0))" 2>/dev/null) || config_score=0
    deep_score=$(python3 -c "import json; print(json.loads('''$deep_output''').get('score', 0))" 2>/dev/null) || deep_score=999

    local config_higher
    config_higher=$(python3 -c "print('yes' if $config_score > $deep_score else 'no')" 2>/dev/null) || config_higher="no"
    assert_eq "test_deep_paths_score_lower: config files score higher than deep utility paths" "yes" "$config_higher"

    assert_pass_if_clean "test_deep_paths_score_lower"
}

# ── test_complex_override_true_above_threshold ────────────────────────────────
# When score > 5 (threshold), complex_override must be true
test_complex_override_true_above_threshold() {
    _snapshot_fail

    # Many wiring/config files to push score above threshold
    local file_list
    file_list="$(printf 'main.py\nroutes.py\nconfig.py\nsettings.py\napp.py\nwsgi.py\nurls.py\nmiddleware.py\nmodels.py\nschema.py\ncelery.py\n')"

    local output
    output=$(echo "$file_list" | python3 "$SCRIPT" 2>/dev/null) || output="{}"

    local score complex_override
    score=$(python3 -c "import json; print(json.loads('''$output''').get('score', 0))" 2>/dev/null) || score=0
    complex_override=$(python3 -c "import json; print(json.loads('''$output''').get('complex_override', False))" 2>/dev/null) || complex_override="False"

    # Only assert complex_override=True if score actually exceeded threshold
    local score_above_threshold
    score_above_threshold=$(python3 -c "print('yes' if $score > 5 else 'no')" 2>/dev/null) || score_above_threshold="no"

    if [[ "$score_above_threshold" == "yes" ]]; then
        assert_eq "test_complex_override_true_above_threshold: complex_override=True when score>5" "True" "$complex_override"
    else
        # Score did not exceed threshold — fail explicitly so the test is useful
        assert_eq "test_complex_override_true_above_threshold: score must exceed 5 for this fixture (got $score)" "above_threshold" "below_threshold"
    fi

    assert_pass_if_clean "test_complex_override_true_above_threshold"
}

# ── test_complex_override_false_below_threshold ───────────────────────────────
# When score <= 5 (threshold), complex_override must be false
test_complex_override_false_below_threshold() {
    _snapshot_fail

    # Single deep utility file — should score <= 5
    local file_list
    file_list="$(printf 'src/utils/helpers/string_util.py\n')"

    local output
    output=$(echo "$file_list" | python3 "$SCRIPT" 2>/dev/null) || output="{}"

    local score complex_override
    score=$(python3 -c "import json; print(json.loads('''$output''').get('score', 0))" 2>/dev/null) || score=0
    complex_override=$(python3 -c "import json; print(json.loads('''$output''').get('complex_override', True))" 2>/dev/null) || complex_override="True"

    local score_at_or_below
    score_at_or_below=$(python3 -c "print('yes' if $score <= 5 else 'no')" 2>/dev/null) || score_at_or_below="no"

    if [[ "$score_at_or_below" == "yes" ]]; then
        assert_eq "test_complex_override_false_below_threshold: complex_override=False when score<=5" "False" "$complex_override"
    else
        assert_eq "test_complex_override_false_below_threshold: score must be <=5 for this fixture (got $score)" "at_or_below_threshold" "above_threshold"
    fi

    assert_pass_if_clean "test_complex_override_false_below_threshold"
}

# ── test_layer_count ──────────────────────────────────────────────────────────
# layer_count must equal the number of distinct top-level directories
test_layer_count() {
    _snapshot_fail

    # Three distinct top-level dirs: src, tests, config
    local file_list
    file_list="$(printf 'src/main.py\nsrc/routes.py\ntests/test_main.py\nconfig/settings.py\n')"

    local output
    output=$(echo "$file_list" | python3 "$SCRIPT" 2>/dev/null) || output="{}"

    local layer_count
    layer_count=$(python3 -c "import json; print(json.loads('''$output''').get('layer_count', -1))" 2>/dev/null) || layer_count="-1"

    assert_eq "test_layer_count: layer_count equals 3 (src, tests, config)" "3" "$layer_count"

    assert_pass_if_clean "test_layer_count"
}

# ── test_change_type_valid_enum ───────────────────────────────────────────────
# change_type must be one of: additive, subtractive, substitutive, mixed
test_change_type_valid_enum() {
    _snapshot_fail

    local file_list
    file_list="$(printf 'src/main.py\nsrc/routes.py\n')"

    local output
    output=$(echo "$file_list" | python3 "$SCRIPT" 2>/dev/null) || output="{}"

    local change_type
    change_type=$(python3 -c "import json; print(json.loads('''$output''').get('change_type', ''))" 2>/dev/null) || change_type=""

    local is_valid_enum
    is_valid_enum=$(python3 -c "print('yes' if '$change_type' in ('additive','subtractive','substitutive','mixed') else 'no')" 2>/dev/null) || is_valid_enum="no"
    assert_eq "test_change_type_valid_enum: change_type is valid enum value" "yes" "$is_valid_enum"

    assert_pass_if_clean "test_change_type_valid_enum"
}

# ── test_empty_input ──────────────────────────────────────────────────────────
# Empty stdin must produce score=0 and complex_override=false
test_empty_input() {
    _snapshot_fail

    local output exit_code=0
    output=$(echo "" | python3 "$SCRIPT" 2>/dev/null) || exit_code=$?

    assert_eq "test_empty_input: exits 0 on empty input" "0" "$exit_code"

    local score complex_override
    score=$(python3 -c "import json; print(json.loads('''$output''').get('score', -1))" 2>/dev/null) || score="-1"
    complex_override=$(python3 -c "import json; print(json.loads('''$output''').get('complex_override', True))" 2>/dev/null) || complex_override="True"

    assert_eq "test_empty_input: score=0 on empty input" "0" "$score"
    assert_eq "test_empty_input: complex_override=False on empty input" "False" "$complex_override"

    assert_pass_if_clean "test_empty_input"
}

# ── test_go_fixture ───────────────────────────────────────────────────────────
# kubernetes-style Go project: cmd/, pkg/, internal/, main.go
# Expects non-zero score (main.go and wiring dirs present)
test_go_fixture() {
    _snapshot_fail

    local file_list
    file_list="$(printf \
'cmd/server/main.go\ncmd/server/server.go\npkg/api/handler.go\npkg/api/routes.go\ninternal/config/config.go\ninternal/db/db.go\ngo.mod\ngo.sum\nMakefile\n')"

    local output exit_code=0
    output=$(echo "$file_list" | python3 "$SCRIPT" 2>/dev/null) || exit_code=$?

    assert_eq "test_go_fixture: exits 0" "0" "$exit_code"

    local score change_type layer_count
    score=$(python3 -c "import json; print(json.loads('''$output''').get('score', -1))" 2>/dev/null) || score="-1"
    change_type=$(python3 -c "import json; print(json.loads('''$output''').get('change_type', ''))" 2>/dev/null) || change_type=""
    layer_count=$(python3 -c "import json; print(json.loads('''$output''').get('layer_count', -1))" 2>/dev/null) || layer_count="-1"

    local score_positive
    score_positive=$(python3 -c "print('yes' if $score > 0 else 'no')" 2>/dev/null) || score_positive="no"
    assert_eq "test_go_fixture: score > 0 for kubernetes-style Go project" "yes" "$score_positive"

    local is_valid_enum
    is_valid_enum=$(python3 -c "print('yes' if '$change_type' in ('additive','subtractive','substitutive','mixed') else 'no')" 2>/dev/null) || is_valid_enum="no"
    assert_eq "test_go_fixture: change_type is valid enum" "yes" "$is_valid_enum"

    # 5 top-level dirs: cmd, pkg, internal, go.mod(root), go.sum(root), Makefile(root) -> at least 3 dirs
    local layer_at_least_3
    layer_at_least_3=$(python3 -c "print('yes' if $layer_count >= 3 else 'no')" 2>/dev/null) || layer_at_least_3="no"
    assert_eq "test_go_fixture: layer_count >= 3 for kubernetes-style layout" "yes" "$layer_at_least_3"

    assert_pass_if_clean "test_go_fixture"
}

# ── test_typescript_fixture ───────────────────────────────────────────────────
# next.js-style TypeScript project: pages/, app/, next.config.js
# Expects non-zero score (next.config.js and routing files present)
test_typescript_fixture() {
    _snapshot_fail

    local file_list
    file_list="$(printf \
'pages/index.tsx\npages/api/hello.ts\napp/layout.tsx\napp/page.tsx\nnext.config.js\ntsconfig.json\npackage.json\nsrc/components/Button.tsx\nsrc/lib/api.ts\n')"

    local output exit_code=0
    output=$(echo "$file_list" | python3 "$SCRIPT" 2>/dev/null) || exit_code=$?

    assert_eq "test_typescript_fixture: exits 0" "0" "$exit_code"

    local score change_type layer_count
    score=$(python3 -c "import json; print(json.loads('''$output''').get('score', -1))" 2>/dev/null) || score="-1"
    change_type=$(python3 -c "import json; print(json.loads('''$output''').get('change_type', ''))" 2>/dev/null) || change_type=""
    layer_count=$(python3 -c "import json; print(json.loads('''$output''').get('layer_count', -1))" 2>/dev/null) || layer_count="-1"

    local score_positive
    score_positive=$(python3 -c "print('yes' if $score > 0 else 'no')" 2>/dev/null) || score_positive="no"
    assert_eq "test_typescript_fixture: score > 0 for next.js project" "yes" "$score_positive"

    local is_valid_enum
    is_valid_enum=$(python3 -c "print('yes' if '$change_type' in ('additive','subtractive','substitutive','mixed') else 'no')" 2>/dev/null) || is_valid_enum="no"
    assert_eq "test_typescript_fixture: change_type is valid enum" "yes" "$is_valid_enum"

    # Top-level dirs: pages, app, src (plus root files like next.config.js counted at root)
    local layer_at_least_2
    layer_at_least_2=$(python3 -c "print('yes' if $layer_count >= 2 else 'no')" 2>/dev/null) || layer_at_least_2="no"
    assert_eq "test_typescript_fixture: layer_count >= 2 for next.js layout" "yes" "$layer_at_least_2"

    assert_pass_if_clean "test_typescript_fixture"
}

# ── test_python_fixture ───────────────────────────────────────────────────────
# pyproject-style Python project: src/, pyproject.toml, setup.cfg
# Expects non-zero score (pyproject.toml is a high-weight config file)
test_python_fixture() {
    _snapshot_fail

    local file_list
    file_list="$(printf \
'src/mypackage/__init__.py\nsrc/mypackage/main.py\nsrc/mypackage/routes.py\nsrc/mypackage/models.py\ntests/test_main.py\ntests/conftest.py\npyproject.toml\nsetup.cfg\n')"

    local output exit_code=0
    output=$(echo "$file_list" | python3 "$SCRIPT" 2>/dev/null) || exit_code=$?

    assert_eq "test_python_fixture: exits 0" "0" "$exit_code"

    local score change_type
    score=$(python3 -c "import json; print(json.loads('''$output''').get('score', -1))" 2>/dev/null) || score="-1"
    change_type=$(python3 -c "import json; print(json.loads('''$output''').get('change_type', ''))" 2>/dev/null) || change_type=""

    local score_positive
    score_positive=$(python3 -c "print('yes' if $score > 0 else 'no')" 2>/dev/null) || score_positive="no"
    assert_eq "test_python_fixture: score > 0 for pyproject-style Python project" "yes" "$score_positive"

    local is_valid_enum
    is_valid_enum=$(python3 -c "print('yes' if '$change_type' in ('additive','subtractive','substitutive','mixed') else 'no')" 2>/dev/null) || is_valid_enum="no"
    assert_eq "test_python_fixture: change_type is valid enum" "yes" "$is_valid_enum"

    assert_pass_if_clean "test_python_fixture"
}

# ── test_rust_fixture ─────────────────────────────────────────────────────────
# cargo-style Rust project: src/, Cargo.toml, build.rs
# Expects non-zero score (Cargo.toml and build.rs are wiring files)
test_rust_fixture() {
    _snapshot_fail

    local file_list
    file_list="$(printf \
'src/main.rs\nsrc/lib.rs\nsrc/config.rs\nsrc/routes.rs\ntests/integration_test.rs\nCargo.toml\nCargo.lock\nbuild.rs\n')"

    local output exit_code=0
    output=$(echo "$file_list" | python3 "$SCRIPT" 2>/dev/null) || exit_code=$?

    assert_eq "test_rust_fixture: exits 0" "0" "$exit_code"

    local score change_type
    score=$(python3 -c "import json; print(json.loads('''$output''').get('score', -1))" 2>/dev/null) || score="-1"
    change_type=$(python3 -c "import json; print(json.loads('''$output''').get('change_type', ''))" 2>/dev/null) || change_type=""

    local score_positive
    score_positive=$(python3 -c "print('yes' if $score > 0 else 'no')" 2>/dev/null) || score_positive="no"
    assert_eq "test_rust_fixture: score > 0 for cargo-style Rust project" "yes" "$score_positive"

    local is_valid_enum
    is_valid_enum=$(python3 -c "print('yes' if '$change_type' in ('additive','subtractive','substitutive','mixed') else 'no')" 2>/dev/null) || is_valid_enum="no"
    assert_eq "test_rust_fixture: change_type is valid enum" "yes" "$is_valid_enum"

    assert_pass_if_clean "test_rust_fixture"
}

# ── Run all tests ──────────────────────────────────────────────────────────────
test_script_exists
test_script_executable
test_outputs_valid_json
test_known_config_files_score_higher
test_deep_paths_score_lower
test_complex_override_true_above_threshold
test_complex_override_false_below_threshold
test_layer_count
test_change_type_valid_enum
test_empty_input
test_go_fixture
test_typescript_fixture
test_python_fixture
test_rust_fixture

print_summary
