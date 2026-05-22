"""dso_ci_review.arbiter — Cycle-end arbiter dispatch and ruling validation.

Provides public functions:

  dispatch_arbiter          — Dispatches the cycle-end arbiter for a list of findings.
                              Returns a list of per-finding ruling dicts.

  validate_cycle_end_ruling — Validates a ruling dict against VALID_RULINGS and,
                              for schema_version >= 1.1.0, enforces enum
                              membership for cross_reviewer_agreement (4-val),
                              cross_cycle_pattern (7-val), and impact_class
                              (9-val: 8-cat floor + 'none'). Raises ValueError
                              for unrecognized values or missing v1.1.0 fields.

  dispatch_cycle_end_arbiter — Alias for dispatch_arbiter; cycle-end consolidation.

  compute_ruling_from_fixture — Apply CoVe fallback and validate on a pre-stored
                                arbiter_ruling from a fixture. Used by shell replay
                                tests to exercise the deterministic arbiter pipeline
                                without requiring LLM dispatch.
"""

from __future__ import annotations

import json as _json
import subprocess
import sys
from typing import Any

from dso_ci_review.dispatch import dispatch_review

# Specific transport / parse exception classes treated as dispatch failures.
# NOTE: deliberately NOT bare `Exception` — catching `Exception` would mask
# downstream programming bugs (e.g. AttributeError in CoVe fallback) as fake
# BLOCK rulings. Only true transport/parse errors are dispatch failures.
_DISPATCH_FAILURE_EXCEPTIONS: tuple[type[BaseException], ...] = (
    subprocess.CalledProcessError,
    _json.JSONDecodeError,
    OSError,  # base class for ConnectionError, TimeoutError, FileNotFoundError, etc.
)

VALID_RULINGS: frozenset[str] = frozenset({"BLOCK", "DEFER", "DROP"})

# v1.1.0 enriched-ruling enum vocabularies (see code-reviewer-arbiter.md Enum
# Vocabularies and contracts/review-defenses.md arbiter_ruling sub-schema).
VALID_CROSS_REVIEWER_AGREEMENT: frozenset[str] = frozenset(
    {
        "UNANIMOUS",
        "MAJORITY",
        "SPLIT",
        "SINGLE_REVIEWER",
    }
)
VALID_CROSS_CYCLE_PATTERN: frozenset[str] = frozenset(
    {
        "NEW_INTRODUCED",
        "RECURRING",
        "RESUSTAIN_OF",
        "RESOLVED_THEN_REINTRODUCED",
        "ESCALATED",
        "DEFENDED_PRIOR_CYCLE",
        "UNKNOWN",
    }
)
VALID_IMPACT_CLASS: frozenset[str] = frozenset(
    {
        "bug",
        "unintended_behavior",
        "security_vulnerability",
        "data_loss_or_corruption",
        "secret_exposure",
        "compliance_violation",
        "api_contract_break",
        "infrastructure_break",
        "none",
    }
)

# Fields required by schema_version >= 1.1.0 (missing fields raise ValueError).
_V1_1_0_REQUIRED_FIELDS: tuple[str, ...] = (
    "cross_reviewer_agreement",
    "cross_cycle_pattern",
    "impact_class",
)


