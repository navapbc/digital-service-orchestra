"""dso_ci_review.dispatch — Fallback-aware LLM dispatch for CI code review.

Implements a two-axis fallback strategy:
  - Cross-provider fallback: try each provider in provider_chain in order
  - Context-window fallback: when ContextWindowExceededError fires, escalate
    to a larger model within the same provider

DD1: streaming=False preserved (stream=False passed to every litellm.completion call)
DD2: fallback_hops rendered in result when a hop occurred
DD3: fallback_exhausted entry (6 required fields) written when chain fully exhausted
"""

from __future__ import annotations

import json
import logging
from typing import Any

logger = logging.getLogger(__name__)

_SYSTEM_PROMPT = (
    "You are a code reviewer. Analyze the provided diff and return a JSON object "
    'with a single key "findings" whose value is a list of finding objects. '
    "Each finding object must have: severity (string), description (string), "
    "cited_lines (list of strings in 'path:lineno' format). "
    "Return ONLY the JSON object, no markdown fences."
)

# Default per-provider model identifiers (primary → context escalation chain)
_DEFAULT_CONTEXT_CHAIN: dict[str, list[str]] = {
    "anthropic": [
        "claude-haiku-4-5-20251001",
        "claude-sonnet-4-5",
        "claude-opus-4-5",
    ],
    "openai": [
        "openai/gpt-4o-mini",
        "openai/gpt-4o",
    ],
}

# Map provider name → required API key environment variable
_PROVIDER_API_KEY: dict[str, str] = {
    "anthropic": "ANTHROPIC_API_KEY",
    "openai": "OPENAI_API_KEY",
}

# Map provider name → default primary model
_PROVIDER_DEFAULT_MODEL: dict[str, str] = {
    "anthropic": "claude-haiku-4-5-20251001",
    "openai": "openai/gpt-4o-mini",
}


def _build_messages(diff_text: str) -> list[dict[str, str]]:
    return [
        {"role": "system", "content": _SYSTEM_PROMPT},
        {"role": "user", "content": f"Review this diff:\n\n{diff_text}"},
    ]


def _parse_response(response: Any) -> dict[str, Any]:
    raw_content: str = response.choices[0].message.content or ""
    try:
        return json.loads(raw_content)
    except (json.JSONDecodeError, TypeError) as exc:
        raise ValueError(
            f"LLM returned non-JSON response (length={len(raw_content)}); "
            "cannot parse as findings."
        ) from exc


