"""Deterministic mock provider for dso_ci_review tests."""

from __future__ import annotations

from typing import Any


class MockProvider:
    """Deterministic mock provider for testing. Returns canned empty findings."""

    def review_diff(self, diff_text: str, **kwargs: Any) -> dict[str, Any]:
        """Return canned empty findings without calling any LLM.

        Args:
            diff_text: The unified diff to review (ignored by this mock).
            **kwargs: Ignored; accepted for interface compatibility.

        Returns:
            A dict with ``"findings"`` (empty list) and ``"mock"`` (True).
        """
        return {"findings": [], "mock": True}