def validate_cycle_end_ruling(ruling: dict[str, Any]) -> dict[str, Any]:
    """Validate a cycle-end ruling dict against VALID_RULINGS + v1.1.0 enums.

    For all rulings, enforces ``ruling['ruling']`` ∈ VALID_RULINGS.

    For rulings whose ``schema_version`` is ``>= 1.1.0``, additionally enforces:
      - ``cross_reviewer_agreement`` is a list whose elements ∈
        ``VALID_CROSS_REVIEWER_AGREEMENT``;
      - ``cross_cycle_pattern`` is a list whose elements ∈
        ``VALID_CROSS_CYCLE_PATTERN``;
      - ``impact_class`` is a single string ∈ ``VALID_IMPACT_CLASS``.

    The three v1.1.0 fields are REQUIRED — a missing field raises ``ValueError``.

    Legacy v1.0.0 rulings (or rulings with no ``schema_version`` at all) are
    treated as backward-compat and skip the v1.1.0 enrichment checks; only the
    base ``ruling`` enum is enforced.

    Args:
        ruling: A ruling dict with a 'ruling' key.

    Returns:
        The ruling dict unchanged if valid.

    Raises:
        ValueError: If ruling['ruling'] is not in VALID_RULINGS, or — for
            schema_version >= 1.1.0 — if any v1.1.0 enrichment field is missing
            or contains an unknown enum value.
    """
    ruling_value = ruling.get("ruling", "")
    if ruling_value not in VALID_RULINGS:
        raise ValueError(
            f"Unknown ruling {ruling_value!r}. Must be one of {sorted(VALID_RULINGS)}"
        )

    # v1.1.0 enrichment-field enforcement (gated on schema_version).
    # String compare is sufficient for "1.x.y" dotted versions where each
    # component is a single digit — the schema lives in a small, controlled
    # vocabulary (1.0.0, 1.1.0) and an explicit lexical >= covers both.
    schema_version = ruling.get("schema_version", "1.0.0")
    if schema_version >= "1.1.0":
        # All three enriched fields must be present.
        for field in _V1_1_0_REQUIRED_FIELDS:
            if field not in ruling:
                raise ValueError(
                    f"Required v1.1.0 field {field!r} missing from ruling "
                    f"(schema_version={schema_version!r})"
                )

        # cross_reviewer_agreement: list of strings, each ∈ VALID_CROSS_REVIEWER_AGREEMENT.
        # Cardinality: 1 or more (per code-reviewer-arbiter.md schema contract).
        cra = ruling["cross_reviewer_agreement"]
        if not isinstance(cra, list):
            raise ValueError(
                f"cross_reviewer_agreement must be a list, got {type(cra).__name__}"
            )
        if not cra:
            raise ValueError(
                "cross_reviewer_agreement must contain at least one value "
                "(schema cardinality: 1+)"
            )
        for value in cra:
            if value not in VALID_CROSS_REVIEWER_AGREEMENT:
                raise ValueError(
                    f"Unknown cross_reviewer_agreement value {value!r}. "
                    f"Must be one of {sorted(VALID_CROSS_REVIEWER_AGREEMENT)}"
                )

        # cross_cycle_pattern: list of strings, each ∈ VALID_CROSS_CYCLE_PATTERN.
        # Cardinality: 1 or more (per code-reviewer-arbiter.md schema contract).
        ccp = ruling["cross_cycle_pattern"]
        if not isinstance(ccp, list):
            raise ValueError(
                f"cross_cycle_pattern must be a list, got {type(ccp).__name__}"
            )
        if not ccp:
            raise ValueError(
                "cross_cycle_pattern must contain at least one value "
                "(schema cardinality: 1+)"
            )
        for value in ccp:
            if value not in VALID_CROSS_CYCLE_PATTERN:
                raise ValueError(
                    f"Unknown cross_cycle_pattern value {value!r}. "
                    f"Must be one of {sorted(VALID_CROSS_CYCLE_PATTERN)}"
                )

        # impact_class: single string ∈ VALID_IMPACT_CLASS.
        impact = ruling["impact_class"]
        if impact not in VALID_IMPACT_CLASS:
            raise ValueError(
                f"Unknown impact_class {impact!r}. "
                f"Must be one of {sorted(VALID_IMPACT_CLASS)}"
            )

    return ruling


