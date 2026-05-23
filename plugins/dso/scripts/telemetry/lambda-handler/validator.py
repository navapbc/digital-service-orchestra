"""
Canonical telemetry event validator.

Validates against COMMON_FIELDS (11 fields) + PER_TYPE_FIELDS (per-event-type)
per ${CLAUDE_PLUGIN_ROOT}/docs/contracts/telemetry-event-schema.md.
"""

from schema import COMMON_FIELDS, PER_TYPE_FIELDS


def _check_field(field: str, rule: dict, payload: dict) -> tuple[bool, str | None]:
    if rule["required"] and field not in payload:
        return False, f"Missing required field: {field}"
    if field in payload:
        value = payload[field]
        # bool is a subclass of int in Python; reject ints typed as bools and vice versa.
        if rule["type"] is int and isinstance(value, bool):
            return False, f"Field {field}: expected int, got bool"
        if rule["type"] is bool and not isinstance(value, bool):
            return False, f"Field {field}: expected bool"
        if not isinstance(value, rule["type"]):
            return False, f"Field {field}: expected {rule['type'].__name__}"
        if rule["enum"] and value not in rule["enum"]:
            return False, f"Field {field}: value not in allowed set"
    return True, None


def validate_event(payload: dict) -> tuple[bool, str | None]:
    # Phase 1: validate 11 common fields.
    for field, rule in COMMON_FIELDS.items():
        ok, err = _check_field(field, rule, payload)
        if not ok:
            return False, err

    # Phase 2: validate per-event-type fields. The event_type enum check in
    # COMMON_FIELDS guarantees event_type is in PER_TYPE_FIELDS (or absent,
    # which Phase 1 already rejected).
    event_type = payload["event_type"]
    type_fields = PER_TYPE_FIELDS.get(event_type, {})
    for field, rule in type_fields.items():
        ok, err = _check_field(field, rule, payload)
        if not ok:
            return False, err

    return True, None
