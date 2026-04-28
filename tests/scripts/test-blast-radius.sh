#!/usr/bin/env bash
# tests/scripts/test-blast-radius.sh
# Behavioral RED tests for plugins/dso/scripts/fix-bug/blast-radius.sh
#
# Each test creates an isolated temp project directory with controlled file
# structures and import relationships, then executes the gate script and
# asserts on observable outputs (stdout JSON, exit code).
#
# RED STATE: All tests currently fail because blast-radius.sh does not
# yet exist. They will pass (GREEN) after the script is implemented.
#
# Usage: bash tests/scripts/test-blast-radius.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
GATE_SCRIPT="$PLUGIN_ROOT/plugins/dso/scripts/fix-bug/blast-radius.sh"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

# Temp dir cleanup on exit
_TEST_TMPDIRS=()
_cleanup() { for d in "${_TEST_TMPDIRS[@]:-}"; do rm -rf "$d"; done; }
trap _cleanup EXIT

echo "=== test-blast-radius.sh ==="

# ── Helper: create a temp project dir ────────────────────────────────────────
_make_project() {
    local tmpdir
    tmpdir="$(mktemp -d)"
    _TEST_TMPDIRS+=("$tmpdir")
    echo "$tmpdir"
}

# ── Helper: extract a JSON field from gate output ────────────────────────────
_json_field() {
    local json="$1" field="$2"
    python3 -c "
import sys, json as j
try:
    d = j.loads(sys.stdin.read())
    v = d.get('$field', '')
    print(str(v).lower() if isinstance(v, bool) else v)
except Exception:
    print('')
" <<< "$json" 2>/dev/null || echo ""
}

# ── test_convention_package_manifest ─────────────────────────────────────────
# pyproject.toml in a project → annotation mentions "package manifest"
test_convention_package_manifest() {
    _snapshot_fail

    local proj
    proj="$(_make_project)"
    touch "$proj/pyproject.toml"

    local output exit_code=0
    output=$(bash "$GATE_SCRIPT" "$proj/pyproject.toml" 2>/dev/null) || exit_code=$?

    assert_eq "test_convention_package_manifest: exits 0" "0" "$exit_code"

    local evidence
    evidence="$(_json_field "$output" evidence)"
    assert_contains "test_convention_package_manifest: annotation mentions 'package manifest'" "package manifest" "$evidence"

    local triggered
    triggered="$(_json_field "$output" triggered)"
    assert_eq "test_convention_package_manifest: triggered=true for convention match" "true" "$triggered"

    assert_pass_if_clean "test_convention_package_manifest"
}

# ── test_convention_ci_config ─────────────────────────────────────────────────
# .github/workflows/ci.yml → annotation mentions "CI config"
test_convention_ci_config() {
    _snapshot_fail

    local proj
    proj="$(_make_project)"
    mkdir -p "$proj/.github/workflows"
    touch "$proj/.github/workflows/ci.yml"

    local output exit_code=0
    output=$(bash "$GATE_SCRIPT" "$proj/.github/workflows/ci.yml" 2>/dev/null) || exit_code=$?

    assert_eq "test_convention_ci_config: exits 0" "0" "$exit_code"

    local evidence
    evidence="$(_json_field "$output" evidence)"
    assert_contains "test_convention_ci_config: annotation mentions 'CI config'" "CI config" "$evidence"

    local triggered
    triggered="$(_json_field "$output" triggered)"
    assert_eq "test_convention_ci_config: triggered=true for CI config convention" "true" "$triggered"

    assert_pass_if_clean "test_convention_ci_config"
}

# ── test_convention_entry_point ───────────────────────────────────────────────
# main.py → annotation mentions "entry point"
test_convention_entry_point() {
    _snapshot_fail

    local proj
    proj="$(_make_project)"
    echo "# main entry" > "$proj/main.py"

    local output exit_code=0
    output=$(bash "$GATE_SCRIPT" "$proj/main.py" 2>/dev/null) || exit_code=$?

    assert_eq "test_convention_entry_point: exits 0" "0" "$exit_code"

    local evidence
    evidence="$(_json_field "$output" evidence)"
    assert_contains "test_convention_entry_point: annotation mentions 'entry point'" "entry point" "$evidence"

    local triggered
    triggered="$(_json_field "$output" triggered)"
    assert_eq "test_convention_entry_point: triggered=true for entry point convention" "true" "$triggered"

    assert_pass_if_clean "test_convention_entry_point"
}