def _enforce_cove_fallback(
    ruling: dict[str, Any], cycle_num: int, max_cycles: int
) -> dict[str, Any]:
    """Reclassify BLOCK to DEFER when cycle_num exceeds max_cycles (CoVe soft-cap).

    Args:
        ruling: A ruling dict with a 'ruling' key.
        cycle_num: Current review cycle number.
        max_cycles: Configured maximum review cycles.

    Returns:
        The ruling dict, with ruling='DEFER' if BLOCK was issued past the cycle cap.
    """
    if ruling.get("ruling") == "BLOCK" and cycle_num > max_cycles:
        result = dict(ruling)
        result["ruling"] = "DEFER"
        result["rationale"] = (
            f"CoVe soft-cap: cycle_num={cycle_num} > max_cycles={max_cycles} — "
            "BLOCK reclassified to DEFER to force convergence"
        )
        return result
    return ruling


def _enforce_impact_class_floor(ruling: dict[str, Any]) -> dict[str, Any]:
    """Reclassify BLOCK to DEFER when impact_class='none' (outside 8-category floor).

    Per the BLOCK-gate AND-logic in code-reviewer-arbiter.md, BLOCK requires
    impact_class to be in the 8-category floor (NOT 'none'). A finding without
    real impact (style, hygiene, refactor) must not block a merge — it gets
    DEFER ruling so it's tracked but not blocking.

    Only applies to rulings with schema_version >= "1.1.0" (legacy rulings
    without impact_class field are passed through unchanged).
    """
    if ruling.get("schema_version", "1.0.0") < "1.1.0":
        return ruling
    if ruling.get("ruling") == "BLOCK" and ruling.get("impact_class") == "none":
        result = dict(ruling)
        result["ruling"] = "DEFER"
        original_rationale = result.get("rationale", "")
        result["rationale"] = (
            f"impact_class floor: impact_class='none' is outside 8-category BLOCK floor — "
            f"BLOCK reclassified to DEFER. Original: {original_rationale}"
        )
        return result
    return ruling


def compute_ruling_from_fixture(fixture: dict) -> dict:
    """Apply CoVe fallback and validate on a pre-stored arbiter_ruling from a fixture.

    Used by shell replay tests to exercise the deterministic arbiter pipeline
    (CoVe soft-cap + ruling validation) without requiring LLM dispatch.

    Args:
        fixture: dict with keys 'arbiter_ruling', 'cycle', 'max_cycles'

    Returns:
        The effective ruling dict after CoVe fallback and validation.

    Raises:
        ValueError: if ruling is not in VALID_RULINGS after CoVe fallback.
    """
    ruling = dict(fixture["arbiter_ruling"])
    cycle_num = int(fixture.get("cycle", 1))
    max_cycles = int(fixture.get("max_cycles", 4))
    ruling = _enforce_cove_fallback(ruling, cycle_num, max_cycles)
    ruling = _enforce_impact_class_floor(ruling)
    return validate_cycle_end_ruling(ruling)


