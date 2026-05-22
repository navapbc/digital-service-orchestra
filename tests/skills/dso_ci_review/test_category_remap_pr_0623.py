"""Tests for the schema-correction category-freeze remediation (bug 0623-54f4-d31b-4623).

Behavioral contracts under test:

1. ``_remap_off_enum_categories`` normalizes the 35 off-enum categories observed
   in PR #257/258 (e.g. ``code_smell``, ``missing_test_coverage``) into the
   canonical 5-value enum {correctness, design, hygiene, maintainability,
   verification}. Unknown off-enum values pass through unchanged so the
   validator can still flag them as a fallback signal.

2. ``dispatch_schema_correction`` ALLOWS a category change during correction
   IFF the original ``category`` is not in the canonical enum (the
   correction-loop must be able to repair off-enum categories the upstream LLM
   emitted).

3. ``dispatch_schema_correction`` STILL REJECTS a category change during
   correction when the original ``category`` IS in the canonical enum (the
   frozen-field invariant remains in force for in-enum originals — the
   exception is scoped to off-enum repair only).

4. Each of the 6 reviewer agent files anchors the canonical enum in plain
   English so the upstream reviewer LLM does not emit off-enum values in the
   first place (defense-in-depth).

These tests EMULATE the failure mode without invoking the real Anthropic
endpoint; the load-bearing integration test
``test_schema_compliance_pr80.py::test_pr80_zero_synthetic_schema_errors``
remains the end-to-end confirmation.
"""

from __future__ import annotations

import copy
import json
import pathlib
import sys
from typing import Any

# Ensure the plugin scripts directory is on sys.path so that
# `dso_ci_review.dispatch` resolves to the plugin, not the test package.
_REPO_ROOT = pathlib.Path(__file__).resolve().parents[3]
_SCRIPTS_DIR = str(_REPO_ROOT / "plugins" / "dso" / "scripts")
if _SCRIPTS_DIR not in sys.path:
    sys.path.insert(0, _SCRIPTS_DIR)

import dso_ci_review.dispatch as _dispatch_mod  # noqa: E402
import dso_ci_review.runner as _runner_mod  # noqa: E402


# ---------------------------------------------------------------------------
# Shared test helpers
# ---------------------------------------------------------------------------

_DIFF_TEXT = "--- a/foo.py\n+++ b/foo.py\n@@ -1 +1 @@\n-x = 1\n+x = 2\n"

_CANONICAL_CATEGORIES = frozenset(
    {"correctness", "design", "hygiene", "maintainability", "verification"}
)


def _make_finding(category: str, **overrides: Any) -> dict[str, Any]:
    base: dict[str, Any] = {
        "severity": "important",
        "category": category,
        "description": "Sample finding for category-remap test.",
        "file": "src/handler.py",
        "cited_lines": ["src/handler.py:42"],
        "finding_id": "f-abc12345",
        "cited_excerpt": "return obj.value",
        "reachability": (
            "Public endpoint accepts user-supplied input that reaches the "
            "bug site at line 42 and produces incorrect output."
        ),
    }
    base.update(overrides)
    return base


# ---------------------------------------------------------------------------
# Test 1 — _remap_off_enum_categories normalizes known off-enum values
# ---------------------------------------------------------------------------


def test_off_enum_categories_remapped() -> None:
    """Given: a synthetic findings array with one off-enum category per canonical
              bucket plus one unknown off-enum value.
    When: ``_remap_off_enum_categories`` is invoked.
    Then:
      - Known off-enum categories are normalized to the canonical bucket.
      - Unknown off-enum values pass through unchanged (the validator may
        still flag them as a fallback signal).
      - Canonical-enum categories are left unchanged.
    """
    # Exercise one representative off-enum value per canonical bucket plus
    # one unknown value plus one already-canonical value.
    findings = [
        _make_finding("missing_implementation"),  # → correctness
        _make_finding("test_fragility"),  # → verification
        _make_finding("code_smell"),  # → hygiene
        _make_finding("code_clarity"),  # → maintainability
        _make_finding("totally_unknown_value_zz"),  # → passthrough
        _make_finding("correctness"),  # canonical, unchanged
    ]

    remapped = _runner_mod._remap_off_enum_categories(findings)

    assert len(remapped) == len(findings), "remap must preserve finding count"

    assert remapped[0]["category"] == "correctness", (
        f"missing_implementation should map to correctness, got {remapped[0]['category']!r}"
    )
    assert remapped[1]["category"] == "verification", (
        f"test_fragility should map to verification, got {remapped[1]['category']!r}"
    )
    assert remapped[2]["category"] == "hygiene", (
        f"code_smell should map to hygiene, got {remapped[2]['category']!r}"
    )
    assert remapped[3]["category"] == "maintainability", (
        f"code_clarity should map to maintainability, got {remapped[3]['category']!r}"
    )
    assert remapped[4]["category"] == "totally_unknown_value_zz", (
        "unknown off-enum values must pass through unchanged so the validator "
        "can flag them as a fallback signal"
    )
    assert remapped[5]["category"] == "correctness", (
        "already-canonical categories must pass through unchanged"
    )


# ---------------------------------------------------------------------------
# Test 2 — dispatch.dispatch_schema_correction allows category repair iff
#          the original is off-enum
# ---------------------------------------------------------------------------


def _make_fake_response(findings: list[dict]) -> Any:
    """Minimal fake litellm response containing the given findings."""
    content = json.dumps({"findings": findings})

    class _FakeMsg:
        pass

    class _FakeChoice:
        pass

    class _FakeResp:
        pass

    msg = _FakeMsg()
    msg.content = content  # type: ignore[attr-defined]
    choice = _FakeChoice()
    choice.message = msg  # type: ignore[attr-defined]
    resp = _FakeResp()
    resp.choices = [choice]  # type: ignore[attr-defined]
    return resp


