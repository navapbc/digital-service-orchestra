#!/usr/bin/env bash
# tests/unit/scripts/test-detect-enforcement-artifacts.sh
# Behavioral tests for plugins/dso/scripts/onboarding/detect-enforcement-artifacts.sh
#
# Tests verify observable behavior:
#   1. Always exits 0 (detection mode, not validation)
#   2. Output is parseable JSON with expected keys
#   3. arch_enforcement_md: false when ARCH_ENFORCEMENT.md absent
#   4. arch_enforcement_md: true when ARCH_ENFORCEMENT.md present
#   5. adr_dir: false and adr_count: 0 when docs/adr/ absent
#   6. adr_dir: true and adr_count reflects .md files when docs/adr/ present
#   7. claude_md_invariants_section: false when CLAUDE.md lacks the heading
#   8. claude_md_invariants_section: true when CLAUDE.md has the heading
#   9. --project-dir=<dir> (= form) works equivalently to --project-dir <dir>
#  10. Unknown argument exits 1 with error on stderr
#  11. Script is executable
#
# Usage: bash tests/unit/scripts/test-detect-enforcement-artifacts.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
SCRIPT="$REPO_ROOT/plugins/dso/scripts/onboarding/detect-enforcement-artifacts.sh"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-detect-enforcement-artifacts.sh ==="

# ── Helper: create a minimal project dir fixture ─────────────────────────────
_make_project_dir() {
    mktemp -d
}

# ── Test 1: Script always exits 0 (even with missing artifacts) ───────────────

test_always_exits_0() {
    _snapshot_fail

    if [[ ! -x "$SCRIPT" ]]; then
        (( ++FAIL ))
        printf "FAIL: test_always_exits_0\n  script not found or not executable: %s\n" "$SCRIPT" >&2
        assert_pass_if_clean "test_always_exits_0"
        return
    fi

    local proj_dir exit_code=0
    proj_dir="$(_make_project_dir)"
    trap 'rm -rf "$proj_dir"' RETURN

    bash "$SCRIPT" --project-dir "$proj_dir" >/dev/null 2>&1 || exit_code=$?

    assert_eq "always exits 0" "0" "$exit_code"

    assert_pass_if_clean "test_always_exits_0"
}

# ── Test 2: Output is parseable JSON with expected keys ──────────────────────

test_output_is_valid_json_with_required_keys() {
    _snapshot_fail

    if [[ ! -x "$SCRIPT" ]]; then
        (( ++FAIL ))
        printf "FAIL: test_output_is_valid_json_with_required_keys\n  script not found or not executable: %s\n" "$SCRIPT" >&2
        assert_pass_if_clean "test_output_is_valid_json_with_required_keys"
        return
    fi

    local proj_dir parse_exit=0
    proj_dir="$(_make_project_dir)"
    trap 'rm -rf "$proj_dir"' RETURN

    local out
    out=$(bash "$SCRIPT" --project-dir "$proj_dir" 2>/dev/null)
    printf '%s' "$out" | python3 -c "import json,sys; json.load(sys.stdin)" 2>/dev/null || parse_exit=$?

    assert_eq "json: valid JSON" "0" "$parse_exit"
    assert_contains "json: project_dir key" '"project_dir"'               "$out"
    assert_contains "json: arch_enforcement_md key" '"arch_enforcement_md"' "$out"
    assert_contains "json: adr_dir key" '"adr_dir"'                        "$out"
    assert_contains "json: adr_count key" '"adr_count"'                    "$out"
    assert_contains "json: claude_md_invariants_section key" '"claude_md_invariants_section"' "$out"

    assert_pass_if_clean "test_output_is_valid_json_with_required_keys"
}

# ── Test 3: arch_enforcement_md: false when ARCH_ENFORCEMENT.md absent ───────

test_arch_md_false_when_absent() {
    _snapshot_fail

    if [[ ! -x "$SCRIPT" ]]; then
        (( ++FAIL ))
        printf "FAIL: test_arch_md_false_when_absent\n  script not found or not executable: %s\n" "$SCRIPT" >&2
        assert_pass_if_clean "test_arch_md_false_when_absent"
        return
    fi

    local proj_dir
    proj_dir="$(_make_project_dir)"
    trap 'rm -rf "$proj_dir"' RETURN

    # No ARCH_ENFORCEMENT.md in project
    local out
    out=$(bash "$SCRIPT" --project-dir "$proj_dir" 2>/dev/null)

    local val
    val=$(printf '%s' "$out" | python3 -c "import json,sys; print(json.load(sys.stdin)['arch_enforcement_md'])" 2>/dev/null || echo "error")

    assert_eq "arch_md absent: false" "False" "$val"

    assert_pass_if_clean "test_arch_md_false_when_absent"
}