def dispatch_arbiter(
    findings: list[dict[str, Any]],
    defenses: list[dict[str, Any]],
    diff_text: str,
    model: str,
    provider_chain: list[str],
    cycle_num: int,
    max_cycles: int,
    reviewer_breakdown: dict[str, list[str]] | None = None,
    ledger_history: list[dict[str, Any]] | None = None,
) -> list[dict[str, Any]]:
    """Dispatch the cycle-end consolidation arbiter for a list of findings.

    Calls the code-reviewer-arbiter agent via dispatch_review and processes
    each finding's ruling through CoVe fallback and validation.

    Args:
        findings: List of unresolved finding dicts from the current review cycle.
        defenses: List of defense dicts submitted across all cycles.
        diff_text: Unified diff text under review.
        model: Primary model identifier to use.
        provider_chain: Ordered list of provider names.
        cycle_num: Current review cycle number.
        max_cycles: Configured maximum review cycles.
        reviewer_breakdown: Optional mapping ``finding_id -> [reviewer_agent_id, ...]``
            recording which reviewer agents flagged each finding in the current
            cycle. Serialized into the agent input (augmented ``diff_text``) so
            the agent can derive ``cross_reviewer_agreement`` per finding. See
            bug eb3d-f283 for the fix that closed this wiring gap.
        ledger_history: Optional list of prior cycle ledger entries (most recent
            last) sourced from cycle-ledger.json. Serialized into the agent
            input (augmented ``diff_text``) so the agent can derive
            ``cross_cycle_pattern`` per finding. See bug eb3d-f283 for the fix
            that closed this wiring gap.

    Returns:
        A list of per-finding ruling dicts, each containing:
        - ruling: one of BLOCK, DEFER, DROP
        - rationale: one-sentence explanation
        - schema_version: "1.0.0"

    Context threading: ``findings``, ``defenses``, ``reviewer_breakdown``, and
    ``ledger_history`` are all serialized into the agent input by appending
    labeled JSON blocks to ``diff_text`` before calling ``dispatch_review``
    (same pattern as ``dispatch_two_call_review`` and
    ``dispatch_arch_synthesis``). Without this, the agent sees only the diff
    and cannot enumerate per-finding rulings — see bug eb3d-f283.

    The agent contract (see the ``code-reviewer-arbiter`` agent file under
    ``${CLAUDE_PLUGIN_ROOT}/agents/``) specifies the output as a JSON array
    with one element per input finding. A single dict response is accepted
    for backward compatibility and wrapped in a list.

    Length-mismatch handling (AC amendment): if the agent returns a number of
    rulings that does not match the input findings, dispatch is treated as a
    failure and the function emits fail-closed synthetic BLOCK rulings for
    every critical/important finding (matches T2 fail-closed behavior). The
    mismatch is logged to stderr as ``arbiter_length_mismatch``.

    Dispatch-failure handling (AC amendment, T2): if dispatch_review raises a
    transport/parse failure (subprocess.CalledProcessError, json.JSONDecodeError,
    or any OSError including ConnectionError/TimeoutError), the function emits
    fail-closed synthetic BLOCK rulings for every critical/important finding.
    Each synthetic ruling preserves the original ``severity`` and the input
    ``finding_index``. Empty findings + dispatch failure returns an empty list
    (no synthetic BLOCK for a nonexistent finding). The failure is logged to
    stderr as ``arbiter_dispatch_failed reason=<exc> finding_count=<n>``.

    NOTE: bare ``Exception`` is intentionally NOT caught — that would mask
    downstream programming bugs as fake BLOCK rulings, defeating the purpose
    of the fail-closed signal.
    """
    # Empty findings: no dispatch needed, return empty (no synthetic BLOCK for
    # nonexistent findings — would be meaningless and would pollute the gate).
    if not findings:
        return []

    # Augment diff_text with serialized JSON context blocks so the arbiter
    # agent can enumerate per-finding rulings. Matches the pattern in
    # dispatch_two_call_review (dispatch.py "## Prior review findings index")
    # and dispatch_arch_synthesis (dispatch.py "## Prior specialist findings").
    # Bug eb3d-f283: without this, the agent saw only the diff and returned a
    # single ruling, triggering the length-mismatch all-BLOCK fallback.
    augmented_diff = (
        diff_text
        + "\n\n## Unresolved findings (cycle "
        + str(cycle_num)
        + " of "
        + str(max_cycles)
        + ")\n\n"
        + _json.dumps(findings, indent=2)
        + "\n\n## Defenses\n\n"
        + _json.dumps(defenses, indent=2)
        + "\n\n## Reviewer breakdown\n\n"
        + _json.dumps(reviewer_breakdown or {}, indent=2)
        + "\n\n## Cycle ledger history\n\n"
        + _json.dumps(ledger_history or [], indent=2)
    )

    try:
        result = dispatch_review(
            diff_text=augmented_diff,
            agent_id="code-reviewer-arbiter",
            primary_model=model,
            provider_chain=provider_chain,
        )
    except _DISPATCH_FAILURE_EXCEPTIONS as exc:
        print(
            f"arbiter_dispatch_failed reason={type(exc).__name__} "
            f"finding_count={len(findings)}",
            file=sys.stderr,
        )
        exc_msg = str(exc)[:200]
        return [
            {
                "ruling": "BLOCK",
                "rationale": (
                    f"Arbiter dispatch failed: {type(exc).__name__}: {exc_msg}; "
                    "defaulting to BLOCK; manual review required."
                ),
                "schema_version": "1.0.0",
                "finding_index": i,
                "severity": finding.get("severity", ""),
                "finding_hash": finding.get("finding_hash", ""),
            }
            for i, finding in enumerate(findings)
            if finding.get("severity") in ("critical", "important")
        ]

    # Agent contract: returns a JSON array of per-finding rulings.
    # Backward-compat: a single-ruling dict response is wrapped in a list.
    if isinstance(result, dict):
        rulings_list = [result]
    elif isinstance(result, list):
        rulings_list = result
    else:
        raise ValueError(
            f"Arbiter returned unexpected type: {type(result).__name__}; "
            "expected list of per-finding ruling dicts or a single ruling dict."
        )

    # Length-mismatch detection (AC amendment): treat as dispatch failure.
    if len(rulings_list) != len(findings):
        print(
            f"arbiter_length_mismatch findings={len(findings)} "
            f"rulings={len(rulings_list)}",
            file=sys.stderr,
        )
        return [
            {
                "ruling": "BLOCK",
                "rationale": (
                    f"Arbiter response length mismatch (got {len(rulings_list)} "
                    f"rulings for {len(findings)} findings); defaulting to BLOCK; "
                    "manual review required."
                ),
                "schema_version": "1.0.0",
                "finding_index": i,
                "severity": finding.get("severity", ""),
                "finding_hash": finding.get("finding_hash", ""),
            }
            for i, finding in enumerate(findings)
            if finding.get("severity") in ("critical", "important")
        ]

    # Per-finding processing: schema_version, CoVe fallback, validation.
    validated_rulings: list[dict[str, Any]] = []
    for ruling in rulings_list:
        if "schema_version" not in ruling:
            ruling["schema_version"] = "1.0.0"
        ruling = _enforce_cove_fallback(ruling, cycle_num, max_cycles)
        ruling = _enforce_impact_class_floor(ruling)
        validate_cycle_end_ruling(ruling)
        validated_rulings.append(ruling)

    return validated_rulings


