"""Anthropic provider adapter for dso_ci_review.

Wraps litellm.completion to call Claude models and parse
structured review findings from the response.
"""

from __future__ import annotations

import json
import logging
from typing import Any

logger = logging.getLogger(__name__)

_DEFAULT_MODEL = "claude-haiku-4-5-20251001"
_SYSTEM_PROMPT = (
    "You are a code reviewer. Analyze the provided diff and return a JSON object "
    'with a single key "findings" whose value is a list of finding objects. '
    "Each finding object must have: severity (string), description (string), "
    "cited_lines (list of strings in 'path:lineno' format). "
    "Return ONLY the JSON object, no markdown fences."
)


class AnthropicProvider:
    """Provider adapter that calls Anthropic models via LiteLLM."""

    def __init__(self, model: str = _DEFAULT_MODEL) -> None:
        self._model = model

    def review_diff(self, diff_text: str, **kwargs: Any) -> dict[str, Any]:
        """Send *diff_text* to the Anthropic model via LiteLLM and return parsed findings.

        Args:
            diff_text: The unified diff to review.
            **kwargs: Optional overrides; ``model`` overrides the instance default.

        Returns:
            A dict with a ``"findings"`` key containing a list of finding dicts.

        Raises:
            ValueError: When the LLM returns a response that cannot be parsed as findings JSON.
        """
        model = kwargs.get("model", self._model)
        return review_diff(diff_text, model=model)


def review_diff(diff_text: str, model: str = _DEFAULT_MODEL) -> dict[str, Any]:
    """Send *diff_text* to the Anthropic model via LiteLLM and return parsed findings.

    Args:
        diff_text: The unified diff to review.
        model: LiteLLM model identifier (default: claude-haiku-4-5-20251001).

    Returns:
        A dict with a ``"findings"`` key containing a list of finding dicts.

    Raises:
        ValueError: When the LLM returns a response that cannot be parsed as findings JSON.
    """
    import litellm  # deferred so the module is importable without litellm installed

    messages = [
        {"role": "system", "content": _SYSTEM_PROMPT},
        {"role": "user", "content": f"Review this diff:\n\n{diff_text}"},
    ]

    response = litellm.completion(
        model=model,
        messages=messages,
    )

    raw_content: str = response.choices[0].message.content or ""
    try:
        return json.loads(raw_content)
    except (json.JSONDecodeError, TypeError):
        raise ValueError(
            f"LLM returned non-JSON response (length={len(raw_content)}); "
            "cannot parse as findings. Treat as review failure."
        )
