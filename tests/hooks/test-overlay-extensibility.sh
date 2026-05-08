#!/usr/bin/env bash
# tests/hooks/test-overlay-extensibility.sh
# UPDATE tests: extensibility invariant for overlay-registry pattern.
#
# Task d510-f6c2-23b8-4241
#
# Invariant: adding a new overlay entry to overlay-registry.json (without
# changing verifier code) automatically causes the verifier to check for that
# overlay's findings file.
#
# All 3 tests are UPDATE classification — expected to pass immediately against
# the current verifier implementation which respects OVERLAY_REGISTRY_PATH.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
HOOK="$REPO_ROOT/plugins/dso/hooks/pre-commit-compliance-verifier.sh"

source "$REPO_ROOT/tests/lib/assert.sh"

# ---------------------------------------------------------------------------
# Helper: write all 5 required base step artifacts into a directory
# ---------------------------------------------------------------------------
write_base_artifacts() {
    local dir="$1"
    printf '{"step":"test","exit_code":0,"stdout":"","stderr":"","timestamp":"2026-01-01T00:00:00Z"}\n' \
        > "$dir/test.result"
    printf '{"step":"format","exit_code":0,"stdout":"","stderr":"","timestamp":"2026-01-01T00:00:00Z"}\n' \
        > "$dir/format.result"
    printf '{"step":"lint","exit_code":0,"stdout":"","stderr":"","timestamp":"2026-01-01T00:00:00Z"}\n' \
        > "$dir/lint.result"
    printf '{"step":"reviewer-record","exit_code":0,"stdout":"","stderr":"","timestamp":"2026-01-01T00:00:00Z"}\n' \
        > "$dir/reviewer-record.result"
}

# Helper: write a custom overlay registry JSON file
write_custom_registry() {
    local path="$1"
    # Adds a novel "custom" overlay not present in the real registry
    printf '{"custom":"custom-findings.json"}\n' > "$path"
}

# Helper: run hook with env overrides, return exit code
run_hook() {
    local exit_code=0
    env "$@" bash "$HOOK" 2>/dev/null || exit_code=$?
    echo "$exit_code"
}

# ---------------------------------------------------------------------------
# test_new_overlay_auto_enforced_missing
#
# Adds "custom": "custom-findings.json" to a test-local registry copy.
# classifier-dispatch.result flags "custom" overlay.
# All 5 base step artifacts present.
# custom-findings.json is ABSENT from ARTIFACTS_DIR.
# Verifier must exit 1 — proving the new registry entry is auto-enforced.
# ---------------------------------------------------------------------------
ARTIFACTS_DIR_1=$(mktemp -d "${TMPDIR:-/tmp}/test-ext-missing-XXXXXX")
REGISTRY_1=$(mktemp "${TMPDIR:-/tmp}/overlay-registry-XXXXXX")
trap 'rm -rf "$ARTIFACTS_DIR_1" "$REGISTRY_1"' EXIT

write_base_artifacts "$ARTIFACTS_DIR_1"
write_custom_registry "$REGISTRY_1"
printf '{"step":"classifier-dispatch","exit_code":0,"stdout":"{\"overlays\":[\"custom\"]}","stderr":"","timestamp":"2026-01-01T00:00:00Z"}\n' \
    > "$ARTIFACTS_DIR_1/classifier-dispatch.result"
# custom-findings.json intentionally absent

EXIT_CODE=$(run_hook \
    "DSO_COMPLIANCE_VERIFIER_ENABLED=true" \
    "WORKFLOW_PLUGIN_ARTIFACTS_DIR=$ARTIFACTS_DIR_1" \
    "OVERLAY_REGISTRY_PATH=$REGISTRY_1")
assert_eq "test_new_overlay_auto_enforced_missing" "1" "$EXIT_CODE"

# ---------------------------------------------------------------------------
# test_new_overlay_auto_enforced_present
#
# Same setup as above but custom-findings.json IS present in ARTIFACTS_DIR.
# Verifier must exit 0 — registry-driven check passes when artifact exists.
# ---------------------------------------------------------------------------
ARTIFACTS_DIR_2=$(mktemp -d "${TMPDIR:-/tmp}/test-ext-present-XXXXXX")
REGISTRY_2=$(mktemp "${TMPDIR:-/tmp}/overlay-registry-XXXXXX")
trap 'rm -rf "$ARTIFACTS_DIR_2" "$REGISTRY_2"' EXIT

write_base_artifacts "$ARTIFACTS_DIR_2"
write_custom_registry "$REGISTRY_2"
printf '{"step":"classifier-dispatch","exit_code":0,"stdout":"{\"overlays\":[\"custom\"]}","stderr":"","timestamp":"2026-01-01T00:00:00Z"}\n' \
    > "$ARTIFACTS_DIR_2/classifier-dispatch.result"
# custom-findings.json present
printf '{"overlay":"custom","findings":[],"timestamp":"2026-01-01T00:00:00Z"}\n' \
    > "$ARTIFACTS_DIR_2/custom-findings.json"

EXIT_CODE=$(run_hook \
    "DSO_COMPLIANCE_VERIFIER_ENABLED=true" \
    "WORKFLOW_PLUGIN_ARTIFACTS_DIR=$ARTIFACTS_DIR_2" \
    "OVERLAY_REGISTRY_PATH=$REGISTRY_2")
assert_eq "test_new_overlay_auto_enforced_present" "0" "$EXIT_CODE"

# ---------------------------------------------------------------------------
# test_extensibility_without_code_change
#
# Uses a novel overlay name ("noveloverlay") that does not appear anywhere in
# the verifier source code. Writes a registry mapping it to
# "noveloverlay-findings.json". Runs the verifier without the findings file —
# expects exit 1. This proves registry content drives enforcement, not
# hardcoded overlay names in verifier logic.
# ---------------------------------------------------------------------------
ARTIFACTS_DIR_3=$(mktemp -d "${TMPDIR:-/tmp}/test-ext-novel-XXXXXX")
REGISTRY_3=$(mktemp "${TMPDIR:-/tmp}/overlay-registry-XXXXXX")
trap 'rm -rf "$ARTIFACTS_DIR_3" "$REGISTRY_3"' EXIT

write_base_artifacts "$ARTIFACTS_DIR_3"
# Novel overlay name — no hardcoded reference in verifier code
printf '{"noveloverlay":"noveloverlay-findings.json"}\n' > "$REGISTRY_3"
printf '{"step":"classifier-dispatch","exit_code":0,"stdout":"{\"overlays\":[\"noveloverlay\"]}","stderr":"","timestamp":"2026-01-01T00:00:00Z"}\n' \
    > "$ARTIFACTS_DIR_3/classifier-dispatch.result"
# noveloverlay-findings.json intentionally absent

EXIT_CODE=$(run_hook \
    "DSO_COMPLIANCE_VERIFIER_ENABLED=true" \
    "WORKFLOW_PLUGIN_ARTIFACTS_DIR=$ARTIFACTS_DIR_3" \
    "OVERLAY_REGISTRY_PATH=$REGISTRY_3")
assert_eq "test_extensibility_without_code_change" "1" "$EXIT_CODE"

# ---------------------------------------------------------------------------
print_summary