# ── Test 4: arch_enforcement_md: true when ARCH_ENFORCEMENT.md present ───────

test_arch_md_true_when_present() {
    _snapshot_fail

    if [[ ! -x "$SCRIPT" ]]; then
        (( ++FAIL ))
        printf "FAIL: test_arch_md_true_when_present\n  script not found or not executable: %s\n" "$SCRIPT" >&2
        assert_pass_if_clean "test_arch_md_true_when_present"
        return
    fi

    local proj_dir
    proj_dir="$(_make_project_dir)"
    trap 'rm -rf "$proj_dir"' RETURN

    touch "$proj_dir/ARCH_ENFORCEMENT.md"

    local out
    out=$(bash "$SCRIPT" --project-dir "$proj_dir" 2>/dev/null)

    local val
    val=$(printf '%s' "$out" | python3 -c "import json,sys; print(json.load(sys.stdin)['arch_enforcement_md'])" 2>/dev/null || echo "error")

    assert_eq "arch_md present: true" "True" "$val"

    assert_pass_if_clean "test_arch_md_true_when_present"
}

# ── Test 5: adr_dir: false and adr_count: 0 when docs/adr/ absent ────────────

test_adr_dir_false_and_count_0_when_absent() {
    _snapshot_fail

    if [[ ! -x "$SCRIPT" ]]; then
        (( ++FAIL ))
        printf "FAIL: test_adr_dir_false_and_count_0_when_absent\n  script not found or not executable: %s\n" "$SCRIPT" >&2
        assert_pass_if_clean "test_adr_dir_false_and_count_0_when_absent"
        return
    fi

    local proj_dir
    proj_dir="$(_make_project_dir)"
    trap 'rm -rf "$proj_dir"' RETURN

    # No docs/adr/
    local out
    out=$(bash "$SCRIPT" --project-dir "$proj_dir" 2>/dev/null)

    local dir_val count_val
    dir_val=$(printf '%s' "$out" | python3 -c "import json,sys; print(json.load(sys.stdin)['adr_dir'])" 2>/dev/null || echo "error")
    count_val=$(printf '%s' "$out" | python3 -c "import json,sys; print(json.load(sys.stdin)['adr_count'])" 2>/dev/null || echo "error")

    assert_eq "adr_dir absent: false" "False" "$dir_val"
    assert_eq "adr_count absent: 0"   "0"     "$count_val"

    assert_pass_if_clean "test_adr_dir_false_and_count_0_when_absent"
}

# ── Test 6: adr_dir: true and adr_count accurate when docs/adr/ has .md files ─

test_adr_dir_true_and_count_accurate_when_present() {
    _snapshot_fail

    if [[ ! -x "$SCRIPT" ]]; then
        (( ++FAIL ))
        printf "FAIL: test_adr_dir_true_and_count_accurate_when_present\n  script not found or not executable: %s\n" "$SCRIPT" >&2
        assert_pass_if_clean "test_adr_dir_true_and_count_accurate_when_present"
        return
    fi

    local proj_dir
    proj_dir="$(_make_project_dir)"
    trap 'rm -rf "$proj_dir"' RETURN

    mkdir -p "$proj_dir/docs/adr"
    touch "$proj_dir/docs/adr/0001-use-bash.md"
    touch "$proj_dir/docs/adr/0002-prefer-json.md"

    local out
    out=$(bash "$SCRIPT" --project-dir "$proj_dir" 2>/dev/null)

    local dir_val count_val
    dir_val=$(printf '%s' "$out" | python3 -c "import json,sys; print(json.load(sys.stdin)['adr_dir'])" 2>/dev/null || echo "error")
    count_val=$(printf '%s' "$out" | python3 -c "import json,sys; print(json.load(sys.stdin)['adr_count'])" 2>/dev/null || echo "error")

    assert_eq "adr_dir present: true" "True" "$dir_val"
    assert_eq "adr_count: 2"          "2"    "$count_val"

    assert_pass_if_clean "test_adr_dir_true_and_count_accurate_when_present"
}

# ── Test 7: claude_md_invariants_section: false when heading absent ───────────

