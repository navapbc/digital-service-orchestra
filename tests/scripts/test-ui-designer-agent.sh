#!/usr/bin/env bash
# tests/scripts/test-ui-designer-agent.sh
# Structural (static analysis) tests for the dso:ui-designer agent definition.
#
# These tests verify that the agent file at plugins/dso/agents/ui-designer.md
# encodes the required behavioral contracts: frontmatter with name/model, stack
# adapter resolution, CACHE_MISSING handling, Lite/Full track complexity triage,
# full-track phases, Phase 5 exclusion, return payload section, scope_split_proposals,
# and shim compliance (no direct plugins/dso/scripts/ paths).
#
# All tests FAIL (RED) until the agent file is created with correct content.
#
# Usage: bash tests/scripts/test-ui-designer-agent.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
AGENT_FILE="$PLUGIN_ROOT/plugins/dso/agents/ui-designer.md"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-ui-designer-agent.sh ==="

# ── test_agent_file_exists ───────────────────────────────────────────────────
# The agent file must exist and be non-empty.
# RED: file does not exist yet — both assertions fail.
_snapshot_fail
if [[ -f "$AGENT_FILE" ]]; then
    actual_exists="exists"
else
    actual_exists="missing"
fi
assert_eq "test_agent_file_exists: file present at plugins/dso/agents/ui-designer.md" "exists" "$actual_exists"

if [[ -f "$AGENT_FILE" && -s "$AGENT_FILE" ]]; then
    actual_nonempty="nonempty"
else
    actual_nonempty="empty-or-missing"
fi
assert_eq "test_agent_file_exists: file is non-empty" "nonempty" "$actual_nonempty"
assert_pass_if_clean "test_agent_file_exists"

# ── test_frontmatter_name ───────────────────────────────────────────────────
# YAML frontmatter must contain name: ui-designer.
# Contract: callers rely on the routing name to dispatch correctly.
_snapshot_fail
if [[ -f "$AGENT_FILE" ]]; then
    frontmatter=$(awk '/^---/{c++; if(c==2) exit} c{print}' "$AGENT_FILE")
    if grep -qE '^name:[[:space:]]*ui-designer[[:space:]]*$' <<< "$frontmatter"; then
        actual_name="present"
    else
        actual_name="missing"
    fi
else
    actual_name="missing"
fi
assert_eq "test_frontmatter_name: name is ui-designer" "present" "$actual_name"
assert_pass_if_clean "test_frontmatter_name"

# ── test_frontmatter_model_sonnet ───────────────────────────────────────────
# YAML frontmatter must contain model: sonnet.
# Contract: ui-designer is a code-generation agent; sonnet is the appropriate tier.
_snapshot_fail
if [[ -f "$AGENT_FILE" ]]; then
    frontmatter=$(awk '/^---/{c++; if(c==2) exit} c{print}' "$AGENT_FILE")
    if grep -qE '^model:[[:space:]]*sonnet[[:space:]]*$' <<< "$frontmatter"; then
        actual_model="present"
    else
        actual_model="missing"
    fi
else
    actual_model="missing"
fi
assert_eq "test_frontmatter_model_sonnet: model is sonnet" "present" "$actual_model"
assert_pass_if_clean "test_frontmatter_model_sonnet"

# ── test_has_resolve_stack_adapter ──────────────────────────────────────────
# The agent must reference resolve-stack-adapter.sh for stack adapter resolution.
# Contract: stack adapter provides framework-specific component discovery patterns.
_snapshot_fail
if [[ -f "$AGENT_FILE" ]]; then
    file_content=$(cat "$AGENT_FILE")
    if grep -q "resolve-stack-adapter.sh" "$AGENT_FILE"; then
        actual_adapter="present"
    else
        actual_adapter="missing"
    fi
else
    actual_adapter="missing"
fi
assert_eq "test_has_resolve_stack_adapter: resolve-stack-adapter.sh referenced" "present" "$actual_adapter"
assert_pass_if_clean "test_has_resolve_stack_adapter"

# ── test_has_cache_missing_handling ─────────────────────────────────────────
# The agent must handle CACHE_MISSING status and provide instructions.
# Contract: when UI discovery cache is absent, the agent must not proceed with
# full design phases — it must return cache_status: CACHE_MISSING.
_snapshot_fail
if [[ -f "$AGENT_FILE" ]]; then
    if grep -q "CACHE_MISSING" "$AGENT_FILE"; then
        actual_cache="present"
    else
        actual_cache="missing"
    fi
else
    actual_cache="missing"
fi
assert_eq "test_has_cache_missing_handling: CACHE_MISSING string present" "present" "$actual_cache"
assert_pass_if_clean "test_has_cache_missing_handling"