# ── test_fan_in_grep_fallback ─────────────────────────────────────────────────
# 3 files import the target file, ast-grep not present → "imported by 3 modules"
# (The script falls back to grep-based fan-in counting when ast-grep is absent.)
test_fan_in_grep_fallback() {
    _snapshot_fail

    local proj
    proj="$(_make_project)"
    mkdir -p "$proj/src" "$proj/consumers"

    # Target file (not a known convention filename)
    echo "def helper(): pass" > "$proj/src/helper_utils.py"

    # Three files that import the target
    echo "from src.helper_utils import helper" > "$proj/consumers/a.py"
    echo "import src.helper_utils" > "$proj/consumers/b.py"
    echo "from src import helper_utils" > "$proj/consumers/c.py"

    # Temporarily shadow ast-grep with a non-existent path so the script
    # takes the grep fallback path
    local output exit_code=0
    output=$(BLAST_RADIUS_GATE_SKIP_AST_GREP=1 bash "$GATE_SCRIPT" "$proj/src/helper_utils.py" "$proj" 2>/dev/null) || exit_code=$?

    assert_eq "test_fan_in_grep_fallback: exits 0" "0" "$exit_code"

    local evidence
    evidence="$(_json_field "$output" evidence)"
    assert_contains "test_fan_in_grep_fallback: evidence mentions 'imported by 3'" "imported by 3" "$evidence"

    local triggered
    triggered="$(_json_field "$output" triggered)"
    assert_eq "test_fan_in_grep_fallback: triggered=true when fan-in=3" "true" "$triggered"

    assert_pass_if_clean "test_fan_in_grep_fallback"
}

