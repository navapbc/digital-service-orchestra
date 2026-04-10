"""Unit tests for figma_merge.id_validate.validate_id_linkage() (RED phase).

Tests cover:
  - IV-1: All component IDs match across spatial-layout.json, wireframe.svg, tokens.md → empty violations list
  - IV-2: Component ID in spatial-layout.json missing from wireframe.svg → violation with artifact='wireframe.svg'
  - IV-3: Component ID in spatial-layout.json missing from tokens.md → violation with artifact='tokens.md'
  - IV-4: <g id=...> in wireframe.svg with no corresponding component in spatial-layout.json → orphaned violation
  - IV-5: Violations have required fields: id, artifact, violation_type (missing|orphaned)
  - IV-6: Empty violations list → len(violations)==0 indicates clean linkage

All tests are expected to FAIL (ImportError / ModuleNotFoundError) because
figma_merge/id_validate.py does not exist yet (RED phase of TDD).
"""

from __future__ import annotations

import sys
from pathlib import Path


# ---------------------------------------------------------------------------
# Path setup — add scripts directory so 'figma_merge' package is discoverable.
# The submodule id_validate does not exist yet, so the import below will raise
# ModuleNotFoundError (RED phase).
# ---------------------------------------------------------------------------

REPO_ROOT = Path(__file__).resolve().parents[2]
_SCRIPTS_DIR = REPO_ROOT / "plugins" / "dso" / "scripts"
if str(_SCRIPTS_DIR) not in sys.path:
    sys.path.insert(0, str(_SCRIPTS_DIR))

# This import will fail with ModuleNotFoundError until id_validate.py is implemented.
from figma_merge.id_validate import validate_id_linkage  # noqa: E402


# ---------------------------------------------------------------------------
# Test helpers — minimal in-memory artifact representations
# ---------------------------------------------------------------------------


def _make_spatial(component_ids: list[str]) -> dict:
    """Return a minimal spatial-layout.json structure with given component IDs."""
    return {"components": [{"id": cid, "label": cid} for cid in component_ids]}


def _make_wireframe(component_ids: list[str]) -> str:
    """Return a minimal SVG string with <g id=...> elements for given IDs."""
    groups = "\n".join(f'  <g id="{cid}"></g>' for cid in component_ids)
    return f'<svg xmlns="http://www.w3.org/2000/svg">\n{groups}\n</svg>'


def _make_tokens(component_ids: list[str]) -> str:
    """Return a minimal tokens.md string referencing given component IDs."""
    lines = [f"## {cid}\n- color: #000\n" for cid in component_ids]
    return "\n".join(lines)


# ---------------------------------------------------------------------------
# IV-1: All IDs consistent → empty violations list
# ---------------------------------------------------------------------------


class TestAllIdsConsistent:
    """IV-1: When all component IDs match across all three artifacts, violations list is empty."""

    def test_all_ids_match_returns_empty_violations(self) -> None:
        """IV-1: Given consistent spatial-layout.json, wireframe.svg, and tokens.md,
        validate_id_linkage() returns an empty list."""
        ids = ["header", "footer", "nav-bar"]
        spatial = _make_spatial(ids)
        wireframe = _make_wireframe(ids)
        tokens = _make_tokens(ids)

        violations = validate_id_linkage(spatial, wireframe, tokens)

        assert violations == [], (
            f"Expected no violations when all IDs match, got: {violations}"
        )


# ---------------------------------------------------------------------------
# IV-2: Component ID in spatial-layout.json missing from wireframe.svg
# ---------------------------------------------------------------------------


class TestMissingFromWireframe:
    """IV-2: Component ID in spatial-layout.json that has no <g id=...> in wireframe.svg."""

    def test_missing_wireframe_id_reported_with_correct_artifact(self) -> None:
        """IV-2: Given a component ID in spatial-layout.json that has no matching
        <g id=...> in wireframe.svg, violations list contains that ID with artifact='wireframe.svg'."""
        spatial_ids = ["header", "missing-in-wireframe"]
        wireframe_ids = ["header"]  # 'missing-in-wireframe' absent
        tokens_ids = ["header", "missing-in-wireframe"]

        spatial = _make_spatial(spatial_ids)
        wireframe = _make_wireframe(wireframe_ids)
        tokens = _make_tokens(tokens_ids)

        violations = validate_id_linkage(spatial, wireframe, tokens)

        matching = [v for v in violations if v.get("id") == "missing-in-wireframe"]
        assert len(matching) >= 1, (
            "Expected a violation for 'missing-in-wireframe' missing from wireframe.svg"
        )
        assert matching[0]["artifact"] == "wireframe.svg", (
            f"Expected artifact='wireframe.svg', got: {matching[0].get('artifact')}"
        )


# ---------------------------------------------------------------------------
# IV-3: Component ID in spatial-layout.json not referenced in tokens.md
# ---------------------------------------------------------------------------


class TestMissingFromTokens:
    """IV-3: Component ID in spatial-layout.json that is not referenced in tokens.md."""

    def test_missing_tokens_id_reported_with_correct_artifact(self) -> None:
        """IV-3: Given a component ID in spatial-layout.json that is not referenced in tokens.md,
        violations list contains that ID with artifact='tokens.md'."""
        spatial_ids = ["header", "missing-in-tokens"]
        wireframe_ids = ["header", "missing-in-tokens"]
        tokens_ids = ["header"]  # 'missing-in-tokens' absent

        spatial = _make_spatial(spatial_ids)
        wireframe = _make_wireframe(wireframe_ids)
        tokens = _make_tokens(tokens_ids)

        violations = validate_id_linkage(spatial, wireframe, tokens)

        matching = [v for v in violations if v.get("id") == "missing-in-tokens"]
        assert len(matching) >= 1, (
            "Expected a violation for 'missing-in-tokens' missing from tokens.md"
        )
        assert matching[0]["artifact"] == "tokens.md", (
            f"Expected artifact='tokens.md', got: {matching[0].get('artifact')}"
        )