def dispatch_cycle_end_arbiter(
    findings: list[dict[str, Any]],
    defenses: list[dict[str, Any]],
    diff_text: str,
    model: str,
    provider_chain: list[str],
    cycle_num: int,
    max_cycles: int,
    reviewer_breakdown: dict[str, list[str]] | None = None,
    ledger_history: list[dict[str, Any]] | None = None,
) -> list[dict[str, Any]]:
    """Cycle-end consolidation arbiter entry point. Delegates to dispatch_arbiter.

    Args:
        findings: List of unresolved finding dicts.
        defenses: List of defense dicts.
        diff_text: Unified diff text under review.
        model: Primary model identifier.
        provider_chain: Ordered list of provider names.
        cycle_num: Current review cycle number.
        max_cycles: Configured maximum review cycles.
        reviewer_breakdown: Optional ``finding_id -> [reviewer_agent_id, ...]``
            mapping for ``cross_reviewer_agreement`` derivation. See
            ``dispatch_arbiter`` for details.
        ledger_history: Optional list of prior cycle ledger entries for
            ``cross_cycle_pattern`` derivation. See ``dispatch_arbiter`` for
            details.

    Returns:
        List of per-finding ruling dicts from dispatch_arbiter.
    """
    return dispatch_arbiter(
        findings,
        defenses,
        diff_text,
        model,
        provider_chain,
        cycle_num,
        max_cycles,
        reviewer_breakdown=reviewer_breakdown,
        ledger_history=ledger_history,
    )
