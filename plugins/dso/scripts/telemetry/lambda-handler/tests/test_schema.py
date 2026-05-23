from schema import SCHEMA_RULES

CANONICAL_FIELDS = [
    "event_id", "timestamp", "client_id", "session_id",
    "epic_id", "story_id", "reviewer_id", "verdict",
    "score", "cited_excerpt", "emit_excerpts",
]


def test_schema_rules_covers_required_fields():
    for field in CANONICAL_FIELDS:
        assert field in SCHEMA_RULES, f"Missing field: {field}"


def test_schema_rules_value_shape():
    for field, rule in SCHEMA_RULES.items():
        assert isinstance(rule["type"], type), f"{field}: type must be a Python type"
        assert isinstance(rule["required"], bool), f"{field}: required must be bool"
        assert "enum" in rule, f"{field}: missing enum key"
        assert rule["enum"] is None or isinstance(rule["enum"], list), f"{field}: enum must be list or None"