# ── test_has_complexity_triage ───────────────────────────────────────────────
# The agent must contain complexity triage section with both Lite and Full tracks.
# Contract: triage prevents spending full design effort on trivial changes.
_snapshot_fail
if [[ -f "$AGENT_FILE" ]]; then
    file_content=$(cat "$AGENT_FILE")
    shopt -s nocasematch
    if [[ "$file_content" =~ [Ll]ite ]]; then
        actual_lite="present"
    else
        actual_lite="missing"
    fi
    if [[ "$file_content" =~ [Ff]ull ]]; then
        actual_full="present"
    else
        actual_full="missing"
    fi
    shopt -u nocasematch
    # Must contain a triage/classification step
    if grep -qiE "triage|classif|track" "$AGENT_FILE"; then
        actual_triage="present"
    else
        actual_triage="missing"
    fi
else
    actual_lite="missing"
    actual_full="missing"
    actual_triage="missing"
fi
assert_eq "test_has_complexity_triage: Lite track referenced" "present" "$actual_lite"
assert_eq "test_has_complexity_triage: Full track referenced" "present" "$actual_full"
assert_eq "test_has_complexity_triage: triage/classification logic present" "present" "$actual_triage"
assert_pass_if_clean "test_has_complexity_triage"

# ── test_has_lite_track ──────────────────────────────────────────────────────
# The agent must contain Lite track design brief logic.
# Contract: Lite track produces a Design Brief (not full manifest) for simple changes.
_snapshot_fail
if [[ -f "$AGENT_FILE" ]]; then
    if grep -qiE "design brief|brief\.md|lite.*step|lite.*track" "$AGENT_FILE"; then
        actual_lite_track="present"
    else
        actual_lite_track="missing"
    fi
else
    actual_lite_track="missing"
fi
assert_eq "test_has_lite_track: Lite track design brief logic present" "present" "$actual_lite_track"
assert_pass_if_clean "test_has_lite_track"

# ── test_has_full_track_phases ───────────────────────────────────────────────
# The agent must contain references to Full track phases 1-4 and 6.
# Contract: full track produces a Design Manifest via the 6-phase pipeline
# (Phase 5 is excluded — it is orchestrated by preplanning).
_snapshot_fail
if [[ -f "$AGENT_FILE" ]]; then
    file_content=$(cat "$AGENT_FILE")

    for phase_num in 1 2 3 4 6; do
        if grep -qE "Phase $phase_num[^0-9]|Phase ${phase_num}:" "$AGENT_FILE"; then
            actual_phase="present"
        else
            actual_phase="missing"
        fi
        assert_eq "test_has_full_track_phases: Phase $phase_num referenced" "present" "$actual_phase"
    done
else
    for phase_num in 1 2 3 4 6; do
        assert_eq "test_has_full_track_phases: Phase $phase_num referenced" "present" "missing"
    done
fi
assert_pass_if_clean "test_has_full_track_phases"

# ── test_phase_5_excluded ────────────────────────────────────────────────────
# Phase 5 (Design Review) must be explicitly excluded from the agent.
# Contract: Phase 5 is orchestrated by preplanning, not by the ui-designer agent.
# The agent body should either NOT reference "Phase 5" at all, or if it does,
# it must note that it is excluded/skipped.
_snapshot_fail
if [[ -f "$AGENT_FILE" ]]; then
    # Check if "Phase 5" appears, and if so, verify it's mentioned as excluded
    phase5_count=$(grep -c "Phase 5" "$AGENT_FILE" 2>/dev/null || echo "0")
    if [[ "$phase5_count" -eq 0 ]]; then
        # Phase 5 not mentioned at all — acceptable
        actual_phase5="excluded"
    else
        # Phase 5 is mentioned — verify it notes exclusion
        if grep -qiE "Phase 5.*exclud|exclud.*Phase 5|Phase 5.*skip|skip.*Phase 5|Phase 5.*omit|Phase 5.*orchestrat" "$AGENT_FILE"; then
            actual_phase5="excluded"
        else
            actual_phase5="included-without-exclusion-note"
        fi
    fi
else
    actual_phase5="excluded"
fi
assert_eq "test_phase_5_excluded: Phase 5 absent or noted as excluded" "excluded" "$actual_phase5"
assert_pass_if_clean "test_phase_5_excluded"

# ── test_has_return_payload_section ─────────────────────────────────────────
# The agent must have a Return Payload section referencing the contract.
# Contract: all dispatched agents must emit structured payloads for orchestrators.
_snapshot_fail
if [[ -f "$AGENT_FILE" ]]; then
    if grep -qiE "return payload|UI_DESIGNER_PAYLOAD" "$AGENT_FILE"; then
        actual_payload_section="present"
    else
        actual_payload_section="missing"
    fi
    if grep -q "ui-designer-payload.md" "$AGENT_FILE"; then
        actual_contract_ref="present"
    else
        actual_contract_ref="missing"
    fi
else
    actual_payload_section="missing"
    actual_contract_ref="missing"
