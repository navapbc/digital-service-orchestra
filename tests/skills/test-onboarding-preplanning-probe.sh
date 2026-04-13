#!/usr/bin/env bash
# tests/skills/test-onboarding-preplanning-probe.sh
# RED tests for story cde0-f2eb:
#   onboarding/SKILL.md must include a probe question for preplanning.interactive
#   and explicit-overwrite semantics for pre-existing dso-config.conf entries.
#
# Assertions (both must pass):
#   test_preplanning_interactive_probe: SKILL.md contains a probe question for
#     preplanning.interactive (asking operator whether preplanning should be interactive)
#   test_preplanning_interactive_explicit_overwrite: SKILL.md documents that
#     preplanning.interactive is explicitly overwritten even when key already exists
#     (unlike other merge-not-overwrite config keys)
#
# Per behavioral-testing-standard.md Rule 5: for non-executable LLM instruction
# files like SKILL.md, test structural boundaries via grep patterns, not execution.
#
# Usage: bash tests/skills/test-onboarding-preplanning-probe.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SKILL_MD="$PLUGIN_ROOT/plugins/dso/skills/onboarding/SKILL.md"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-onboarding-preplanning-probe.sh ==="

# ---------------------------------------------------------------------------
# test_preplanning_interactive_probe
# SKILL.md must contain a probe question for preplanning.interactive.
# Must reference both "preplanning.interactive" (the config key) and ask
# whether preplanning should be interactive (true/false or similar phrasing).
# ---------------------------------------------------------------------------
test_preplanning_interactive_probe() {
    _snapshot_fail
    local has_config_key has_probe_question result
    has_config_key="no"
    has_probe_question="no"

    # Check for the config key reference
    if grep -qF "preplanning.interactive" "$SKILL_MD" 2>/dev/null; then
        has_config_key="yes"
    fi

    # Check for a probe question pattern (asking about interactive/interactively)
    if grep -qiE "preplanning.*interactive|interactive.*preplanning" "$SKILL_MD" 2>/dev/null; then
        has_probe_question="yes"
    fi

    if [[ "$has_config_key" == "yes" && "$has_probe_question" == "yes" ]]; then
        result="found"
    else
        result="missing"
    fi

    assert_eq "test_preplanning_interactive_probe" "found" "$result"
    assert_pass_if_clean "test_preplanning_interactive_probe"
}

# ---------------------------------------------------------------------------
# test_preplanning_interactive_explicit_overwrite
# SKILL.md must document that preplanning.interactive is explicitly overwritten
# even when the key already exists in dso-config.conf.
# This is an exception to the general merge-not-overwrite behavior.
# Must reference both the key AND overwrite semantics.
# ---------------------------------------------------------------------------
test_preplanning_interactive_explicit_overwrite() {
    _snapshot_fail
    local has_key has_overwrite_semantics result
    has_key="no"
    has_overwrite_semantics="no"

    # Check for the config key reference
    if grep -qF "preplanning.interactive" "$SKILL_MD" 2>/dev/null; then
        has_key="yes"
    fi

    # Check for explicit overwrite semantics near preplanning.interactive.
    # The instruction must say that this key is OVERWRITTEN (not skipped) even
    # when it already exists. Accept: "overwrite", "always write", "even if.*exists",
    # "regardless.*exists", "replace.*existing".
    if grep -qiE "overwrite.*preplanning\.interactive|preplanning\.interactive.*overwrite|always write.*preplanning|preplanning.*always write|even if.*preplanning\.interactive.*exists|preplanning\.interactive.*even if.*exists" "$SKILL_MD" 2>/dev/null; then
        has_overwrite_semantics="yes"
    fi

    if [[ "$has_key" == "yes" && "$has_overwrite_semantics" == "yes" ]]; then
        result="found"
    else
        result="missing"
    fi

    assert_eq "test_preplanning_interactive_explicit_overwrite" "found" "$result"
    assert_pass_if_clean "test_preplanning_interactive_explicit_overwrite"
}

# Run tests
test_preplanning_interactive_probe
test_preplanning_interactive_explicit_overwrite

print_summary
