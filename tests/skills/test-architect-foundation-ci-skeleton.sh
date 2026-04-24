#!/usr/bin/env bash
# tests/skills/test-architect-foundation-ci-skeleton.sh
# Tests that plugins/dso/skills/architect-foundation/SKILL.md contains a CI skeleton
# template section with hashFiles() conditionals for dependency caching per language.
#
# Testing mode: RED — all tests FAIL on current SKILL.md (no CI skeleton section exists).
#
# Validates (5 named assertions):
#   test_python_hashfiles_conditional: CI skeleton section contains Python block with
#     hashFiles() gated on requirements.txt or pyproject.toml, root-relative path
#   test_node_hashfiles_conditional: Node block with hashFiles() gated on
#     package-lock.json or yarn.lock
#   test_ruby_hashfiles_conditional: Ruby block with hashFiles() gated on
#     Gemfile.lock or Gemfile
#   test_blocks_structurally_isolated: Each language block is a self-contained
#     conditional (not interleaved with other language blocks)
#   test_paths_root_relative: All hashFiles() paths have no leading ./ or /
#
# Extraction strategy: awk extracts content from a "CI skeleton" or "CI Skeleton"
# section heading in SKILL.md (up to the next top-level ## heading), then grep
# asserts the presence or absence of specific patterns within that extracted block.
#
# Usage: bash tests/skills/test-architect-foundation-ci-skeleton.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
# CI skeleton content lives in the shared prompt file loaded on demand by
# architect-foundation Phase 3 Step 3, not inline in SKILL.md.
SKILL_MD="$DSO_PLUGIN_DIR/skills/shared/prompts/ci-skeleton-templates.md"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-architect-foundation-ci-skeleton.sh ==="

# _extract_ci_skeleton_section: read the whole ci-skeleton-templates.md file.
# The file is a dedicated reference doc — no enclosing section extraction is needed.
_extract_ci_skeleton_section() {
    cat "$SKILL_MD" 2>/dev/null
}

# test_python_hashfiles_conditional
# Assert that the CI skeleton section contains a Python block whose dependency
# cache key uses hashFiles() gated on requirements.txt or pyproject.toml,
# with root-relative paths (no leading ./ or /).
#
# RED: SKILL.md has no CI skeleton section → extracted block is empty → grep fails.
test_python_hashfiles_conditional() {
    _snapshot_fail
    local section python_found
    section="$(_extract_ci_skeleton_section)"
    python_found="missing"
    # Check for hashFiles() referencing a Python dependency file
    if printf '%s\n' "$section" | grep -qE "hashFiles\(['\"]?(requirements\.txt|pyproject\.toml)['\"]?\)"; then
        python_found="found"
    fi
    assert_eq "test_python_hashfiles_conditional" "found" "$python_found"
    assert_pass_if_clean "test_python_hashfiles_conditional"
}

# test_node_hashfiles_conditional
# Assert that the CI skeleton section contains a Node block whose dependency
# cache key uses hashFiles() gated on package-lock.json or yarn.lock.
#
# RED: SKILL.md has no CI skeleton section → extracted block is empty → grep fails.
test_node_hashfiles_conditional() {
    _snapshot_fail
    local section node_found
    section="$(_extract_ci_skeleton_section)"
    node_found="missing"
    if printf '%s\n' "$section" | grep -qE "hashFiles\(['\"]?(package-lock\.json|yarn\.lock)['\"]?\)"; then
        node_found="found"
    fi
    assert_eq "test_node_hashfiles_conditional" "found" "$node_found"
    assert_pass_if_clean "test_node_hashfiles_conditional"
}

# test_ruby_hashfiles_conditional
# Assert that the CI skeleton section contains a Ruby block whose dependency
# cache key uses hashFiles() gated on Gemfile.lock or Gemfile.
#
# RED: SKILL.md has no CI skeleton section → extracted block is empty → grep fails.
test_ruby_hashfiles_conditional() {
    _snapshot_fail
    local section ruby_found
    section="$(_extract_ci_skeleton_section)"
    ruby_found="missing"
    if printf '%s\n' "$section" | grep -qE "hashFiles\(['\"]?(Gemfile\.lock|Gemfile)['\"]?\)"; then
        ruby_found="found"
    fi
    assert_eq "test_ruby_hashfiles_conditional" "found" "$ruby_found"
    assert_pass_if_clean "test_ruby_hashfiles_conditional"
}

# test_blocks_structurally_isolated
# Assert that each language's hashFiles() block is self-contained — no line
# mixes hashFiles() targets from multiple languages on the same line
# (e.g., "hashFiles('requirements.txt', 'package-lock.json')" is a violation).
# We detect this by checking that no single hashFiles() call references
# dependency files from more than one language ecosystem.
#
# RED: SKILL.md has no CI skeleton section → extracted block is empty → no
# multi-language lines exist → the negative assertion would pass, BUT because
# there is also no CI skeleton section at all the previous tests already fail,
# and this test additionally verifies isolation structure once the section
# exists. For RED enforcement, we also assert the section is non-empty.
test_blocks_structurally_isolated() {
    _snapshot_fail
    local section section_nonempty interleaved_found isolation_ok
    section="$(_extract_ci_skeleton_section)"

    # The section must exist (non-empty) — if SKILL.md has no CI skeleton section,
    # this test fails to enforce the structural invariant.
    if [[ -z "$section" ]]; then
        section_nonempty="missing"
    else
        section_nonempty="found"
    fi
    assert_eq "test_blocks_structurally_isolated (section_exists)" "found" "$section_nonempty"

    # No single hashFiles() call should mix Python and Node dependency files.
    interleaved_found="not-interleaved"
    if printf '%s\n' "$section" | grep -qE "hashFiles\(.*requirements\.txt.*package-lock\.json|hashFiles\(.*package-lock\.json.*requirements\.txt|hashFiles\(.*Gemfile.*package-lock\.json|hashFiles\(.*package-lock\.json.*Gemfile"; then
        interleaved_found="interleaved"
    fi
    assert_eq "test_blocks_structurally_isolated (no_interleaving)" "not-interleaved" "$interleaved_found"

    assert_pass_if_clean "test_blocks_structurally_isolated"
}

# test_paths_root_relative
# Assert that all hashFiles() paths in the CI skeleton section are root-relative
# (no leading ./ or /). Valid: "requirements.txt". Invalid: "./requirements.txt",
# "/requirements.txt".
#
# RED: SKILL.md has no CI skeleton section → extracted block is empty → the
# section_nonempty sub-assertion fails.
test_paths_root_relative() {
    _snapshot_fail
    local section section_nonempty bad_paths_found
    section="$(_extract_ci_skeleton_section)"

    # Section must exist.
    if [[ -z "$section" ]]; then
        section_nonempty="missing"
    else
        section_nonempty="found"
    fi
    assert_eq "test_paths_root_relative (section_exists)" "found" "$section_nonempty"

    # All hashFiles() arguments must be root-relative (no leading ./ or /).
    bad_paths_found="none"
    if printf '%s\n' "$section" | grep -qE "hashFiles\(['\"](\./|/)"; then
        bad_paths_found="found"
    fi
    assert_eq "test_paths_root_relative (no_leading_slash_or_dot)" "none" "$bad_paths_found"

    assert_pass_if_clean "test_paths_root_relative"
}

# Run all 5 test functions — all RED (FAIL) on current SKILL.md
test_python_hashfiles_conditional
test_node_hashfiles_conditional
test_ruby_hashfiles_conditional
test_blocks_structurally_isolated
test_paths_root_relative

print_summary