# ---------------------------------------------------------------------------
# IV-4: <g id=...> in wireframe.svg with no corresponding component in spatial-layout.json
# ---------------------------------------------------------------------------


class TestOrphanedInWireframe:
    """IV-4: <g id=...> in wireframe.svg that has no corresponding component in spatial-layout.json."""

    def test_orphaned_wireframe_id_reported(self) -> None:
        """IV-4: Given a <g id=...> in wireframe.svg that has no corresponding component
        in spatial-layout.json, violations list contains that ID as orphaned in wireframe.svg."""
        spatial_ids = ["header"]
        wireframe_ids = ["header", "orphan-in-wireframe"]  # extra ID not in spatial
        tokens_ids = ["header"]

        spatial = _make_spatial(spatial_ids)
        wireframe = _make_wireframe(wireframe_ids)
        tokens = _make_tokens(tokens_ids)

        violations = validate_id_linkage(spatial, wireframe, tokens)

        matching = [v for v in violations if v.get("id") == "orphan-in-wireframe"]
        assert len(matching) >= 1, (
            "Expected a violation for 'orphan-in-wireframe' which is in wireframe.svg "
            "but has no corresponding component in spatial-layout.json"
        )
        assert matching[0]["artifact"] == "wireframe.svg", (
            f"Expected artifact='wireframe.svg' for orphan, got: {matching[0].get('artifact')}"
        )


# ---------------------------------------------------------------------------
# IV-5: Violations have required fields: id, artifact, violation_type
# ---------------------------------------------------------------------------


class TestViolationSchema:
    """IV-5: Violations are dicts with fields: id, artifact, violation_type (missing|orphaned)."""

    def test_violation_dicts_have_required_fields(self) -> None:
        """IV-5: Given violations present, each violation is a dict with fields
        id, artifact, and violation_type (value: 'missing' or 'orphaned')."""
        spatial_ids = ["header"]
        wireframe_ids = []  # 'header' missing from wireframe
        tokens_ids = ["header"]

        spatial = _make_spatial(spatial_ids)
        wireframe = _make_wireframe(wireframe_ids)
        tokens = _make_tokens(tokens_ids)

        violations = validate_id_linkage(spatial, wireframe, tokens)

        assert len(violations) >= 1, "Expected at least one violation for this scenario"
        for v in violations:
            assert "id" in v, f"Violation missing 'id' field: {v}"
            assert "artifact" in v, f"Violation missing 'artifact' field: {v}"
            assert "violation_type" in v, (
                f"Violation missing 'violation_type' field: {v}"
            )
            assert v["violation_type"] in ("missing", "orphaned"), (
                f"violation_type must be 'missing' or 'orphaned', got: {v['violation_type']!r}"
            )

    def test_missing_violation_type_is_missing(self) -> None:
        """IV-5 (missing variant): Violation for a component absent from an artifact has
        violation_type='missing'."""
        spatial_ids = ["button"]
        wireframe_ids = []  # 'button' missing from wireframe
        tokens_ids = ["button"]

        violations = validate_id_linkage(
            _make_spatial(spatial_ids),
            _make_wireframe(wireframe_ids),
            _make_tokens(tokens_ids),
        )

        missing_violations = [
            v for v in violations if v.get("violation_type") == "missing"
        ]
        assert len(missing_violations) >= 1, (
            "Expected violation_type='missing' for a component absent from wireframe.svg"
        )

    def test_orphaned_violation_type_is_orphaned(self) -> None:
        """IV-5 (orphaned variant): Violation for an artifact-only ID has
        violation_type='orphaned'."""
        spatial_ids = []  # no components
        wireframe_ids = ["ghost-component"]  # in wireframe but not spatial
        tokens_ids = []

        violations = validate_id_linkage(
            _make_spatial(spatial_ids),
            _make_wireframe(wireframe_ids),
            _make_tokens(tokens_ids),
        )

        orphaned_violations = [
            v for v in violations if v.get("violation_type") == "orphaned"
        ]
        assert len(orphaned_violations) >= 1, (
            "Expected violation_type='orphaned' for ID in wireframe.svg but not spatial-layout.json"
        )


# ---------------------------------------------------------------------------
# IV-6: Empty violations list means clean linkage (len==0)
# ---------------------------------------------------------------------------


class TestCleanLinkageCheck:
    """IV-6: When validate_id_linkage() returns an empty list, len(violations)==0."""

    def test_empty_violations_list_len_is_zero(self) -> None:
        """IV-6: Given all artifacts consistent and validate_id_linkage() returns empty list,
        len(violations)==0 indicates a clean linkage."""
        ids = ["card", "modal", "tooltip"]
        spatial = _make_spatial(ids)
        wireframe = _make_wireframe(ids)
        tokens = _make_tokens(ids)

        violations = validate_id_linkage(spatial, wireframe, tokens)

        assert len(violations) == 0, (
            f"len(violations) must be 0 for clean linkage, got {len(violations)}: {violations}"
        )

    def test_empty_artifacts_produce_empty_violations(self) -> None:
        """IV-6 (edge case): Given all artifacts empty (no components), violations is empty."""
        violations = validate_id_linkage(
            _make_spatial([]),
            _make_wireframe([]),
            _make_tokens([]),
        )

        assert len(violations) == 0, (
            f"Empty artifacts should produce 0 violations, got: {violations}"
        )
