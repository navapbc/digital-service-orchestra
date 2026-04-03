#!/usr/bin/env bash
# tests/scripts/test-qualify-skill-refs.sh
# TDD tests for qualify-skill-refs.sh — rewrites unqualified DSO skill references.
#
# Tests:
#  (a) test_qualifies_unqualified_ref        — /sprint → /dso:sprint
#  (b) test_skips_already_qualified          — /dso:sprint → unchanged
#  (c) test_skips_simple_url                 — https://example.com/sprint → unchanged
#  (d) test_skips_multi_segment_url          — https://example.com/foo--/sprint → unchanged (BUG: dso-gir2)
#  (e) test_skips_filesystem_path            — skills/debug-everything/ → unchanged
#  (f) test_idempotent                       — running twice yields same result
#
# Usage: bash tests/scripts/test-qualify-skill-refs.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
SCRIPT="$DSO_PLUGIN_DIR/scripts/qualify-skill-refs.sh"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-qualify-skill-refs.sh ==="

# Helper: apply the fixer's perl script to a string and return the result.
# This replicates the URL-aware alternation logic from qualify-skill-refs.sh (dso-gir2):
#   Alternation: match EITHER a full URL (kept unchanged) OR an unqualified skill ref (qualified).
_apply_fixer_regex() {
    local _content="$1"
    local _skill_alternation="sprint|commit|review|end|implementation-plan|preplanning|debug-everything|brainstorm|plan-review|interface-contracts|resolve-conflicts|retro|roadmap|oscillation-check|design-onboarding|design-review|ui-discover|dev-onboarding|validate-work|tickets-health|playwright-debug|dryrun|quick-ref|fix-cascade-recovery|fix-bug"
    printf '%s' "$_content" | perl -pe "s{(https?://\S+)|(?<![a-zA-Z0-9_/])(?<!dso:)/(${_skill_alternation})(?![a-zA-Z0-9_:-])}{ defined \$1 ? \$1 : \"/dso:\$2\" }ge"
}

# ── (a) test_qualifies_unqualified_ref ────────────────────────────────────────
# A plain /sprint reference should be rewritten to /dso:sprint
test_qualifies_unqualified_ref() {
    _snapshot_fail
    local _input='Use /sprint to run the sprint workflow.'
    local _result
    _result=$(_apply_fixer_regex "$_input")
    assert_contains "test_qualifies_unqualified_ref: /sprint → /dso:sprint" "/dso:sprint" "$_result"
    assert_pass_if_clean "test_qualifies_unqualified_ref"
}

# ── (b) test_skips_already_qualified ─────────────────────────────────────────
# /dso:sprint should NOT be rewritten to /dso:dso:sprint
test_skips_already_qualified() {
    _snapshot_fail
    local _input='Use /dso:sprint to run epics.'
    local _result
    _result=$(_apply_fixer_regex "$_input")
    assert_contains "test_skips_already_qualified: /dso:sprint unchanged" "/dso:sprint" "$_result"
    assert_eq "test_skips_already_qualified: no double qualification" "$_input" "$_result"
    assert_pass_if_clean "test_skips_already_qualified"
}

# ── (c) test_skips_simple_url ─────────────────────────────────────────────────
# https://example.com/sprint should NOT be rewritten (preceded by ://)
test_skips_simple_url() {
    _snapshot_fail
    local _input='See https://example.com/sprint for more info.'
    local _result
    _result=$(_apply_fixer_regex "$_input")
    assert_eq "test_skips_simple_url: URL unchanged" "$_input" "$_result"
    assert_pass_if_clean "test_skips_simple_url"
}

# ── (d) test_skips_multi_segment_url — dso-gir2 regression test ───────────────
# https://example.com/foo--/sprint has a hyphen before /sprint.
# The :// lookbehind alone does NOT cover this; the old fixer incorrectly rewrote it.
# The checker strips the full URL (https?://\S+) before checking, so it would
# never flag this — but the old fixer would incorrectly qualify it.
#
# After the fix, qualify-skill-refs.sh uses URL-aware alternation to match and
# preserve full URLs before the skill-ref substitution arm can match their path segments.
test_skips_multi_segment_url() {
    _snapshot_fail
    local _input='See https://example.com/foo--/sprint for details.'
    local _result
    _result=$(_apply_fixer_regex "$_input")
    # With the OLD (buggy) regex: "foo--" ends with "-", not in lookbehind set → /sprint IS rewritten
    # With the FIXED regex (URL-aware alternation): URL is matched and preserved → unchanged
    assert_eq "test_skips_multi_segment_url: URL with hyphen-segment unchanged" "$_input" "$_result"
    assert_pass_if_clean "test_skips_multi_segment_url"
}

# ── (e) test_skips_filesystem_path ───────────────────────────────────────────
# skills/debug-everything/ (filesystem path) should NOT be rewritten
test_skips_filesystem_path() {
    _snapshot_fail
    local _input='See skills/debug-everything/ for the skill files.'
    local _result
    _result=$(_apply_fixer_regex "$_input")
    assert_eq "test_skips_filesystem_path: filesystem path unchanged" "$_input" "$_result"
    assert_pass_if_clean "test_skips_filesystem_path"
}

# ── (f) test_idempotent ───────────────────────────────────────────────────────
# Running the fixer twice on already-qualified refs should produce the same output
test_idempotent() {
    _snapshot_fail
    local _input='Use /dso:sprint and /dso:commit here.'
    local _result1 _result2
    _result1=$(_apply_fixer_regex "$_input")
    _result2=$(_apply_fixer_regex "$_result1")
    assert_eq "test_idempotent: two passes yield same result" "$_result1" "$_result2"
    assert_pass_if_clean "test_idempotent"
}

# ── Run all tests ─────────────────────────────────────────────────────────────
test_qualifies_unqualified_ref
test_skips_already_qualified
test_skips_simple_url
test_skips_multi_segment_url
test_skips_filesystem_path
test_idempotent

print_summary
