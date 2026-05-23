SCHEMA_RULES = {
    "event_id":      {"type": str,  "required": True,  "enum": None},
    "timestamp":     {"type": str,  "required": True,  "enum": None},
    "client_id":     {"type": str,  "required": True,  "enum": None},
    "session_id":    {"type": str,  "required": True,  "enum": None},
    "epic_id":       {"type": str,  "required": True,  "enum": None},
    "story_id":      {"type": str,  "required": True,  "enum": None},
    "reviewer_id":   {"type": str,  "required": True,  "enum": None},
    "verdict":       {"type": str,  "required": True,  "enum": ["PASS", "FAIL", "NEEDS_REVISION"]},
    "score":         {"type": int,  "required": True,  "enum": None},
    "cited_excerpt": {"type": str,  "required": False, "enum": None},
    "emit_excerpts": {"type": bool, "required": False, "enum": None},
}
