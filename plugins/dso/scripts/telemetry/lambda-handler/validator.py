from schema import SCHEMA_RULES


def validate_event(payload: dict) -> tuple[bool, str | None]:
    for field, rule in SCHEMA_RULES.items():
        if rule["required"] and field not in payload:
            return False, f"Missing required field: {field}"
        if field in payload:
            if not isinstance(payload[field], rule["type"]):
                return False, f"Field {field}: expected {rule['type'].__name__}"
            if rule["enum"] and payload[field] not in rule["enum"]:
                return False, f"Field {field}: value not in allowed set"
    return True, None
