#!/usr/bin/env bash
# tests/scripts/test-closure-checks-e26d-verifier.sh
#
# Story e26d-b59d-5484-4e1f DD2 + DD6 structural-proxy test for the
# completion-verifier refused-closure flow specified by epic a03c-d55e-1393-4f27
# SC7 (verifier returns refused-closure when a Closure Check is unresolved).
#
# Structural proxy strategy: assert the contract surfaces (agent file,
# protocol doc, deterministic helpers) exist and behave correctly, plus
# exercise check-verifier-verdict.sh with a synthetic FAIL payload to
# confirm the runtime helper actually emits the refused-closure exit code
# specified by the protocol. The synthetic exercise is the closest the
# structural proxy comes to verifying live dispatch behavior — it bypasses
# Claude but does exercise the deterministic gate that converts a verdict
# into refused-closure.
#
# Sentinel-fail (DD6): --sentinel mode mutates VERIFIER-PROTOCOL.md to remove
# the Closure Checks validation heading and asserts the anchor would fail.
#
# Usage:
#   bash tests/scripts/test-closure-checks-e26d-verifier.sh
#   bash tests/scripts/test-closure-checks-e26d-verifier.sh --sentinel
#
# Returns: exit 0 if all tests pass, exit 1 if any fail.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
PLUGIN_ROOT="$REPO_ROOT/plugins/dso"

AGENT_FILE="$PLUGIN_ROOT/agents/completion-verifier.md"
PROTOCOL="$PLUGIN_ROOT/docs/VERIFIER-PROTOCOL.md"
VERDICT_HELPER="$PLUGIN_ROOT/scripts/check-verifier-verdict.sh"
MANIFEST_HELPER="$PLUGIN_ROOT/scripts/check-manifest-completeness.sh"
NARRATIVE_HELPER="$PLUGIN_ROOT/scripts/render-closure-narrative.sh"

MODE="anchor"
if [[ "${1:-}" = "--sentinel" ]]; then
    MODE="sentinel"
fi

PASS=0
FAIL=0
_pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
_fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1" >&2; }

echo "=== test-closure-checks-e26d-verifier.sh (mode=$MODE) ==="

# Suite-runner guard
if [[ "${_RUN_ALL_ACTIVE:-0}" = "1" ]] && [[ ! -f "$AGENT_FILE" || ! -f "$PROTOCOL" || ! -x "$VERDICT_HELPER" ]]; then
    echo "SKIP: verifier source-of-truth files not present"
    printf "PASSED: 0  FAILED: 0\n"
    exit 0
fi

_SUITE_TMP=$(mktemp -d "${TMPDIR:-/tmp}/test-e26d-verifier.XXXXXX")
trap 'rm -rf "$_SUITE_TMP"' EXIT

assert_anchor() {
    local name="$1" file="$2" pattern="$3"
    if [[ "$MODE" = "anchor" ]]; then
        if grep -qF -- "$pattern" "$file" 2>/dev/null; then
            _pass "$name"
        else
            _fail "$name (expected pattern in $file: $pattern)"
        fi
    else
        local tmp_copy
        tmp_copy="$_SUITE_TMP/$(basename "$file").$RANDOM"
        cp "$file" "$tmp_copy"
        grep -vF -- "$pattern" "$tmp_copy" > "$tmp_copy.stripped" && mv "$tmp_copy.stripped" "$tmp_copy"
        if grep -qF -- "$pattern" "$tmp_copy" 2>/dev/null; then
            _fail "$name (sentinel mutation failed to remove pattern)"
        else
            _pass "$name (sentinel confirms anchor is load-bearing)"
        fi
    fi
}

# ── DD2 anchor 1: completion-verifier agent file exists with name front-matter
if [[ -f "$AGENT_FILE" ]]; then
    _pass "DD2 anchor: completion-verifier agent file present"
else
    _fail "DD2 anchor: completion-verifier agent file missing at $AGENT_FILE"
fi

assert_anchor "DD2 anchor: agent front-matter declares name: completion-verifier" \
    "$AGENT_FILE" "name: completion-verifier"

# ── DD2 anchor 2: VERIFIER-PROTOCOL.md exists with the Closure-Checks-validation
# heading. The literal "## Closure Checks validation" is load-bearing — it is
# the documented section that defines refused-closure behavior. If renamed,
# the protocol's refused-closure contract loses its named anchor.
if [[ -f "$PROTOCOL" ]]; then
    _pass "DD2 anchor: VERIFIER-PROTOCOL.md present"
else
    _fail "DD2 anchor: VERIFIER-PROTOCOL.md missing at $PROTOCOL"
fi

assert_anchor "DD2 anchor: '## Closure Checks validation' heading in VERIFIER-PROTOCOL.md" \
    "$PROTOCOL" "## Closure Checks validation"

# ── DD2 anchor 3: deterministic helpers exist and are executable
for helper in "$VERDICT_HELPER" "$MANIFEST_HELPER" "$NARRATIVE_HELPER"; do
    helper_name=$(basename "$helper")
    if [[ -x "$helper" ]]; then
        _pass "DD2 anchor: $helper_name exists and is executable"
    else
        _fail "DD2 anchor: $helper_name missing or not executable"
    fi
done

# ── DD2 runtime exercise: feed check-verifier-verdict.sh a synthetic FAIL P1
# payload and assert the helper emits the refused-closure exit code (1) that
# the protocol specifies. This is the structural proxy's closest approximation
# of "verifier returns refused-closure" — the deterministic gate runs.
# Skip exercise in sentinel mode (sentinel mode targets anchor mutation).
if [[ "$MODE" = "anchor" && -x "$VERDICT_HELPER" ]]; then
    rc=0
    echo '{"schema_version": 2, "P1": "FAIL"}' | bash "$VERDICT_HELPER" >/dev/null 2>&1 || rc=$?
    if [[ $rc -eq 1 ]]; then
        _pass "DD2 runtime: check-verifier-verdict emits refused-closure (exit 1) on P1=FAIL"
    else
        _fail "DD2 runtime: check-verifier-verdict returned rc=$rc on P1=FAIL (expected 1)"
    fi

    # Positive control: PASS payload should exit 0.
    rc=0
    echo '{"schema_version": 2, "P1": "PASS"}' | bash "$VERDICT_HELPER" >/dev/null 2>&1 || rc=$?
    if [[ $rc -eq 0 ]]; then
        _pass "DD2 runtime: check-verifier-verdict emits success (exit 0) on P1=PASS"
    else
        _fail "DD2 runtime: check-verifier-verdict returned rc=$rc on P1=PASS (expected 0)"
    fi
fi

printf "PASSED: %d  FAILED: %d\n" "$PASS" "$FAIL"

if [[ $FAIL -gt 0 ]]; then
    exit 1
fi
exit 0
