#!/usr/bin/env bash
# tests/docs/test-reviewer-blindspot-annotations.sh
#
# Structural boundary test (Rule 5 of behavioral-testing-standard.md):
# Each of the five reviewer-delta files consumed by build-review-agents.sh
# must include a "## AI Blindspot Annotations" section heading. This is a
# structural boundary check: we assert the section heading exists in the
# generated reviewer agent output, not the body wording.
#
# We exercise the actual build-review-agents.sh script (executes real code,
# Rule 3) and inspect the produced agent files in an isolated temp directory.
# The section heading is part of each delta file, so it must appear in the
# generated agent file when the delta is composed with the base.
#
# RED phase: tests FAIL because the "## AI Blindspot Annotations" section
# is not yet present in any reviewer-delta-*.md file.

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
ASSERT_LIB="$REPO_ROOT/tests/lib/assert.sh"
# shellcheck source=../lib/assert.sh
source "$ASSERT_LIB"

BUILD_SCRIPT="$REPO_ROOT/plugins/dso/scripts/build-review-agents.sh"
HEADING='## AI Blindspot Annotations'

# Track temp dirs for cleanup
_TEST_TMPDIRS=()
_cleanup() {
    for d in "${_TEST_TMPDIRS[@]:-}"; do
        [[ -n "$d" && -d "$d" ]] && rm -rf "$d"
    done
}
trap _cleanup EXIT

# Helper: run build script into a fresh temp dir, then check whether the
# generated agent file for the given tier contains the expected heading.
# Echoes "1" if the heading is found, "0" otherwise.
_check_tier_has_blindspot_heading() {
    local tier="$1"
    local tmpdir
    tmpdir="$(mktemp -d)"
    _TEST_TMPDIRS+=("$tmpdir")

    bash "$BUILD_SCRIPT" --output "$tmpdir" >/dev/null 2>&1

    local agent_file="$tmpdir/code-reviewer-${tier}.md"
    if [[ ! -f "$agent_file" ]]; then
        echo "0"
        return
    fi

    if grep -q "^${HEADING}\$" "$agent_file"; then
        echo "1"
    else
        echo "0"
    fi
}

test_blindspot_in_deep_hygiene() {
    echo "=== test_blindspot_in_deep_hygiene ==="
    local found
    found="$(_check_tier_has_blindspot_heading "deep-hygiene")"
    assert_eq \
        "deep-hygiene reviewer agent contains '## AI Blindspot Annotations' section" \
        "1" \
        "$found"
}

test_blindspot_in_deep_correctness() {
    echo "=== test_blindspot_in_deep_correctness ==="
    local found
    found="$(_check_tier_has_blindspot_heading "deep-correctness")"
    assert_eq \
        "deep-correctness reviewer agent contains '## AI Blindspot Annotations' section" \
        "1" \
        "$found"
}

test_blindspot_in_deep_arch() {
    echo "=== test_blindspot_in_deep_arch ==="
    local found
    found="$(_check_tier_has_blindspot_heading "deep-arch")"
    assert_eq \
        "deep-arch reviewer agent contains '## AI Blindspot Annotations' section" \
        "1" \
        "$found"
}

test_blindspot_in_standard() {
    echo "=== test_blindspot_in_standard ==="
    local found
    found="$(_check_tier_has_blindspot_heading "standard")"
    assert_eq \
        "standard reviewer agent contains '## AI Blindspot Annotations' section" \
        "1" \
        "$found"
}

test_blindspot_in_light() {
    echo "=== test_blindspot_in_light ==="
    local found
    found="$(_check_tier_has_blindspot_heading "light")"
    assert_eq \
        "light reviewer agent contains '## AI Blindspot Annotations' section" \
        "1" \
        "$found"
}

# Dispatch
test_blindspot_in_deep_hygiene
test_blindspot_in_deep_correctness
test_blindspot_in_deep_arch
test_blindspot_in_standard
test_blindspot_in_light

print_summary