fi
assert_eq "test_has_return_payload_section: Return Payload section present" "present" "$actual_payload_section"
assert_eq "test_has_return_payload_section: ui-designer-payload.md contract referenced" "present" "$actual_contract_ref"
assert_pass_if_clean "test_has_return_payload_section"

# ── test_has_scope_split_proposals ──────────────────────────────────────────
# The agent must reference scope_split_proposals in its return payload.
# Contract: when the pragmatic scope splitter fires, proposals must be surfaced
# to the orchestrator in the structured payload.
_snapshot_fail
if [[ -f "$AGENT_FILE" ]]; then
    if grep -q "scope_split_proposals" "$AGENT_FILE"; then
        actual_scope_split="present"
    else
        actual_scope_split="missing"
    fi
else
    actual_scope_split="missing"
fi
assert_eq "test_has_scope_split_proposals: scope_split_proposals referenced" "present" "$actual_scope_split"
assert_pass_if_clean "test_has_scope_split_proposals"

# ── test_no_direct_plugin_path ───────────────────────────────────────────────
# The agent must NOT contain direct plugins/dso/scripts/ paths outside of
# shim-exempt annotations or fenced code blocks.
# Contract: all plugin script references must go through the .claude/scripts/dso shim.
# Method: find all lines with plugins/dso/scripts/ and verify each is exempt.
_snapshot_fail
if [[ -f "$AGENT_FILE" ]]; then
    # Find lines with plugins/dso/scripts/ that are NOT shim-exempt annotated
    # and NOT inside fenced code blocks (which are documentation examples)
    non_exempt_count=0
    in_code_block=0
    while IFS= read -r line; do
        # Track fenced code block state
        if [[ "$line" =~ ^[[:space:]]*\`\`\` ]]; then
            if [[ $in_code_block -eq 0 ]]; then
                in_code_block=1
            else
                in_code_block=0
            fi
            continue
        fi
        # Skip lines inside code blocks (documentation examples)
        if [[ $in_code_block -eq 1 ]]; then
            continue
        fi
        # Check for direct plugin path reference outside code blocks
        if echo "$line" | grep -q "plugins/dso/scripts/"; then
            # Allow if line has shim-exempt annotation
            if echo "$line" | grep -q "shim-exempt"; then
                continue
            fi
            # Allow if it's a comment line (# ...)
            if echo "$line" | grep -qE "^[[:space:]]*#"; then
                continue
            fi
            (( non_exempt_count++ )) || true
        fi
    done < "$AGENT_FILE"

    if [[ "$non_exempt_count" -eq 0 ]]; then
        actual_shim_compliance="compliant"
    else
        actual_shim_compliance="non-compliant ($non_exempt_count violations)"
    fi
else
    actual_shim_compliance="compliant"
fi
assert_eq "test_no_direct_plugin_path: no direct plugins/dso/scripts/ paths outside shim-exempt" "compliant" "$actual_shim_compliance"
assert_pass_if_clean "test_no_direct_plugin_path"


# ── test_payload_field_conformance ─────────────────────────────────────────────
# The return payload must use field names matching the contract:
# design_uuid, wireframe_svg, token_overlay (not wireframe or tokens).
_snapshot_fail
if [[ -f "$AGENT_FILE" ]]; then
    file_content=$(cat "$AGENT_FILE")
    # Must have design_uuid in payload
    if echo "$file_content" | grep -q '"design_uuid"'; then
        actual_design_uuid="present"
    else
        actual_design_uuid="missing"
    fi
    # Must have wireframe_svg in payload (not just wireframe)
    if echo "$file_content" | grep -q '"wireframe_svg"'; then
        actual_wireframe_svg="present"
    else
        actual_wireframe_svg="missing"
    fi
    # Must have token_overlay in payload (not just tokens)
    if echo "$file_content" | grep -q '"token_overlay"'; then
        actual_token_overlay="present"
    else
        actual_token_overlay="missing"
    fi
    # Must NOT have bare "wireframe" payload key (would be schema mismatch)
    if echo "$file_content" | grep -qE '"wireframe":[[:space:]]*"designs/'; then
        actual_no_bare_wireframe="bare-wireframe-found"
    else
        actual_no_bare_wireframe="ok"
    fi
else
    actual_design_uuid="missing"
    actual_wireframe_svg="missing"
    actual_token_overlay="missing"
    actual_no_bare_wireframe="ok"
fi
assert_eq "test_payload_field_conformance: design_uuid field present" "present" "$actual_design_uuid"
assert_eq "test_payload_field_conformance: wireframe_svg field present" "present" "$actual_wireframe_svg"
assert_eq "test_payload_field_conformance: token_overlay field present" "present" "$actual_token_overlay"
assert_eq "test_payload_field_conformance: no bare wireframe key in payload" "ok" "$actual_no_bare_wireframe"
assert_pass_if_clean "test_payload_field_conformance"

# ── Summary ──────────────────────────────────────────────────────────────────
print_summary
