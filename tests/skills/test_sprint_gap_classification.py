"""RED tests for gap classification logic in sprint Phase 7 (Remediation).

Epic ca76-bb4e: Sprint Phase 7 gap classification routing.

These tests assert that sprint/SKILL.md contains gap classification logic
that:
1. Mentions Gap Classification as a named step/concept in Phase 7
2. Uses the canonical signal values: intent_gap and implementation_gap
3. Requires user confirmation before routing intent_gap to brainstorm
4. Documents the failure fallback to intent_gap (safer default)

Tests 1, 2, 3, 5, 6 must FAIL against unmodified sprint/SKILL.md (RED).
Test 4 (regex parsing of sample lines from the contract) should PASS —
it validates the parser regex against hardcoded sample strings, not SKILL.md.
"""

import pathlib
import re

REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
SKILL_MD = REPO_ROOT / "plugins" / "dso" / "skills" / "sprint" / "SKILL.md"

# Canonical signal regex per gap-classification-output.md contract
GAP_CLASSIFICATION_RE = re.compile(
    r"GAP_CLASSIFICATION:\s+(intent_gap|implementation_gap)"
    r"\s+ROUTING:\s+(brainstorm|implementation-plan)"
    r"\s+EXPLANATION:\s+(.+)"
)


def _read_skill() -> str:
    return SKILL_MD.read_text()


def test_sprint_phase7_gap_classification_step_exists() -> None:
    """Sprint SKILL.md Phase 7 must mention 'Gap Classification' (case-insensitive).

    The gap-classification sub-agent dispatch must be a named, identifiable
    step in Phase 7 (Remediation) so the orchestrator cannot rationalize
    past it. Asserts RED against unmodified SKILL.md.
    """
    content = _read_skill()
    assert re.search(r"gap.classif", content, re.IGNORECASE), (
        "Expected sprint/SKILL.md to contain 'Gap Classification' (or 'gap-classification') "
        "as a named concept in Phase 7 (Remediation). "
        "The gap-classification sub-agent dispatch must be explicitly named so the "
        "orchestrator cannot rationalize past it. "
        "Add a Phase 7 step that references gap classification by name."
    )


def test_sprint_phase7_mentions_intent_gap() -> None:
    """Sprint SKILL.md must contain the signal value 'intent_gap'.

    The parser in Phase 7 must name the canonical classification values from
    the gap-classification-output.md contract. 'intent_gap' is the safer
    default and the value that triggers user confirmation + brainstorm routing.
    Asserts RED against unmodified SKILL.md.
    """
    content = _read_skill()
    assert "intent_gap" in content, (
        "Expected sprint/SKILL.md to contain the canonical signal value 'intent_gap'. "
        "Phase 7 (Remediation) must name the classification values it parses from the "
        "gap-classification sub-agent output per the gap-classification-output.md contract. "
        "Add 'intent_gap' to the Phase 7 routing logic."
    )


def test_sprint_phase7_mentions_implementation_gap() -> None:
    """Sprint SKILL.md must contain the signal value 'implementation_gap'.

    The parser in Phase 7 must name both canonical classification values from
    the gap-classification-output.md contract. 'implementation_gap' is the
    value that permits autonomous implementation-plan routing.
    Asserts RED against unmodified SKILL.md.
    """
    content = _read_skill()
    assert "implementation_gap" in content, (
        "Expected sprint/SKILL.md to contain the canonical signal value 'implementation_gap'. "
        "Phase 7 (Remediation) must name both classification values it parses from the "
        "gap-classification sub-agent output per the gap-classification-output.md contract. "
        "Add 'implementation_gap' to the Phase 7 routing logic."
    )