def _stub_validate_schema_pass(merged: dict, **_kwargs: Any) -> Any:
    return _runner_mod._SchemaValidationResult("schema_pass", [])


def test_dispatch_correction_allows_category_change_when_original_off_enum(
    monkeypatch,
) -> None:
    """Given: an original finding whose ``category`` is OFF the canonical enum
              (e.g. ``code_smell``).
    When: schema-correction returns the same finding with ``category`` remapped
          to a canonical value (e.g. ``hygiene``) and all other frozen fields
          preserved byte-for-byte.
    Then:
      - ``dispatch_schema_correction`` returns the corrected findings WITHOUT
        appending a synthetic ``schema_error`` (the correction succeeds).
      - The frozen-field exception fires only because the original category
        was off-enum; this is the load-bearing assertion.
    """
    original = _make_finding("code_smell")
    corrected = copy.deepcopy(original)
    corrected["category"] = "hygiene"  # repaired to canonical

    def _mock_dispatch_review(**_kwargs: Any) -> dict:
        return {"findings": [corrected]}

    monkeypatch.setattr(_dispatch_mod, "dispatch_review", _mock_dispatch_review)
    monkeypatch.setattr(
        _runner_mod, "_validate_findings_schema", _stub_validate_schema_pass
    )

    result = _dispatch_mod.dispatch_schema_correction(
        original_findings=[original],
        diff_text=_DIFF_TEXT,
        provider_chain=["anthropic"],
        environ={"ANTHROPIC_API_KEY": "test-key"},
        max_attempts=1,
        agent_id="code-reviewer-standard",
    )

    findings = result.get("findings", [])
    synthetic_errors = [f for f in findings if f.get("category") == "schema_error"]
    assert not synthetic_errors, (
        "schema-correction must SUCCEED (no synthetic schema_error) when the "
        "original category is off-enum and the corrected category is canonical; "
        f"got: {synthetic_errors!r}"
    )

    assert len(findings) == 1, (
        f"corrected findings should contain the single repaired finding, got {findings!r}"
    )
    assert findings[0]["category"] == "hygiene", (
        f"corrected category should be the canonical repair value 'hygiene', "
        f"got {findings[0].get('category')!r}"
    )


def test_dispatch_correction_still_rejects_category_change_when_original_canonical(
    monkeypatch,
) -> None:
    """Given: an original finding whose ``category`` is ALREADY canonical
              (e.g. ``correctness``).
    When: schema-correction returns the same finding with ``category`` changed
          to a different canonical value (e.g. ``design``).
    Then:
      - The frozen-field invariant must remain in force: the correction is
        rejected and a synthetic ``schema_error`` is appended after attempts
        exhaust.
    """
    original = _make_finding("correctness")
    corrupted = copy.deepcopy(original)
    corrupted["category"] = "design"  # forbidden — original was canonical

    def _mock_dispatch_review(**_kwargs: Any) -> dict:
        return {"findings": [corrupted]}

    monkeypatch.setattr(_dispatch_mod, "dispatch_review", _mock_dispatch_review)
    monkeypatch.setattr(
        _runner_mod, "_validate_findings_schema", _stub_validate_schema_pass
    )

    result = _dispatch_mod.dispatch_schema_correction(
        original_findings=[original],
        diff_text=_DIFF_TEXT,
        provider_chain=["anthropic"],
        environ={"ANTHROPIC_API_KEY": "test-key"},
        max_attempts=2,
        agent_id="code-reviewer-standard",
    )

    findings = result.get("findings", [])
    synthetic_errors = [
        f
        for f in findings
        if isinstance(f, dict)
        and f.get("type") == "parse_error"
        and f.get("category") == "schema_error"
    ]
    assert synthetic_errors, (
        "schema-correction MUST reject a category change when the original "
        "category was already canonical (frozen-field invariant); expected a "
        f"synthetic schema_error, got findings={findings!r}"
    )


# ---------------------------------------------------------------------------
# Test 3 — All 6 reviewer agent files enumerate the canonical enum verbatim
# ---------------------------------------------------------------------------


def test_reviewer_agent_prompts_enumerate_category_enum() -> None:
    """Given: the 6 reviewer agent files generated by build-review-agents.sh.
    When: searching each file's text.
    Then: each file MUST contain the literal canonical-enum enumeration
          ``correctness|design|hygiene|maintainability|verification`` so the
          upstream LLM does not invent off-enum categories.
    """
    agent_files = [
        "code-reviewer-light.md",
        "code-reviewer-standard.md",
        "code-reviewer-deep-correctness.md",
        "code-reviewer-deep-verification.md",
        "code-reviewer-deep-hygiene.md",
        "code-reviewer-deep-arch.md",
    ]
    agents_dir = _REPO_ROOT / "plugins" / "dso" / "agents"
    anchor = "correctness|design|hygiene|maintainability|verification"

    missing = []
    for fname in agent_files:
        path = agents_dir / fname
        assert path.exists(), f"agent file is missing: {path}"
        text = path.read_text(encoding="utf-8")
        if anchor not in text:
            missing.append(fname)

    assert not missing, (
        "the canonical-enum anchor "
        f"'{anchor}' is absent from these reviewer agent files: {missing!r}. "
        "Each reviewer agent MUST enumerate the canonical 5-value enum verbatim "
        "so the upstream LLM does not invent off-enum categories."
    )
