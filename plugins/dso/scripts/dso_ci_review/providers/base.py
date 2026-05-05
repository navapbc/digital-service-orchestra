"""Provider Protocol for dso_ci_review LLM adapters.

All provider implementations must satisfy this Protocol, enabling
structural subtyping (duck typing) without inheritance.
"""

from __future__ import annotations

from typing import Any, Protocol, runtime_checkable


@runtime_checkable
class Provider(Protocol):
    """Structural interface for LLM review provider adapters.

    Any class with a ``review_diff`` method matching this signature
    satisfies the Protocol without explicit inheritance.
    """

    def review_diff(self, diff_text: str, **kwargs: Any) -> dict[str, Any]:
        """Submit *diff_text* for review and return structured findings.

        Args:
            diff_text: The unified diff to review.
            **kwargs: Provider-specific options (e.g. ``model``).

        Returns:
            A dict with at minimum a ``"findings"`` key whose value is a list
            of finding dicts, each containing ``severity``, ``description``,
            and ``cited_lines``.
        """
        ...  # Protocol stub — no implementation required