def test_sprint_phase7_gap_classification_signal_parseable() -> None:
    """The canonical GAP_CLASSIFICATION signal regex must match contract sample lines.

    This test validates the parser regex against hardcoded sample strings from
    the gap-classification-output.md contract — it does NOT read SKILL.md.
    This test SHOULD PASS even against unmodified SKILL.md (validates the regex).
    """
    # Sample lines from the contract (Examples section)
    sample_implementation_gap = (
        "GAP_CLASSIFICATION: implementation_gap ROUTING: implementation-plan "
        "EXPLANATION: The SC requires the /api/users endpoint to return paginated results, "
        "but the current implementation returns all records. The endpoint exists and the "
        "intent is clear; only the pagination logic is missing."
    )
    sample_intent_gap = (
        "GAP_CLASSIFICATION: intent_gap ROUTING: brainstorm "
        "EXPLANATION: The SC states users should see their history in real-time but the "
        "implementation is built on a batch-sync architecture. Real-time delivery would "
        "require redesigning the sync layer — this is an intent-level conflict, not an "
        "incomplete implementation."
    )
    sample_multi_1 = (
        "GAP_CLASSIFICATION: implementation_gap ROUTING: implementation-plan "
        "EXPLANATION: The CSV export SC is unimplemented; the endpoint stub exists but "
        "the serializer is missing."
    )
    sample_multi_2 = (
        "GAP_CLASSIFICATION: intent_gap ROUTING: brainstorm "
        "EXPLANATION: The SC requires offline access, but the current architecture "
        "requires active network connectivity at all layers. This is an architectural "
        "conflict requiring brainstorm re-examination."
    )

    for sample in [
        sample_implementation_gap,
        sample_intent_gap,
        sample_multi_1,
        sample_multi_2,
    ]:
        m = GAP_CLASSIFICATION_RE.search(sample)
        assert m is not None, (
            f"GAP_CLASSIFICATION regex failed to match sample line:\n  {sample}\n"
            "The canonical parsing regex must match all sample lines from the contract."
        )
        classification = m.group(1)
        routing = m.group(2)
        explanation = m.group(3)

        # Validate ROUTING ↔ classification invariant
        if classification == "intent_gap":
            assert routing == "brainstorm", (
                f"intent_gap must route to brainstorm, got: {routing}"
            )
        elif classification == "implementation_gap":
            assert routing == "implementation-plan", (
                f"implementation_gap must route to implementation-plan, got: {routing}"
            )

        assert explanation.strip(), "EXPLANATION must not be empty"


def test_sprint_phase7_requires_user_confirmation_for_intent_gap() -> None:
    """Sprint SKILL.md must require user confirmation before routing intent_gap to brainstorm.

    Per the gap-classification-output.md contract (Routing Behavior section):
    'When a SC is classified as intent_gap, the sprint orchestrator MUST pause
    and present the classification and explanation to the user before invoking
    /dso:brainstorm. Autonomous invocation of brainstorm without user confirmation
    is prohibited.'
    Asserts RED against unmodified SKILL.md.
    """
    content = _read_skill()

    # Check for user confirmation language near intent_gap content
    # Find intent_gap occurrences and check surrounding context
    intent_gap_positions = [m.start() for m in re.finditer(r"intent_gap", content)]

    if not intent_gap_positions:
        raise AssertionError(
            "Expected sprint/SKILL.md to contain 'intent_gap' with adjacent user "
            "confirmation requirements. Neither 'intent_gap' nor user confirmation "
            "language was found. Phase 7 must require explicit user approval before "
            "routing intent_gap SCs to brainstorm."
        )

    # Look for user confirmation language anywhere near intent_gap references
    has_confirmation = False
    for pos in intent_gap_positions:
        # Check ±1000 chars around each intent_gap occurrence
        window_start = max(0, pos - 1000)
        window_end = min(len(content), pos + 1000)
        window = content[window_start:window_end]
        if re.search(
            r"user.confirm|explicit.*approv|pause.*user|present.*user|ask.*user|user.*approv",
            window,
            re.IGNORECASE,
        ):
            has_confirmation = True
            break

    assert has_confirmation, (
        "Expected sprint/SKILL.md to require user confirmation before routing "
        "'intent_gap' SCs to brainstorm. Found 'intent_gap' but no adjacent "
        "user confirmation language (e.g., 'user confirmation', 'explicit approval', "
        "'pause and present to user'). "
        "Per the gap-classification-output.md contract, autonomous brainstorm invocation "
        "without user confirmation is prohibited for intent_gap classifications."
    )


def test_sprint_phase7_failure_fallback_to_intent_gap() -> None:
    """Sprint SKILL.md must document that malformed/absent signals fall back to intent_gap.

    Per the gap-classification-output.md contract (Failure Contract section):
    'If the gap-classification sub-agent output is absent, malformed, or contains
    an unrecognized classification value, then the parser MUST treat all affected
    failing SCs as intent_gap and route them to brainstorm with user confirmation
    required.'
    Asserts RED against unmodified SKILL.md.
    """
    content = _read_skill()

    # Must document fallback behavior — absent/malformed output → intent_gap
    has_fallback = re.search(
        r"fallback.*intent_gap|intent_gap.*fallback"
        r"|default.*intent_gap|intent_gap.*default"
        r"|malformed.*intent_gap|absent.*intent_gap"
        r"|failure.*intent_gap|intent_gap.*failure",
        content,
        re.IGNORECASE,
    )

    assert has_fallback, (
        "Expected sprint/SKILL.md to document the failure fallback: absent, malformed, "
        "or unrecognized gap-classification output must be treated as 'intent_gap'. "
        "Per the gap-classification-output.md contract Failure Contract section, "
        "this is the safer default — it requires user confirmation before any "
        "autonomous action and avoids misrouting ambiguous signals. "
        "Add failure fallback documentation to Phase 7 (Remediation)."
    )
