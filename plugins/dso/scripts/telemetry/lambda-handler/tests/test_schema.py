"""
Tests for the canonical telemetry event schema.

Source of truth: ${CLAUDE_PLUGIN_ROOT}/docs/contracts/telemetry-event-schema.md
Validates that COMMON_FIELDS contains the 11 canonical common fields and that
PER_TYPE_FIELDS covers all 5 canonical event types.
"""

from schema import COMMON_FIELDS, PER_TYPE_FIELDS, SCHEMA_RULES

CANONICAL_COMMON_FIELDS = [
    "schema_version", "event_id", "event_type", "client_id",
    "tool_id", "tool_version", "timestamp",
    "pr_number", "commit_sha", "cycle", "language",
]

CANONICAL_EVENT_TYPES = [
    "review_finding",
    "resolver_outcome",
    "arbiter_ruling",
    "tool_finding",
    "review_cycle",
]


def test_common_fields_cover_all_11_canonical_fields():
    for field in CANONICAL_COMMON_FIELDS:
        assert field in COMMON_FIELDS, f"Missing canonical common field: {field}"
    assert len(COMMON_FIELDS) == len(CANONICAL_COMMON_FIELDS), (
        f"Unexpected common fields: {set(COMMON_FIELDS) - set(CANONICAL_COMMON_FIELDS)}"
    )


def test_common_fields_required_set_matches_canonical():
    required = {f for f, rule in COMMON_FIELDS.items() if rule["required"]}
    expected_required = {
        "schema_version", "event_id", "event_type", "client_id",
        "tool_id", "tool_version", "timestamp",
    }
    assert required == expected_required


def test_per_type_fields_cover_all_5_event_types():
    for event_type in CANONICAL_EVENT_TYPES:
        assert event_type in PER_TYPE_FIELDS, f"Missing per-type fields for: {event_type}"


def test_event_type_enum_matches_canonical_set():
    assert set(COMMON_FIELDS["event_type"]["enum"]) == set(CANONICAL_EVENT_TYPES)


def test_schema_version_is_1():
    assert COMMON_FIELDS["schema_version"]["enum"] == [1]


def test_all_field_rules_have_well_formed_shape():
    sources = [("COMMON_FIELDS", COMMON_FIELDS)]
    sources.extend((f"PER_TYPE_FIELDS[{k}]", v) for k, v in PER_TYPE_FIELDS.items())
    for src_name, src in sources:
        for field, rule in src.items():
            assert isinstance(rule["type"], type), f"{src_name}.{field}: type must be a Python type"
            assert isinstance(rule["required"], bool), f"{src_name}.{field}: required must be bool"
            assert "enum" in rule, f"{src_name}.{field}: missing enum key"
            assert rule["enum"] is None or isinstance(rule["enum"], list), (
                f"{src_name}.{field}: enum must be list or None"
            )


def test_back_compat_alias_present():
    # SCHEMA_RULES is preserved as an alias of COMMON_FIELDS for legacy callers.
    assert SCHEMA_RULES is COMMON_FIELDS
