#!/usr/bin/env bash
# tests/scripts/test-roundtrip-live-arm-failclosed.sh
#
# Story a85d-5f7f-8898-4a4f — "Harden the R8 live drift guard" (§2.9 / CS-17).
#
# Behavioral contract under test (test-ruleset-provisioner-roundtrip.sh's
# _live_round_trip): a live-arm precondition SKIP (no token / gh api rulesets
# failure / rulesets-not-found) must be FAIL-CLOSED under the enforce posture
# flag (DSO_RULESET_INVARIANTS_MODE=enforce) — the whole test must exit NON-ZERO
# so a PAT expiry / scope-strip cannot silently re-open the R8 live-parity hole.
# In warn/default the same SKIP must remain a soft skip (exit 0, offline
# assertions still ran). This proves the durability fix is real, not cosmetic.
#
# These are end-to-end behavioral assertions: we run the actual round-trip
# script with a forced live-arm skip (unset GH_TOKEN + a sabotaged PATH that
# hides `gh`) and assert the exit code by posture. python3/jq must be present so
# the OFFLINE assertions reach _live_round_trip; if not, this harness self-skips.

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
TARGET="$REPO_ROOT/tests/scripts/test-ruleset-provisioner-roundtrip.sh"

PASS=0
FAIL=0
_pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
_fail() { echo "FAIL: $1 ($2)"; FAIL=$((FAIL+1)); }

# OFFLINE assertions in the target need python3 + jq; without them the target
# exits 78 before ever reaching _live_round_trip, so this behavioral test cannot
# exercise the live-arm path. Self-skip cleanly in that case.
if ! command -v python3 >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
    echo "SKIP: python3/jq not in PATH — cannot reach _live_round_trip; harness self-skip"
    echo ""
    echo "PASSED: 0  FAILED: 0"
    exit 0
fi

# Force the live arm to SKIP deterministically WITHOUT breaking the OFFLINE
# assertions: keep the real PATH (the provisioner dry-run needs its full
# toolset), but PREPEND a dir whose only override is a failing `gh` stub. With
# GH_TOKEN unset, `gh auth status` then fails → the target takes the first
# live-arm skip branch. No network, no real auth, offline assertions intact.
_fakebin="$(mktemp -d "${TMPDIR:-/tmp}/dso-failclosed-bin.XXXXXX")"
trap 'rm -rf "$_fakebin"' EXIT
cat >"$_fakebin/gh" <<'STUB'
#!/usr/bin/env bash
# Always-failing gh stub: forces the live-arm precondition skip path.
exit 1
STUB
chmod +x "$_fakebin/gh"

# Run the target with the live arm forced to SKIP, under a given posture.
# Returns the target's exit code; prints nothing to our streams.
_run_target() {
    local mode="$1"
    env -u GH_TOKEN \
        PATH="$_fakebin:$PATH" \
        DSO_RULESET_INVARIANTS_MODE="$mode" \
        GH_REPO="navapbc/digital-service-orchestra" \
        bash "$TARGET" >/dev/null 2>&1
    echo $?
}

# ── Behavior 1: warn posture → live-arm skip is a soft skip → exit 0 ──────────
warn_rc="$(_run_target warn)"
if [[ "$warn_rc" -eq 0 ]]; then
    _pass "warn_posture_live_arm_skip_exits_zero"
else
    _fail "warn_posture_live_arm_skip_exits_zero" "expected exit 0, got $warn_rc"
fi

# ── Behavior 2: enforce posture → live-arm skip is fail-closed → exit non-zero ─
enforce_rc="$(_run_target enforce)"
if [[ "$enforce_rc" -ne 0 ]]; then
    _pass "enforce_posture_live_arm_skip_fails_closed"
else
    _fail "enforce_posture_live_arm_skip_fails_closed" \
        "expected non-zero exit (fail-closed), got $enforce_rc — live arm silently green"
fi

# ── Behavior 3: default (unset) posture behaves like warn → exit 0 ────────────
default_rc="$(env -u GH_TOKEN -u DSO_RULESET_INVARIANTS_MODE \
    PATH="$_fakebin:$PATH" GH_REPO="navapbc/digital-service-orchestra" \
    bash "$TARGET" >/dev/null 2>&1; echo $?)"
if [[ "$default_rc" -eq 0 ]]; then
    _pass "default_posture_defaults_to_warn_exits_zero"
else
    _fail "default_posture_defaults_to_warn_exits_zero" "expected exit 0, got $default_rc"
fi

echo ""
echo "PASSED: $PASS  FAILED: $FAIL"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
