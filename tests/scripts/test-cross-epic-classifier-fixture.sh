#!/usr/bin/env bash
# tests/scripts/test-cross-epic-classifier-fixture.sh
# Fixture tests for the cross-epic interaction classifier agent.
#
# Tests:
#  (1) test_url_collision_fixture_schema    — url-collision-stubs.json is valid JSON with required fields
#  (2) test_benign_overlap_fixture_schema   — benign-overlap-stubs.json is valid JSON with required fields
#  (3) test_url_collision_expected_signal   — url-collision-expected-signal.json matches classifier output schema
#  (4) test_benign_expected_signal          — benign-expected-no-signal.json is valid (empty or benign-only)
#  (5) test_classifier_agent_schema         — cross-epic-interaction-classifier.md has required output schema spec
#
# Usage: bash tests/scripts/test-cross-epic-classifier-fixture.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
FIXTURES_DIR="$PLUGIN_ROOT/tests/fixtures/cross-epic-classifier"
CLASSIFIER_AGENT="$PLUGIN_ROOT/plugins/dso/agents/cross-epic-interaction-classifier.md"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-cross-epic-classifier-fixture.sh ==="

# ── _validate_epic_stub_schema ────────────────────────────────────────────────
# Helper: validates a stub JSON file has the required epic stub schema.
# Usage: _validate_epic_stub_schema <fixture_path>
# Outputs: "OK" or "ERRORS: ..."
_validate_epic_stub_schema() {
    local _fixture_path="$1"
    FIXTURE_PATH="$_fixture_path" python3 -c '
import json, os, sys

fixture_path = os.environ["FIXTURE_PATH"]
with open(fixture_path) as f:
    data = json.load(f)

errors = []

# Check top-level keys
if "new_epic" not in data:
    errors.append("missing new_epic key")
if "open_epics" not in data:
    errors.append("missing open_epics key")

if not errors:
    # Validate new_epic fields
    ne = data["new_epic"]
    for field in ["id", "title", "approach_summary", "success_criteria"]:
        if field not in ne:
            errors.append("new_epic missing field: " + field)
    if "success_criteria" in ne and not isinstance(ne["success_criteria"], list):
        errors.append("new_epic.success_criteria must be an array")

    # Validate open_epics[0] fields
    if "open_epics" in data:
        if not isinstance(data["open_epics"], list) or len(data["open_epics"]) == 0:
            errors.append("open_epics must be a non-empty array")
        else:
            oe = data["open_epics"][0]
            for field in ["id", "title", "approach_summary", "success_criteria"]:
                if field not in oe:
                    errors.append("open_epics[0] missing field: " + field)
            if "success_criteria" in oe and not isinstance(oe["success_criteria"], list):
                errors.append("open_epics[0].success_criteria must be an array")

if errors:
    print("ERRORS: " + "; ".join(errors))
else:
    print("OK")
'
}

# ── test_url_collision_fixture_schema ─────────────────────────────────────────
# (1) url-collision-stubs.json must be valid JSON with required schema
test_url_collision_fixture_schema() {
    _snapshot_fail
    local _fixture="$FIXTURES_DIR/url-collision-stubs.json"

    if [[ ! -f "$_fixture" ]]; then
        assert_eq "test_url_collision_fixture_schema: fixture file must exist" "exists" "missing"
        assert_pass_if_clean "test_url_collision_fixture_schema"
        return
    fi

    local _result
    _result=$(_validate_epic_stub_schema "$_fixture")
    assert_eq "test_url_collision_fixture_schema: JSON validation" "OK" "$_result"
    assert_pass_if_clean "test_url_collision_fixture_schema"
}

# ── test_benign_overlap_fixture_schema ────────────────────────────────────────
# (2) benign-overlap-stubs.json must be valid JSON with required schema
test_benign_overlap_fixture_schema() {
    _snapshot_fail
    local _fixture="$FIXTURES_DIR/benign-overlap-stubs.json"

    if [[ ! -f "$_fixture" ]]; then
        assert_eq "test_benign_overlap_fixture_schema: fixture file must exist" "exists" "missing"
        assert_pass_if_clean "test_benign_overlap_fixture_schema"
        return
    fi

    local _result
    _result=$(_validate_epic_stub_schema "$_fixture")
    assert_eq "test_benign_overlap_fixture_schema: JSON validation" "OK" "$_result"
    assert_pass_if_clean "test_benign_overlap_fixture_schema"
}

