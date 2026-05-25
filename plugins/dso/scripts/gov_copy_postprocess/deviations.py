"""Deviation tracking for gov-copy post-processing."""

_OWNED_RULE_IDS = ("fk_grade", "banned_words_found", "active_voice")


def _existing_reason(existing_deviations, rule_id):
    for dev in existing_deviations:
        if dev.get("rule_id") == rule_id:
            reason = dev.get("reason", "")
            return reason.strip() if reason else ""
    return None  # not present


def build_deviations(item, existing_deviations, fk_max):
    """Build deviation list for an item.

    For each owned rule_id (fk_grade, banned_words_found, active_voice):
    - If item fails that rule, emit a deviation entry. Preserve any pre-existing
      non-empty reason for the same rule_id; otherwise insert 'unjustified'.
    Untouched rule_ids (outside owned set) are preserved as-is in output.
    """
    checks = item.get("checks", {})
    fk = checks.get("fk_grade", 0)
    banned = checks.get("banned_words_found", [])
    active = checks.get("active_voice", True)

    failures = []
    if fk > fk_max:
        failures.append("fk_grade")
    if banned:
        failures.append("banned_words_found")
    if not active:
        failures.append("active_voice")

    # Start with existing deviations for rule_ids OUTSIDE our ownership (preserved)
    result = [d for d in existing_deviations if d.get("rule_id") not in _OWNED_RULE_IDS]

    # Add new/preserved entries for failed owned rules
    for rule_id in failures:
        existing_reason = _existing_reason(existing_deviations, rule_id)
        reason = existing_reason if existing_reason else "unjustified"
        result.append({"rule_id": rule_id, "reason": reason})

    return result
