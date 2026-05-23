"""
Canonical telemetry event schema (schema_version=1) for the Lambda handler.

Source of truth: ${CLAUDE_PLUGIN_ROOT}/docs/contracts/telemetry-event-schema.md
Any change here MUST be reflected in the canonical doc atomically.

Structure: COMMON_FIELDS (the 11 common fields shared by every event_type) +
PER_TYPE_FIELDS (per-event-type field requirements keyed by event_type).
"""

# 11 canonical common fields shared by every event type at schema_version=1.
COMMON_FIELDS = {
    "schema_version": {"type": int,  "required": True,  "enum": [1]},
    "event_id":       {"type": str,  "required": True,  "enum": None},
    "event_type":     {"type": str,  "required": True,  "enum": [
        "review_finding", "resolver_outcome", "arbiter_ruling", "tool_finding", "review_cycle",
    ]},
    "client_id":      {"type": str,  "required": True,  "enum": None},
    "tool_id":        {"type": str,  "required": True,  "enum": None},
    "tool_version":   {"type": str,  "required": True,  "enum": None},
    "timestamp":      {"type": str,  "required": True,  "enum": None},
    "pr_number":      {"type": int,  "required": False, "enum": None},
    "commit_sha":     {"type": str,  "required": False, "enum": None},
    "cycle":          {"type": int,  "required": False, "enum": None},
    "language":       {"type": str,  "required": False, "enum": None},
}

# Per-event-type fields. Each entry maps event_type -> field-rule dict.
PER_TYPE_FIELDS = {
    "review_finding": {
        "finding_id":    {"type": str,  "required": True,  "enum": None},
        "severity":      {"type": str,  "required": True,  "enum": ["critical", "important", "minor", "suggestion"]},
        "category":      {"type": str,  "required": True,  "enum": ["correctness", "design", "hygiene", "maintainability", "verification"]},
        "description":   {"type": str,  "required": True,  "enum": None},
        "file":          {"type": str,  "required": True,  "enum": None},
        "cited_lines":   {"type": list, "required": True,  "enum": None},
        "cited_excerpt": {"type": str,  "required": False, "enum": None},
        "rule_id":       {"type": str,  "required": False, "enum": None},
        "relation":      {"type": str,  "required": False, "enum": ["NEW_INTRODUCED", "NEW_PRE_EXISTING", "RESUSTAIN_OF", "REFRAME_OF"]},
    },
    "resolver_outcome": {
        "finding_id":         {"type": str,  "required": True,  "enum": None},
        "resolution_action":  {"type": str,  "required": True,  "enum": ["code_fix", "defense", "escalated"]},
        "resolution_cycle":   {"type": int,  "required": True,  "enum": None},
        "accepted":           {"type": bool, "required": True,  "enum": None},
        "resolution_summary": {"type": str,  "required": False, "enum": None},
    },
    "arbiter_ruling": {
        "finding_id":          {"type": str,  "required": True, "enum": None},
        "prior_finding_id":    {"type": str,  "required": True, "enum": None},
        "arbiter_decision":    {"type": str,  "required": True, "enum": ["uphold", "dismiss", "downgrade"]},
        "arbiter_rationale":   {"type": str,  "required": True, "enum": None},
        "downgraded_severity": {"type": str,  "required": False, "enum": ["minor", "suggestion"]},
    },
    "tool_finding": {
        "tool_name":     {"type": str, "required": True,  "enum": None},
        "tool_rule":     {"type": str, "required": True,  "enum": None},
        "tool_severity": {"type": str, "required": True,  "enum": ["error", "warning", "info"]},
        "file":          {"type": str, "required": True,  "enum": None},
        "line":          {"type": int, "required": False, "enum": None},
        "message":       {"type": str, "required": True,  "enum": None},
    },
    "review_cycle": {
        "cycle_number":        {"type": int,  "required": True, "enum": None},
        "tier":                {"type": str,  "required": True, "enum": ["light", "standard", "deep"]},
        "finding_count":       {"type": int,  "required": True, "enum": None},
        "critical_count":      {"type": int,  "required": True, "enum": None},
        "important_count":     {"type": int,  "required": True, "enum": None},
        "minor_count":         {"type": int,  "required": True, "enum": None},
        "pass":                {"type": bool, "required": True, "enum": None},
        "resolution_attempts": {"type": int,  "required": True, "enum": None},
        "diff_hash":           {"type": str,  "required": True, "enum": None},
    },
}

# Back-compat alias for any callers still importing the legacy name.
# Will be removed once all callers migrate to COMMON_FIELDS / PER_TYPE_FIELDS.
SCHEMA_RULES = COMMON_FIELDS
