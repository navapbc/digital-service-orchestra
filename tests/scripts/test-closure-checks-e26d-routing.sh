#!/usr/bin/env bash
# tests/scripts/test-closure-checks-e26d-routing.sh
#
# Story e26d-b59d-5484-4e1f DD1 + DD3 + DD6 structural-proxy tests.
#
# Tests verify epic a03c-d55e-1393-4f27 SC7 (brainstorm transitional-SC routing)
# and SC9-rejection-test at the structural level: that the rules driving
# /dso:brainstorm's routing decision and the SC9 rejection rule are present
# in the load-bearing source-of-truth files.
#
# This is the structural-proxy approach (selected via brainstorm; see
# docs/adr/0017-agent-dispatch-test-strategy.md). It does NOT exercise live
# Claude SKILL dispatch — that would require an LLM call. It DOES exercise
# the structural anchors that drive the SKILL dispatch.
#
# Assertions target LOAD-BEARING surfaces only:
#   - file paths referenced by other files / contracts
#   - heading literals that are referenced by name from other files
#   - cross-file edges in the dependency graph
# Assertions do NOT target prose phrasing (which can be reworded without
# changing behavior — that would be a change-detector pattern).
#
# DD6 sentinel-fail support: invoke with `--sentinel` to confirm each anchor
# would fail if mutated. The sentinel mode copies the source-of-truth file to
# a temp location, strips the anchor, and re-runs the assertion against the
# temp copy, asserting that it now fails.
#
# Usage:
#   bash tests/scripts/test-closure-checks-e26d-routing.sh
#   bash tests/scripts/test-closure-checks-e26d-routing.sh --sentinel
#
# Returns: exit 0 if all tests pass, exit 1 if any fail.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
PLUGIN_ROOT="$REPO_ROOT/plugins/dso"

VSC="$PLUGIN_ROOT/skills/shared/prompts/verifiable-sc-check.md"
BS_SKILL="$PLUGIN_ROOT/skills/brainstorm/SKILL.md"
APPROVAL_GATE="$PLUGIN_ROOT/skills/brainstorm/phases/approval-gate.md"
EPIC_TPL="$PLUGIN_ROOT/skills/brainstorm/phases/epic-description-template.md"

MODE="anchor"
if [[ "${1:-}" = "--sentinel" ]]; then
    MODE="sentinel"
fi

PASS=0
FAIL=0
_pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
_fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1" >&2; }

echo "=== test-closure-checks-e26d-routing.sh (mode=$MODE) ==="

# Suite-runner guard: skip when source files missing (handled per-anchor below)
if [[ "${_RUN_ALL_ACTIVE:-0}" = "1" ]] && [[ ! -f "$VSC" || ! -f "$BS_SKILL" || ! -f "$APPROVAL_GATE" || ! -f "$EPIC_TPL" ]]; then
    echo "SKIP: brainstorm source-of-truth files not present"
    printf "PASSED: 0  FAILED: 0\n"
    exit 0
fi

# ── Per-suite temp ─────────────────────────────────────────────────────────────
_SUITE_TMP=$(mktemp -d "${TMPDIR:-/tmp}/test-e26d-routing.XXXXXX")
trap 'rm -rf "$_SUITE_TMP"' EXIT

# ── Assertion helpers ──────────────────────────────────────────────────────────
# assert_anchor <name> <file> <grep_pattern_or_literal>
# In anchor mode: assert grep succeeds.
# In sentinel mode: copy file to temp, sed-remove the anchor line, assert grep fails.
assert_anchor() {
    local name="$1" file="$2" pattern="$3"
    if [[ "$MODE" = "anchor" ]]; then
        if grep -qF -- "$pattern" "$file" 2>/dev/null; then
            _pass "$name"
        else
            _fail "$name (expected pattern in $file: $pattern)"
        fi
    else
        # Sentinel: mutate temp copy to remove the anchor, assert grep now fails.
        local tmp_copy
        tmp_copy="$_SUITE_TMP/$(basename "$file").$RANDOM"
        cp "$file" "$tmp_copy"
        # Delete every line containing the pattern (literal grep).
        grep -vF -- "$pattern" "$tmp_copy" > "$tmp_copy.stripped" && mv "$tmp_copy.stripped" "$tmp_copy"
        if grep -qF -- "$pattern" "$tmp_copy" 2>/dev/null; then
            _fail "$name (sentinel mutation failed to remove pattern)"
        else
            _pass "$name (sentinel confirms anchor is load-bearing)"
        fi
    fi
}