test_claude_md_section_false_when_heading_absent() {
    _snapshot_fail

    if [[ ! -x "$SCRIPT" ]]; then
        (( ++FAIL ))
        printf "FAIL: test_claude_md_section_false_when_heading_absent\n  script not found or not executable: %s\n" "$SCRIPT" >&2
        assert_pass_if_clean "test_claude_md_section_false_when_heading_absent"
        return
    fi

    local proj_dir
    proj_dir="$(_make_project_dir)"
    trap 'rm -rf "$proj_dir"' RETURN

    printf '# CLAUDE.md\n\n## Some Other Section\n' > "$proj_dir/CLAUDE.md"

    local out
    out=$(bash "$SCRIPT" --project-dir "$proj_dir" 2>/dev/null)

    local val
    val=$(printf '%s' "$out" | python3 -c "import json,sys; print(json.load(sys.stdin)['claude_md_invariants_section'])" 2>/dev/null || echo "error")

    assert_eq "claude_md section absent: false" "False" "$val"

    assert_pass_if_clean "test_claude_md_section_false_when_heading_absent"
}

# ── Test 8: claude_md_invariants_section: true when heading present ───────────

test_claude_md_section_true_when_heading_present() {
    _snapshot_fail

    if [[ ! -x "$SCRIPT" ]]; then
        (( ++FAIL ))
        printf "FAIL: test_claude_md_section_true_when_heading_present\n  script not found or not executable: %s\n" "$SCRIPT" >&2
        assert_pass_if_clean "test_claude_md_section_true_when_heading_present"
        return
    fi

    local proj_dir
    proj_dir="$(_make_project_dir)"
    trap 'rm -rf "$proj_dir"' RETURN

    printf '# CLAUDE.md\n\n## Architectural Invariants\n\nSome rule here.\n' > "$proj_dir/CLAUDE.md"

    local out
    out=$(bash "$SCRIPT" --project-dir "$proj_dir" 2>/dev/null)

    local val
    val=$(printf '%s' "$out" | python3 -c "import json,sys; print(json.load(sys.stdin)['claude_md_invariants_section'])" 2>/dev/null || echo "error")

    assert_eq "claude_md section present: true" "True" "$val"

    assert_pass_if_clean "test_claude_md_section_true_when_heading_present"
}

# ── Test 9: --project-dir=<dir> (equals form) works ─────────────────────────

test_project_dir_equals_form_works() {
    _snapshot_fail

    if [[ ! -x "$SCRIPT" ]]; then
        (( ++FAIL ))
        printf "FAIL: test_project_dir_equals_form_works\n  script not found or not executable: %s\n" "$SCRIPT" >&2
        assert_pass_if_clean "test_project_dir_equals_form_works"
        return
    fi

    local proj_dir exit_code=0
    proj_dir="$(_make_project_dir)"
    trap 'rm -rf "$proj_dir"' RETURN

    local out
    out=$(bash "$SCRIPT" "--project-dir=$proj_dir" 2>/dev/null) || exit_code=$?

    assert_eq "equals form: exits 0" "0" "$exit_code"
    assert_contains "equals form: project_dir key in output" '"project_dir"' "$out"

    assert_pass_if_clean "test_project_dir_equals_form_works"
}

# ── Test 10: Unknown argument exits 1 with error on stderr ───────────────────

test_unknown_argument_exits_1() {
    _snapshot_fail

    if [[ ! -x "$SCRIPT" ]]; then
        (( ++FAIL ))
        printf "FAIL: test_unknown_argument_exits_1\n  script not found or not executable: %s\n" "$SCRIPT" >&2
        assert_pass_if_clean "test_unknown_argument_exits_1"
        return
    fi

    local stderr_out exit_code=0
    stderr_out=$(bash "$SCRIPT" --not-a-real-flag 2>&1 >/dev/null) || exit_code=$?

    assert_eq "unknown arg: exits 1" "1" "$exit_code"
    assert_contains "unknown arg: error on stderr" "Error" "$stderr_out"

    assert_pass_if_clean "test_unknown_argument_exits_1"
}

# ── Test 11: Script is executable ────────────────────────────────────────────

test_detect_enforcement_artifacts_is_executable() {
    _snapshot_fail

    if [[ -x "$SCRIPT" ]]; then
        assert_eq "executable" "yes" "yes"
    else
        (( ++FAIL ))
        printf "FAIL: test_detect_enforcement_artifacts_is_executable\n  not executable: %s\n" "$SCRIPT" >&2
    fi

    assert_pass_if_clean "test_detect_enforcement_artifacts_is_executable"
}

# ── Run all tests ─────────────────────────────────────────────────────────────

test_always_exits_0
test_output_is_valid_json_with_required_keys
test_arch_md_false_when_absent
test_arch_md_true_when_present
test_adr_dir_false_and_count_0_when_absent
test_adr_dir_true_and_count_accurate_when_present
test_claude_md_section_false_when_heading_absent
test_claude_md_section_true_when_heading_present
test_project_dir_equals_form_works
test_unknown_argument_exits_1
test_detect_enforcement_artifacts_is_executable

print_summary