def dispatch_review(
    diff_text: str,
    provider_chain: list[str],
    environ: dict[str, str] | None = None,
    agent_id: str = "unknown",
    context_model_chain: list[str] | None = None,
    primary_model: str | None = None,
) -> dict[str, Any]:
    """Dispatch a code review with a two-axis fallback strategy.

    Axis 1 — cross-provider: iterate over provider_chain, trying each provider
    in order when the previous one raises a non-context error.

    Axis 2 — context-window: when ContextWindowExceededError fires, escalate
    through context_model_chain (larger models, same provider) before moving
    to the next provider.

    Args:
        diff_text: Unified diff text to review.
        provider_chain: Ordered list of provider names to attempt (e.g. ["anthropic", "openai"]).
        environ: Environment variable mapping used for credential checks.
                 Defaults to os.environ when None.
        agent_id: Identifier of the reviewing agent (used in fallback_exhausted entries).
        context_model_chain: Explicit list of models to try on ContextWindowExceededError.
                             When None, uses the default chain for the first provider.
        primary_model: Override the primary model for the first provider call.

    Returns:
        A dict containing "findings" (list). When a fallback hop occurred,
        also contains "fallback_hops" (list of hop descriptor strings).
        On full chain exhaustion, findings contains a single fallback_exhausted entry.

    Raises:
        ConfigError: When a required API key is missing from environ.
    """
    import litellm

    from dso_ci_review.providers.config import ConfigError

    if environ is None:
        import os
        environ = dict(os.environ)

    # --- Credential pre-check (DD startup gate) ---
    for provider in provider_chain:
        key_var = _PROVIDER_API_KEY.get(provider)
        if not key_var:
            raise ConfigError(f"Unknown provider: {provider!r}")
        if not environ.get(key_var):
            raise ConfigError(
                f"Missing {key_var} for provider {provider!r}"
            )

    messages = _build_messages(diff_text)

    # Determine the primary provider and model
    first_provider = provider_chain[0]
    resolved_primary_model = (
        primary_model
        or _PROVIDER_DEFAULT_MODEL.get(first_provider, first_provider)
    )

    # Build context_model_chain if not provided.
    # When context_model_chain is None, use the default chain for the first provider.
    # If first_provider is unknown (not in _DEFAULT_CONTEXT_CHAIN), fall back to a
    # single-element chain containing only the resolved primary model.
    if context_model_chain is None:
        context_model_chain = _DEFAULT_CONTEXT_CHAIN.get(first_provider, [resolved_primary_model])

    # Ensure the primary model is first in the context chain (or use the chain as given)
    # The caller may supply an explicit chain starting from haiku already.

    fallback_hops: list[str] = []
    attempted_cross_provider: list[str] = []
    attempted_context_models: list[str] = []
    last_exc: Exception | None = None

    # Axis 2 first: try context_model_chain for the first provider
    for ctx_model in context_model_chain:
        attempted_context_models.append(ctx_model)
        try:
            response = litellm.completion(
                model=ctx_model,
                messages=messages,
                stream=False,  # DD1: never stream
            )
            result = _parse_response(response)

            # Record a hop before building the result so fallback_hops is complete
            # when we return (non-first model means at least one context escalation occurred).
            if ctx_model != context_model_chain[0]:
                hop_desc = (
                    f"[fallback: {agent_id} {context_model_chain[0]} -> {ctx_model} "
                    f"(ContextWindowExceededError)]"
                )
                fallback_hops.append(hop_desc)
                result["fallback_hops"] = fallback_hops
            return result

        except litellm.ContextWindowExceededError as exc:
            # Context too large; move to the next model in the context chain
            last_exc = exc
            logger.debug(
                "ContextWindowExceededError on %s, escalating context chain", ctx_model
            )
            continue

        except (litellm.RateLimitError, Exception) as exc:
            # Non-context error on the primary provider; break to cross-provider fallback
            last_exc = exc
            attempted_cross_provider.append(first_provider)
            break

    # Axis 1: cross-provider fallback — try remaining providers
    for provider in provider_chain[1:]:
        attempted_cross_provider.append(provider)
        fallback_model = _PROVIDER_DEFAULT_MODEL.get(provider, provider)

        try:
            response = litellm.completion(
                model=fallback_model,
                messages=messages,
                stream=False,  # DD1: never stream
            )
            result = _parse_response(response)

            # Record the cross-provider hop (DD2)
            exc_type = type(last_exc).__name__ if last_exc else "UnknownError"
            hop_desc = (
                f"[fallback: {agent_id} {resolved_primary_model} -> {fallback_model} "
                f"({exc_type})]"
            )
            fallback_hops.append(hop_desc)
            result["fallback_hops"] = fallback_hops
            return result

        except Exception as exc:  # noqa: BLE001
            # Intentionally broad: auth failures, rate limits, and network errors all
            # trigger the exhaustion path (fail-closed). We do not special-case auth
            # failures here; if credentials were invalid, the pre-check gate above
            # would have already raised ConfigError.
            last_exc = exc
            logger.debug(
                "Provider %s also failed: %s", provider, exc
            )
            continue

    # All providers exhausted — emit fallback_exhausted entry (DD3)
    exhausted_entry: dict[str, Any] = {
        "type": "fallback_exhausted",
        "agent_id": agent_id,
        "primary_model": resolved_primary_model,
        "attempted_cross_provider": list(attempted_cross_provider),
        "attempted_context_models": list(attempted_context_models),
        "final_exception_class": type(last_exc).__name__ if last_exc else "UnknownError",
        "final_exception_message": str(last_exc) if last_exc else "",
    }

    logger.warning(
        "Fallback chain exhausted for agent %s (primary=%s): %s",
        agent_id,
        resolved_primary_model,
        exhausted_entry["final_exception_message"],
    )

    return {"findings": [exhausted_entry]}


# ---------------------------------------------------------------------------
# Legacy alias from task description (review_with_fallbacks)
# ---------------------------------------------------------------------------

def review_with_fallbacks(
    diff_text: str,
    agent_id: str,
    primary_model: str,
    provider_chain: list[str],
    config_path: str | None = None,
) -> dict:
    """Thin wrapper around dispatch_review matching the task description interface.

    Maps positional arguments to dispatch_review's keyword interface.
    provider_chain is assumed to be provider names (e.g. ["anthropic", "openai"]).
    """
    return dispatch_review(
        diff_text=diff_text,
        provider_chain=provider_chain,
        agent_id=agent_id,
        primary_model=primary_model,
    )
