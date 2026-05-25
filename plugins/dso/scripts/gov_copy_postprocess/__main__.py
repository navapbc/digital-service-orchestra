"""gov-copy artifact deterministic post-processor CLI.

Usage: python -m plugins.dso.scripts.gov_copy_postprocess <artifact_path> --config-path <config>
"""
import argparse
import sys
from pathlib import Path

import yaml

from .banned import find_banned_words
from .config import load_gov_copy_config, ConfigError
from .deviations import build_deviations, _OWNED_RULE_IDS
from .readability import compute_fk_grade
from .voice import is_active_voice


def _get_item_text(item: dict) -> str:
    """Extract concatenated text from values block (label/hint/errors)."""
    values = item.get("values", {}) or {}
    parts = []
    if "label" in values:
        parts.append(str(values["label"]))
    if "hint" in values:
        parts.append(str(values["hint"]))
    errors = values.get("errors", {}) or {}
    if isinstance(errors, dict):
        for v in errors.values():
            parts.append(str(v))
    elif isinstance(errors, list):
        parts.extend(str(e) for e in errors)
    # Separate fields with ". " so the passive-voice regex
    # (\b(am|is|are|...)\b\s+(...)ed\b) cannot match across field boundaries
    # — e.g. label='Form status is' + hint='updated daily' must NOT be detected
    # as the passive 'is updated' because neither field is passive on its own.
    # The period is a non-whitespace, non-word character that breaks the \s+
    # bridge in the regex; readability/banned-word scans treat each field as
    # its own sentence.
    return ". ".join(parts)


def process_item(item: dict, config) -> dict:
    """Mutate item in place: overwrite checks, update rationale.deviations. Returns the item.

    The checks block conforms to ${CLAUDE_PLUGIN_ROOT}/docs/contracts/gov-copy-artifact.md:
    flat fields (fk_grade int, banned_words_found list, active_voice bool) + a single
    top-level source string. The validator (check-gov-copy-artifact.sh) enforces this shape.
    """
    text = _get_item_text(item)
    fk_raw = compute_fk_grade(text) if text.strip() else 0.0
    fk = int(round(fk_raw))  # contract requires fk_grade as integer
    banned = find_banned_words(text, config.banned_words)
    active = is_active_voice(text) if text.strip() else True
    # Overwrite checks block — flat schema per contract gov-copy-artifact.md
    item["checks"] = {
        "fk_grade": fk,
        "banned_words_found": banned,
        "active_voice": active,
        "source": "deterministic-post-processor",
    }
    # Build deviations using rationale.deviations[] semantics
    rationale = item.setdefault("rationale", {})
    existing_devs = rationale.get("deviations", [])
    # build_deviations consumes the flat checks shape directly
    rationale["deviations"] = build_deviations(item, existing_devs, config.fk_max)
    return item


def main():
    parser = argparse.ArgumentParser(description="gov-copy artifact deterministic post-processor")
    parser.add_argument("artifact_path", help="Path to gov-copy artifact YAML file")
    parser.add_argument("--config-path", required=True, help="Path to dso-config.conf with [gov_copy] block")
    args = parser.parse_args()

    try:
        config = load_gov_copy_config(args.config_path)
    except ConfigError as e:
        print(f"error: {e}", file=sys.stderr)
        return 2

    artifact_path = Path(args.artifact_path)
    if not artifact_path.exists():
        print(f"error: artifact not found: {artifact_path}", file=sys.stderr)
        return 2

    with open(artifact_path) as f:
        artifact = yaml.safe_load(f)
    if artifact is None:
        artifact = {}
    if not isinstance(artifact, dict):
        print(
            f"error: artifact root must be a mapping, got {type(artifact).__name__}",
            file=sys.stderr,
        )
        return 2
    items = artifact.get("items") or []
    if not isinstance(items, list):
        print(
            f"error: artifact.items must be a list, got {type(items).__name__}",
            file=sys.stderr,
        )
        return 2
    # Filter out any non-dict items; report rather than crashing on AttributeError.
    bad_idx = [i for i, it in enumerate(items) if not isinstance(it, dict)]
    if bad_idx:
        print(
            f"error: artifact.items contains non-dict entries at indices {bad_idx}",
            file=sys.stderr,
        )
        return 2

    total = len(items)
    passing = 0
    deviations_count = 0
    for item in items:
        process_item(item, config)
        devs = item.get("rationale", {}).get("deviations", [])
        owned_failures = [d for d in devs if d.get("rule_id") in _OWNED_RULE_IDS]
        deviations_count += len(owned_failures)
        if not owned_failures:
            passing += 1

    pass_ratio = 1.0 if total == 0 else passing / total
    threshold_met = pass_ratio >= config.closing_ratio

    # Atomic write
    tmp_path = artifact_path.with_suffix(artifact_path.suffix + ".tmp")
    with open(tmp_path, "w") as f:
        yaml.safe_dump(artifact, f, default_flow_style=False, sort_keys=False)
    tmp_path.replace(artifact_path)

    # Summary output — single canonical field name (pass_ratio).
    print(f"pass_ratio: {pass_ratio:.2f}")
    print(f"total_items: {total}")
    print(f"deviations_count: {deviations_count}")
    print(f"closing_threshold_met: {str(threshold_met).lower()}")

    return 0 if threshold_met else 1


if __name__ == "__main__":
    sys.exit(main())