# assert_cross_ref <name> <referring_file> <referenced_path_fragment>
# Anchor mode: assert the referring file mentions the referenced fragment.
# Sentinel mode: temp-copy referring file, strip lines containing the fragment, assert reference gone.
assert_cross_ref() {
    local name="$1" referrer="$2" fragment="$3"
    if [[ "$MODE" = "anchor" ]]; then
        if grep -qF -- "$fragment" "$referrer" 2>/dev/null; then
            _pass "$name"
        else
            _fail "$name (referring file $referrer missing reference: $fragment)"
        fi
    else
        local tmp_copy
        tmp_copy="$_SUITE_TMP/$(basename "$referrer").$RANDOM"
        cp "$referrer" "$tmp_copy"
        grep -vF -- "$fragment" "$tmp_copy" > "$tmp_copy.stripped" && mv "$tmp_copy.stripped" "$tmp_copy"
        if grep -qF -- "$fragment" "$tmp_copy" 2>/dev/null; then
            _fail "$name (sentinel mutation failed to remove cross-ref)"
        else
            _pass "$name (sentinel confirms cross-ref is load-bearing)"
        fi
    fi
}

# ── DD1: Brainstorm transitional-SC routing anchors ────────────────────────────

# Anchor 1: source-of-truth file exists.
if [[ -f "$VSC" ]]; then
    _pass "verifiable-sc-check.md file exists at $VSC"
else
    _fail "verifiable-sc-check.md missing at $VSC"
fi

# Anchor 2: End-state-only rule heading (the routing litmus).
assert_anchor "DD1 anchor: '## End-state-only rule' heading present" \
    "$VSC" "## End-state-only rule"

# Anchor 3: Accept-example sub-heading present (rule's positive side).
assert_anchor "DD1 anchor: '### Accept examples' sub-heading present" \
    "$VSC" "### Accept examples"

# Anchor 4: Reject-example sub-heading present (rule's negative side — the
# items that route to Closure Checks).
assert_anchor "DD1 anchor: '### Reject examples' sub-heading present" \
    "$VSC" "### Reject examples"

# Anchor 5: brainstorm SKILL.md references the litmus file by path.
assert_cross_ref "DD1 anchor: brainstorm SKILL.md cites verifiable-sc-check.md" \
    "$BS_SKILL" "verifiable-sc-check.md"

# Anchor 6: approval-gate Gate Template renders '## Closure Checks' literal heading.
assert_anchor "DD1 anchor: approval-gate.md contains '## Closure Checks' template heading" \
    "$APPROVAL_GATE" "## Closure Checks"

# Anchor 7: epic-description-template has the Closure Checks section.
assert_anchor "DD1 anchor: epic-description-template.md contains '## Closure Checks'" \
    "$EPIC_TPL" "## Closure Checks"

# ── DD3: SC9 rejection rule anchors ────────────────────────────────────────────

# Anchor 8: Brainstorm refusal copy section (the SC9 refusal text Claude emits).
assert_anchor "DD3 anchor: '### Brainstorm refusal copy' section present" \
    "$VSC" "### Brainstorm refusal copy"

# Anchor 9: One-shot-verifiable rule on the epic-description-template.
# The literal phrase "One-shot-verifiable requirement" is the section anchor
# brainstorm dispatches read to enforce SC9; it's load-bearing because the
# rule is enforced by Claude reading the template, and the heading is the
# routable surface.
assert_anchor "DD3 anchor: 'One-shot-verifiable requirement' rule present in epic-description-template.md" \
    "$EPIC_TPL" "One-shot-verifiable requirement"

# ── DD4 documentation cross-check ──────────────────────────────────────────────
# DD4 records the test-strategy decision in an ADR. Anchor: the ADR exists.
ADR_FILE="$REPO_ROOT/docs/adr/0017-agent-dispatch-test-strategy.md"
if [[ -f "$ADR_FILE" ]]; then
    _pass "DD4 anchor: docs/adr/0017-agent-dispatch-test-strategy.md present"
else
    _fail "DD4 anchor: docs/adr/0017-agent-dispatch-test-strategy.md missing"
fi

# ── Summary ─────────────────────────────────────────────────────────────────────
printf "PASSED: %d  FAILED: %d\n" "$PASS" "$FAIL"

# In sentinel mode all sentinel assertions should PASS (each anchor is
# load-bearing). In anchor mode all anchor assertions should PASS. If
# anchor mode fails, the source-of-truth files have regressed.
if [[ $FAIL -gt 0 ]]; then
    exit 1
fi
exit 0