# ── test_url_collision_expected_signal ────────────────────────────────────────
# (3) url-collision-expected-signal.json must match classifier output schema
#     and the signal must have severity in (ambiguity, conflict) with /api/users
test_url_collision_expected_signal() {
    _snapshot_fail
    local _fixture="$FIXTURES_DIR/url-collision-expected-signal.json"

    if [[ ! -f "$_fixture" ]]; then
        assert_eq "test_url_collision_expected_signal: fixture file must exist" "exists" "missing"
        assert_pass_if_clean "test_url_collision_expected_signal"
        return
    fi

    local _result
    _result=$(FIXTURE_PATH="$_fixture" python3 -c '
import json, os

fixture_path = os.environ["FIXTURE_PATH"]
with open(fixture_path) as f:
    data = json.load(f)

errors = []
valid_severities = {"benign", "consideration", "ambiguity", "conflict"}
required_signal_fields = [
    "new_epic_id", "overlapping_epic_id", "overlapping_epic_title",
    "severity", "shared_resource", "description", "integration_constraint"
]

# Must have interaction_signals array
if "interaction_signals" not in data:
    errors.append("missing interaction_signals key")
elif not isinstance(data["interaction_signals"], list):
    errors.append("interaction_signals must be an array")
else:
    signals = data["interaction_signals"]
    if len(signals) == 0:
        errors.append("url-collision fixture must have at least one signal")
    else:
        for i, sig in enumerate(signals):
            for field in required_signal_fields:
                if field not in sig:
                    errors.append("signal[" + str(i) + "] missing field: " + field)
            if "severity" in sig and sig["severity"] not in valid_severities:
                errors.append("signal[" + str(i) + "].severity must be one of: " + str(sorted(valid_severities)))

        # url-collision signal must have severity in (ambiguity, conflict)
        first = signals[0]
        if "severity" in first and first["severity"] not in {"ambiguity", "conflict"}:
            errors.append("url-collision signal severity must be ambiguity or conflict, got: " + first["severity"])

        # shared_resource must reference /api/users or users
        if "shared_resource" in first:
            sr = first["shared_resource"]
            if "api/users" not in sr and "users" not in sr:
                errors.append("url-collision signal shared_resource must reference api/users or users, got: " + sr)

if errors:
    print("ERRORS: " + "; ".join(errors))
else:
    print("OK")
')

    assert_eq "test_url_collision_expected_signal: schema validation" "OK" "$_result"
    assert_pass_if_clean "test_url_collision_expected_signal"
}

# ── test_benign_expected_signal ───────────────────────────────────────────────
# (4) benign-expected-no-signal.json must be valid (empty or benign-only signals)
test_benign_expected_signal() {
    _snapshot_fail
    local _fixture="$FIXTURES_DIR/benign-expected-no-signal.json"

    if [[ ! -f "$_fixture" ]]; then
        assert_eq "test_benign_expected_signal: fixture file must exist" "exists" "missing"
        assert_pass_if_clean "test_benign_expected_signal"
        return
    fi

    local _result
    _result=$(FIXTURE_PATH="$_fixture" python3 -c '
import json, os

fixture_path = os.environ["FIXTURE_PATH"]
with open(fixture_path) as f:
    data = json.load(f)

errors = []

# Must have interaction_signals array
if "interaction_signals" not in data:
    errors.append("missing interaction_signals key")
elif not isinstance(data["interaction_signals"], list):
    errors.append("interaction_signals must be an array")
else:
    signals = data["interaction_signals"]
    # Either empty OR contains only benign signals
    non_benign = [s for s in signals if s.get("severity") != "benign"]
    if non_benign:
        errors.append(
            "benign fixture must have empty interaction_signals or only benign severity; "
            "found non-benign: " + str([s.get("severity") for s in non_benign])
        )

if errors:
    print("ERRORS: " + "; ".join(errors))
else:
    print("OK")
')

    assert_eq "test_benign_expected_signal: schema validation" "OK" "$_result"
    assert_pass_if_clean "test_benign_expected_signal"
}

# ── test_classifier_agent_schema ──────────────────────────────────────────────
# (5) cross-epic-interaction-classifier.md must have required output schema spec
test_classifier_agent_schema() {
    _snapshot_fail

    # Check agent file exists
    local _found=0
    if [[ -f "$CLASSIFIER_AGENT" ]]; then
        _found=1
    fi
    assert_eq "test_classifier_agent_schema: agent file must exist" "1" "$_found"

    if [[ "$_found" -eq 0 ]]; then
        assert_pass_if_clean "test_classifier_agent_schema"
        return
    fi

    local _content
    _content=$(cat "$CLASSIFIER_AGENT")

    # Must contain all four severity tier names
    local _has_benign=0
    local _has_consideration=0
    local _has_ambiguity=0
    local _has_conflict=0
    [[ "$_content" == *"benign"* ]] && _has_benign=1
    [[ "$_content" == *"consideration"* ]] && _has_consideration=1
    [[ "$_content" == *"ambiguity"* ]] && _has_ambiguity=1
    [[ "$_content" == *"conflict"* ]] && _has_conflict=1

    assert_eq "test_classifier_agent_schema: must contain severity tier 'benign'" "1" "$_has_benign"
    assert_eq "test_classifier_agent_schema: must contain severity tier 'consideration'" "1" "$_has_consideration"
    assert_eq "test_classifier_agent_schema: must contain severity tier 'ambiguity'" "1" "$_has_ambiguity"
    assert_eq "test_classifier_agent_schema: must contain severity tier 'conflict'" "1" "$_has_conflict"

    # Must contain the output field name 'interaction_signals'
    local _has_output_field=0
    [[ "$_content" == *"interaction_signals"* ]] && _has_output_field=1
    assert_eq "test_classifier_agent_schema: must contain output field 'interaction_signals'" "1" "$_has_output_field"

    # Must contain required signal field 'shared_resource'
    local _has_shared_resource=0
    [[ "$_content" == *"shared_resource"* ]] && _has_shared_resource=1
    assert_eq "test_classifier_agent_schema: must contain signal field 'shared_resource'" "1" "$_has_shared_resource"

    assert_pass_if_clean "test_classifier_agent_schema"
}

# ── Run all tests ─────────────────────────────────────────────────────────────
test_url_collision_fixture_schema
test_benign_overlap_fixture_schema
test_url_collision_expected_signal
test_benign_expected_signal
test_classifier_agent_schema

print_summary
