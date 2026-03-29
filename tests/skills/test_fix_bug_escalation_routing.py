"""Structural metadata validation of skill file — design contract verification.

TDD spec for task b470-27ba (RED task):
- plugins/dso/skills/fix-bug/SKILL.md must contain escalation routing integration documentation:
  1. An escalation routing section heading
  2. Reference to gate-escalation-router.py script
  3. Documentation of the 0-signal auto-fix path (proceeds without user interaction)
  4. Documentation of the 1-signal quick dialog path (1-2 questions inline dialog)
  5. Documentation of the 2+-signal escalation path (escalate to /dso:brainstorm)
  6. Documentation that COMPLEX always escalates regardless of signal count
  7. Routing section appears after all gate sections (after Gate 2d)
  8. Documentation of debug-everything interactivity flag integration

All tests fail RED because the escalation routing section is not yet present in SKILL.md.
"""

import pathlib
import re

REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
SKILL_FILE = REPO_ROOT / "plugins" / "dso" / "skills" / "fix-bug" / "SKILL.md"


def _read_skill() -> str:
    return SKILL_FILE.read_text()


class TestFixBugEscalationRoutingDesignContract:
    """Tests asserting the escalation routing design contract is documented in fix-bug SKILL.md.

    The escalation routing integration is the layer that counts primary gate signals
    (from gates 1b, 2a, 2c, 2d) and routes the fix workflow proportionally:
    0 signals -> auto-fix, 1 signal -> quick dialog, 2+ signals -> /dso:brainstorm epic,
    COMPLEX -> always escalate. These tests verify that the skill documents the routing
    section, the script it delegates to, all three routing paths, the COMPLEX override,
    the routing position relative to gate sections, and the debug-everything interactivity
    flag integration.
    """

    def test_routing_section_exists(self) -> None:
        """SKILL.md must contain an escalation routing section heading."""
        content = _read_skill()
        has_routing_heading = bool(
            re.search(
                r"^#{1,4}\s+.*[Ee]scalation\s+[Rr]outing",
                content,
                re.MULTILINE,
            )
        )
        assert has_routing_heading, (
            "Expected SKILL.md to contain a markdown section heading for the escalation "
            "routing integration (e.g., '### Escalation Routing' or '### Step N: Escalation "
            "Routing'). The escalation routing section is the integration layer that collects "
            "primary gate signals from all gates (1b, 2a, 2c, 2d) and decides whether to "
            "proceed automatically (0 signals), prompt inline (1 signal), or escalate to an "
            "epic (2+ signals or COMPLEX). "
            "This is a RED test — the escalation routing section heading has not yet been "
            "added to SKILL.md."
        )

    def test_routing_dispatches_script(self) -> None:
        """SKILL.md must reference gate-escalation-router.py as the routing implementation."""
        content = _read_skill()
        assert "gate-escalation-router.py" in content, (
            "Expected SKILL.md to contain 'gate-escalation-router.py' to document the "
            "script that implements escalation routing logic — collecting primary signal "
            "counts across all gates and returning the routing decision (auto-fix, dialog, "
            "or escalate). "
            "This is a RED test — the script reference has not yet been added to SKILL.md."
        )

    def test_auto_fix_path(self) -> None:
        """SKILL.md must document the 0-signal auto-fix path that proceeds without user interaction."""
        content = _read_skill()
        router_idx = content.find("gate-escalation-router.py")
        assert router_idx != -1, (
            "Expected SKILL.md to reference 'gate-escalation-router.py'. "
            "This is a RED test — the escalation routing section has not yet been added to SKILL.md."
        )
        routing_context = content[max(0, router_idx - 500) : router_idx + 3000]
        # The 0-signal auto-fix path must be explicitly documented: when no primary gates
        # fire, the fix proceeds autonomously without pausing for user input.
        has_zero_signal_doc = (
            "0 signal" in routing_context.lower()
            or "zero signal" in routing_context.lower()
            or ("0" in routing_context and "auto" in routing_context.lower())
            or "no primary" in routing_context.lower()
        )
        assert has_zero_signal_doc, (
            "Expected the escalation routing section of SKILL.md to document the 0-signal "
            "auto-fix path: when zero primary gates fire, the fix proceeds autonomously "
            "without any user interaction. This is the base case where no escalation signals "
            "were collected from gates 1b, 2a, 2c, or 2d. "
            "This is a RED test — the 0-signal auto-fix path has not yet been documented "
            "in the escalation routing section of SKILL.md."
        )

    def test_dialog_path(self) -> None:
        """SKILL.md must document the 1-signal quick dialog path with blast radius context."""
        content = _read_skill()
        router_idx = content.find("gate-escalation-router.py")
        assert router_idx != -1, (
            "Expected SKILL.md to reference 'gate-escalation-router.py'. "
            "This is a RED test — the escalation routing section has not yet been added to SKILL.md."
        )
        routing_context = content[max(0, router_idx - 500) : router_idx + 3000]
        # The 1-signal dialog path must be documented: exactly 1 primary signal -> inline
        # dialog with 1-2 questions, enriched with blast radius context from Gate 2b.
        has_one_signal_doc = (
            "1 signal" in routing_context.lower()
            or "one signal" in routing_context.lower()
            or "1-2 question" in routing_context.lower()
            or "quick dialog" in routing_context.lower()
            or (
                "dialog" in routing_context.lower()
                and "blast radius" in routing_context.lower()
            )
        )
        assert has_one_signal_doc, (
            "Expected the escalation routing section of SKILL.md to document the 1-signal "
            "quick dialog path: when exactly one primary gate fires, fix-bug prompts a "
            "1-2 question inline dialog, optionally enriched with blast radius context from "
            "Gate 2b if available. This dialog is brief and inline — not a full epic escalation. "
            "This is a RED test — the 1-signal quick dialog path has not yet been documented "
            "in the escalation routing section of SKILL.md."
        )

    def test_escalate_path(self) -> None:
        """SKILL.md must document the 2+-signal escalation path to /dso:brainstorm."""
        content = _read_skill()
        router_idx = content.find("gate-escalation-router.py")
        assert router_idx != -1, (
            "Expected SKILL.md to reference 'gate-escalation-router.py'. "
            "This is a RED test — the escalation routing section has not yet been added to SKILL.md."
        )
        routing_context = content[max(0, router_idx - 500) : router_idx + 3000]
        # The 2+-signal escalation path must be documented: 2 or more primary signals
        # trigger escalation to /dso:brainstorm for epic treatment.
        has_two_plus_doc = (
            "2+" in routing_context
            or "2 or more" in routing_context.lower()
            or "two or more" in routing_context.lower()
            or "/dso:brainstorm" in routing_context
        )
        assert has_two_plus_doc, (
            "Expected the escalation routing section of SKILL.md to document the 2+-signal "
            "escalation path: when two or more primary gates fire, the bug is escalated to "
            "/dso:brainstorm for epic treatment. This is the high-signal case where the fix "
            "complexity warrants a structured epic rather than an inline fix. "
            "This is a RED test — the 2+-signal escalation path has not yet been documented "
            "in the escalation routing section of SKILL.md."
        )

    def test_complex_override(self) -> None:
        """SKILL.md must document that COMPLEX complexity result always escalates to epic."""
        content = _read_skill()
        router_idx = content.find("gate-escalation-router.py")
        assert router_idx != -1, (
            "Expected SKILL.md to reference 'gate-escalation-router.py'. "
            "This is a RED test — the escalation routing section has not yet been added to SKILL.md."
        )
        routing_context = content[max(0, router_idx - 500) : router_idx + 3000]
        # The COMPLEX override must be documented in the routing section: when the complexity
        # evaluator (Gate 3a) returns COMPLEX, the routing always escalates regardless of the
        # primary signal count — even 0 or 1 signal.
        has_complex_override = "COMPLEX" in routing_context and (
            "always" in routing_context.lower()
            or "override" in routing_context.lower()
            or "regardless" in routing_context.lower()
        )
        assert has_complex_override, (
            "Expected the escalation routing section of SKILL.md to document that when the "
            "complexity evaluator returns COMPLEX, the routing always escalates to /dso:brainstorm "
            "regardless of the primary signal count. COMPLEX is an unconditional escalation "
            "override — even 0 primary signals + COMPLEX results in epic escalation. "
            "This is a RED test — the COMPLEX always-escalate override has not yet been "
            "documented in the escalation routing section of SKILL.md."
        )

    def test_routing_after_gates(self) -> None:
        """Escalation routing section must appear after all gate sections (after Gate 2d) in SKILL.md."""
        content = _read_skill()
        router_idx = content.find("gate-escalation-router.py")
        assert router_idx != -1, (
            "Expected SKILL.md to reference 'gate-escalation-router.py'. "
            "This is a RED test — the escalation routing section has not yet been added to SKILL.md."
        )
        # Gate 2d is the last primary gate before routing occurs; routing must follow it.
        assert "Gate 2d" in content, (
            "Expected SKILL.md to contain 'Gate 2d' so that escalation routing positioning "
            "can be verified as occurring after all gate sections."
        )
        gate_2d_pos = content.index("Gate 2d")
        assert gate_2d_pos < router_idx, (
            f"Expected 'Gate 2d' (position {gate_2d_pos}) to appear before "
            f"'gate-escalation-router.py' (position {router_idx}) in SKILL.md. "
            "The escalation routing section collects all gate signals; it must be positioned "
            "after all individual gate sections (1b, 2a, 2b, 2c, 2d) have been defined. "
            "This is a RED test — the escalation routing section has not yet been positioned "
            "after Gate 2d in SKILL.md."
        )

    def test_interactivity_integration(self) -> None:
        """SKILL.md must document integration with debug-everything's interactivity flag."""
        content = _read_skill()
        router_idx = content.find("gate-escalation-router.py")
        assert router_idx != -1, (
            "Expected SKILL.md to reference 'gate-escalation-router.py'. "
            "This is a RED test — the escalation routing section has not yet been added to SKILL.md."
        )
        routing_context = content[max(0, router_idx - 500) : router_idx + 3000]
        # The interactivity flag from debug-everything (Epic A, 2df5-72cb) controls whether
        # the dialog path is available. When non-interactive, 1-signal dialog is deferred
        # as INTERACTIVITY_DEFERRED rather than blocking the workflow.
        has_interactivity_doc = (
            "interactiv" in routing_context.lower()
            or "INTERACTIVITY_DEFERRED" in routing_context
            or "non-interactive" in routing_context.lower()
        )
        assert has_interactivity_doc, (
            "Expected the escalation routing section of SKILL.md to document how the "
            "debug-everything interactivity flag integrates with the routing decision. "
            "When fix-bug runs in non-interactive mode (debug-everything's interactivity "
            "flag), the 1-signal dialog path cannot block for user input — it must defer "
            "as INTERACTIVITY_DEFERRED or a compatible non-blocking alternative. "
            "This is a RED test — the interactivity flag integration has not yet been "
            "documented in the escalation routing section of SKILL.md."
        )