# ── test_fan_in_with_ast_grep ─────────────────────────────────────────────────
# ast-grep available → fan-in counted via ast-grep
# Skipped if ast-grep is not installed.
test_fan_in_with_ast_grep() {
    _snapshot_fail

    if ! command -v ast-grep >/dev/null 2>&1; then
        echo "test_fan_in_with_ast_grep ... SKIP (ast-grep not installed)"
        assert_pass_if_clean "test_fan_in_with_ast_grep"
        return
    fi

    local proj
    proj="$(_make_project)"
    mkdir -p "$proj/src" "$proj/consumers"

    echo "def compute(): pass" > "$proj/src/core_logic.py"
    echo "from src.core_logic import compute" > "$proj/consumers/x.py"
    echo "from src.core_logic import compute" > "$proj/consumers/y.py"

    local output exit_code=0
    output=$(bash "$GATE_SCRIPT" "$proj/src/core_logic.py" "$proj" 2>/dev/null) || exit_code=$?

    assert_eq "test_fan_in_with_ast_grep: exits 0" "0" "$exit_code"

    local triggered
    triggered="$(_json_field "$output" triggered)"
    assert_eq "test_fan_in_with_ast_grep: triggered=true when fan-in found via ast-grep" "true" "$triggered"

    local evidence
    evidence="$(_json_field "$output" evidence)"
    # Evidence must mention a numeric count (fan-in > 0)
    local has_count
    has_count=$(python3 -c "
import re, sys
evidence = sys.stdin.read().strip()
print('yes' if re.search(r'imported by [0-9]+', evidence) else 'no')
" <<< "$evidence" 2>/dev/null) || has_count="no"
    assert_eq "test_fan_in_with_ast_grep: evidence contains 'imported by N'" "yes" "$has_count"

    assert_pass_if_clean "test_fan_in_with_ast_grep"
}

# ── test_fan_in_dotted_imports_union ──────────────────────────────────────────
# When ast-grep is available, dotted imports (from src.mod import ...) are
# counted via grep and unioned with ast-grep results for accurate fan-in.
test_fan_in_dotted_imports_union() {
    _snapshot_fail

    if ! command -v ast-grep >/dev/null 2>&1; then
        echo "test_fan_in_dotted_imports_union ... SKIP (ast-grep not installed)"
        assert_pass_if_clean "test_fan_in_dotted_imports_union"
        return
    fi

    local proj
    proj="$(_make_project)"
    mkdir -p "$proj/src" "$proj/consumers"

    echo "def helper(): pass" > "$proj/src/utils.py"
    # 2 files use dotted imports (only grep catches these)
    echo "from src.utils import helper" > "$proj/consumers/a.py"
    echo "import src.utils" > "$proj/consumers/b.py"

    local output exit_code=0
    output=$(bash "$GATE_SCRIPT" "$proj/src/utils.py" "$proj" 2>/dev/null) || exit_code=$?

    assert_eq "test_fan_in_dotted_imports_union: exits 0" "0" "$exit_code"

    local evidence
    evidence="$(_json_field "$output" evidence)"
    assert_contains "test_fan_in_dotted_imports_union: evidence mentions 'imported by 2'" "imported by 2" "$evidence"

    assert_pass_if_clean "test_fan_in_dotted_imports_union"
}

# ── test_modifier_signal_type ─────────────────────────────────────────────────
# signal_type must always be "modifier", never "primary"
test_modifier_signal_type() {
    _snapshot_fail

    local proj
    proj="$(_make_project)"
    touch "$proj/pyproject.toml"

    local output exit_code=0
    output=$(bash "$GATE_SCRIPT" "$proj/pyproject.toml" 2>/dev/null) || exit_code=$?

    assert_eq "test_modifier_signal_type: exits 0" "0" "$exit_code"

    local signal_type
    signal_type="$(_json_field "$output" signal_type)"
    assert_eq "test_modifier_signal_type: signal_type is 'modifier'" "modifier" "$signal_type"

    assert_ne "test_modifier_signal_type: signal_type is NOT 'primary'" "primary" "$signal_type"

    assert_pass_if_clean "test_modifier_signal_type"
}

# ── test_emits_gate_signal_json ───────────────────────────────────────────────
# gate_id must be "blast_radius"; output must be valid JSON with all required schema fields
test_emits_gate_signal_json() {
    _snapshot_fail

    local proj
    proj="$(_make_project)"
    echo "# entry" > "$proj/main.py"

    local output exit_code=0
    output=$(bash "$GATE_SCRIPT" "$proj/main.py" 2>/dev/null) || exit_code=$?

    assert_eq "test_emits_gate_signal_json: exits 0" "0" "$exit_code"

    # Validate JSON is parseable and all required fields are present
    local fields_ok
    fields_ok=$(python3 -c "
import sys, json as j
try:
    d = j.loads(sys.stdin.read())
    required = {'gate_id', 'triggered', 'signal_type', 'evidence', 'confidence'}
    missing = required - set(d.keys())
    if missing:
        print('missing: ' + ', '.join(sorted(missing)))
    else:
        print('ok')
except Exception as e:
    print('parse_error: ' + str(e))
" <<< "$output" 2>/dev/null) || fields_ok="parse_error"
    assert_eq "test_emits_gate_signal_json: output has all required schema fields" "ok" "$fields_ok"

    local gate_id
    gate_id="$(_json_field "$output" gate_id)"
    assert_eq "test_emits_gate_signal_json: gate_id is 'blast_radius'" "blast_radius" "$gate_id"

    local confidence
    confidence="$(_json_field "$output" confidence)"
    local conf_valid
    conf_valid=$(python3 -c "print('yes' if '$confidence' in ('high','medium','low') else 'no')" 2>/dev/null) || conf_valid="no"
    assert_eq "test_emits_gate_signal_json: confidence is a valid enum value" "yes" "$conf_valid"

    assert_pass_if_clean "test_emits_gate_signal_json"
}

# ── test_no_fan_in_no_convention ──────────────────────────────────────────────
# File not imported by anyone, not a known convention → triggered=false
test_no_fan_in_no_convention() {
    _snapshot_fail

    local proj
    proj="$(_make_project)"
    mkdir -p "$proj/src"

    # A deeply buried utility file with a non-conventional name
    echo "def noop(): pass" > "$proj/src/internal_noop_xyzzy.py"
    # No other files import it

    local output exit_code=0
    output=$(bash "$GATE_SCRIPT" "$proj/src/internal_noop_xyzzy.py" "$proj" 2>/dev/null) || exit_code=$?

    assert_eq "test_no_fan_in_no_convention: exits 0" "0" "$exit_code"

    local triggered
    triggered="$(_json_field "$output" triggered)"
    assert_eq "test_no_fan_in_no_convention: triggered=false when no fan-in and no convention" "false" "$triggered"

    # evidence must still be non-empty (schema requires it)
    local evidence
    evidence="$(_json_field "$output" evidence)"
    assert_ne "test_no_fan_in_no_convention: evidence field is non-empty even when not triggered" "" "$evidence"

    assert_pass_if_clean "test_no_fan_in_no_convention"
}

# ── test_annotation_note_prefix ───────────────────────────────────────────────
# The annotation (evidence field) starts with "Note:" and contains the file path
test_annotation_note_prefix() {
    _snapshot_fail

    local proj
    proj="$(_make_project)"
    touch "$proj/pyproject.toml"

    local output exit_code=0
    output=$(bash "$GATE_SCRIPT" "$proj/pyproject.toml" 2>/dev/null) || exit_code=$?

    assert_eq "test_annotation_note_prefix: exits 0" "0" "$exit_code"

    local evidence
    evidence="$(_json_field "$output" evidence)"

    # Evidence must start with "Note:"
    local starts_with_note
    starts_with_note=$(python3 -c "
evidence = '''$evidence'''
print('yes' if evidence.lstrip().startswith('Note:') else 'no')
" 2>/dev/null) || starts_with_note="no"
    assert_eq "test_annotation_note_prefix: annotation starts with 'Note:'" "yes" "$starts_with_note"

    # Evidence must contain the file path (or its basename at minimum)
    assert_contains "test_annotation_note_prefix: annotation contains the file path" "pyproject.toml" "$evidence"

    assert_pass_if_clean "test_annotation_note_prefix"
}

# ── test_multi_convention ─────────────────────────────────────────────────────
# File matches multiple heuristics (e.g. main.py at root AND imported by others)
# → evidence mentions all matched conventions
test_multi_convention() {
    _snapshot_fail

    local proj
    proj="$(_make_project)"
    mkdir -p "$proj/consumers"

    # main.py — both an entry point convention AND imported by two consumers
    echo "def run(): pass" > "$proj/main.py"
    echo "import main" > "$proj/consumers/runner_a.py"
    echo "import main" > "$proj/consumers/runner_b.py"

    local output exit_code=0
    output=$(bash "$GATE_SCRIPT" "$proj/main.py" "$proj" 2>/dev/null) || exit_code=$?

    assert_eq "test_multi_convention: exits 0" "0" "$exit_code"

    local triggered
    triggered="$(_json_field "$output" triggered)"
    assert_eq "test_multi_convention: triggered=true when multiple signals match" "true" "$triggered"

    local evidence
    evidence="$(_json_field "$output" evidence)"

    # Must mention the entry point convention
    assert_contains "test_multi_convention: evidence mentions entry point convention" "entry point" "$evidence"

    # Must also mention fan-in (imported by N)
    local has_fan_in_mention
    has_fan_in_mention=$(python3 -c "
import re
print('yes' if re.search(r'imported by [0-9]+', '''$evidence''') else 'no')
" 2>/dev/null) || has_fan_in_mention="no"
    assert_eq "test_multi_convention: evidence mentions fan-in count" "yes" "$has_fan_in_mention"

    assert_pass_if_clean "test_multi_convention"
}

# ── Run all tests ─────────────────────────────────────────────────────────────
test_convention_package_manifest
test_convention_ci_config
test_convention_entry_point
test_fan_in_grep_fallback
test_fan_in_with_ast_grep
test_fan_in_dotted_imports_union
test_modifier_signal_type
test_emits_gate_signal_json
test_no_fan_in_no_convention
test_annotation_note_prefix
test_multi_convention

print_summary
