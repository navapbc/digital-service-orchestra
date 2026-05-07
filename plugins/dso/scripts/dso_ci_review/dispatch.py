"""dso_ci_review.dispatch — Fallback-aware LLM dispatch for CI code review.

Implements a two-axis fallback strategy:
  - Axis 1 (Cross-provider fallback): passed as fallbacks=[...] to litellm.completion
  - Axis 2 (Context-window escalation): manual loop catching ContextWindowExceededError

DD1: stream=False on all litellm.completion() calls; fallbacks= passed for cross-provider
DD2: fallback_hops rendered in result when a hop occurred
DD3: fallback_exhausted entry (6 required fields) written when chain fully exhausted
DD4: async_dispatch_specialists uses asyncio.gather(return_exceptions=True) for partial-failure
"""

from __future__ import annotations

import asyncio
import functools
import json
import logging
import pathlib
import sys
from typing import Any

logger = logging.getLogger(__name__)

_SYSTEM_PROMPT = (
    "You are a code reviewer. Analyze the provided diff and return a JSON object "
    'with a single key "findings" whose value is a list of finding objects. '
    'Each finding object must have: severity (one of: "critical", "important", '
    '"minor", "fragile"), description (string), '
    "cited_lines (list of strings in 'path:lineno' format). "
    "Return ONLY the JSON object, no markdown fences, no explanatory text."
)

_PLUGIN_ROOT = pathlib.Path(__file__).resolve().parent.parent.parent
_AGENTS_DIR = _PLUGIN_ROOT / "agents"


@functools.lru_cache(maxsize=32)
def _load_agent_prompt(agent_id: str) -> str:
    """Load the canonical agent file body for ``agent_id``.

    Resolves ``<plugin-root>/agents/<agent_id>.md``, strips YAML frontmatter
    (the leading ``---\\n...\\n---\\n`` block), and returns the body. Falls
    back to the inline ``_SYSTEM_PROMPT`` constant when the agent file is
    missing or empty so dispatch remains functional on agent_id typos.
    """
    if not agent_id or agent_id == "unknown":
        return _SYSTEM_PROMPT
    agent_file = _AGENTS_DIR / f"{agent_id}.md"
    try:
        text = agent_file.read_text(encoding="utf-8")
    except OSError:
        return _SYSTEM_PROMPT
    if text.startswith("---\n"):
        end = text.find("\n---\n", 4)
        if end != -1:
            text = text[end + len("\n---\n") :]
    body = text.strip()
    return body or _SYSTEM_PROMPT


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


def _build_messages(diff_text: str, agent_id: str = "unknown") -> list[dict[str, str]]:
    system_prompt = _load_agent_prompt(agent_id)
    return [
        {"role": "system", "content": system_prompt},
        {"role": "user", "content": f"Review this diff:\n\n{diff_text}"},
    ]


def _parse_response(response: Any) -> dict[str, Any]:
    from dso_ci_review.findings import _extract_json_from_text

    raw_content: str = response.choices[0].message.content or ""
    # Fast path: clean JSON response (well-behaved models)
    try:
        return json.loads(raw_content)
    except (json.JSONDecodeError, TypeError):
        pass
    # Fallback: robust extractor handles prose-wrapped and markdown-fenced JSON
    extracted = _extract_json_from_text(raw_content)
    if extracted is not None:
        return extracted
    # Total parse failure — emit to stderr so CI logs surface the issue immediately
    msg = (
        f"LLM returned non-JSON response (length={len(raw_content)}); "
        "cannot parse as findings."
    )
    print(f"ERROR: {msg}", file=sys.stderr)
    raise ValueError(msg)


def _build_fallbacks(
    provider_chain: list[str],
    primary_provider: str,
) -> list[dict[str, str]]:
    """Build cross-provider fallbacks list for litellm.completion fallbacks= parameter.

    Returns a list of model dicts for each non-primary provider in the chain.
    """
    fallbacks = []
    for provider in provider_chain:
        if provider != primary_provider:
            fallback_model = _PROVIDER_DEFAULT_MODEL.get(provider, provider)
            fallbacks.append({"model": fallback_model})
    return fallbacks


def dispatch_review(
    diff_text: str,
    provider_chain: list[str],
    environ: dict[str, str] | None = None,
    agent_id: str = "unknown",
    context_model_chain: list[str] | None = None,
    primary_model: str | None = None,
) -> dict[str, Any]:
    """Dispatch a code review using LiteLLM with manual context-window escalation.

    Uses litellm.completion with:
      - fallbacks=[...]: cross-provider fallback models (Axis 1, SDK-native)
      - Manual loop over context_model_chain catching ContextWindowExceededError (Axis 2)
      - stream=False: DD1 compliance

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
            raise ConfigError(f"Missing {key_var} for provider {provider!r}")

    messages = _build_messages(diff_text, agent_id=agent_id)

    # Determine the primary provider and model
    first_provider = provider_chain[0]
    resolved_primary_model = primary_model or _PROVIDER_DEFAULT_MODEL.get(
        first_provider, first_provider
    )

    # Build context_model_chain if not provided.
    # When context_model_chain is None, use the default chain for the first provider.
    # If first_provider is unknown (not in _DEFAULT_CONTEXT_CHAIN), fall back to a
    # single-element chain containing only the resolved primary model.
    if context_model_chain is None:
        context_model_chain = _DEFAULT_CONTEXT_CHAIN.get(
            first_provider, [resolved_primary_model]
        )

    # Build SDK-native cross-provider fallback parameter list (Axis 1, DD1)
    fallbacks = _build_fallbacks(provider_chain, first_provider)

    # Track attempted models/providers for fallback_exhausted reporting
    attempted_cross_provider: list[str] = [first_provider]
    attempted_context_models: list[str] = list(context_model_chain)
    last_exc: Exception | None = None
    fallback_hops: list[str] = []

    # Axis 2: manual context-window escalation loop.
    # NOTE: the `context_window_fallbacks` kwarg is a LiteLLM Router parameter
    # and is silently ignored by litellm.completion() — use a manual loop instead.
    for ctx_model in context_model_chain:
        try:
            response = litellm.completion(
                model=ctx_model,
                messages=messages,
                stream=False,  # DD1: never stream
                fallbacks=fallbacks,  # DD1: SDK-native cross-provider fallback (Axis 1)
            )
            result = _parse_response(response)

            # Record a hop if we advanced past the first model in the context chain (DD2).
            # Note: SDK-native cross-provider hops (via fallbacks= parameter) are also
            # detected here via response._hidden_params["model"] when litellm transparently
            # uses a fallback provider.
            actual_model = (
                getattr(response, "_hidden_params", {}).get("model") or ctx_model
            )
            effective_primary = resolved_primary_model
            if ctx_model != effective_primary or actual_model != effective_primary:
                hop_target = actual_model if actual_model != ctx_model else ctx_model
                hop_desc = (
                    f"[fallback: {agent_id} {effective_primary} -> {hop_target} "
                    f"({'sdk_cross_provider' if actual_model != ctx_model else 'context_window_escalation'})]"
                )
                fallback_hops.append(hop_desc)

            if fallback_hops:
                result["fallback_hops"] = fallback_hops

            return result

        except litellm.ContextWindowExceededError as exc:
            # Context too large for this model — try the next larger context model
            last_exc = exc
            logger.debug(
                "ContextWindowExceededError for model %s; escalating context chain",
                ctx_model,
            )
            continue

        except Exception as exc:  # noqa: BLE001
            # Non-context error (rate limit, auth, etc.) — break out; cross-provider
            # fallbacks= will have already been attempted by the SDK within this call.
            last_exc = exc
            # Populate attempted_cross_provider with all providers in the chain
            for provider in provider_chain[1:]:
                attempted_cross_provider.append(provider)
            logger.debug(
                "Non-context error for model %s (provider chain exhausted): %s",
                ctx_model,
                exc,
            )
            break

    # All context models (and their cross-provider fallbacks) exhausted — emit DD3 entry
    exhausted_entry: dict[str, Any] = {
        "type": "fallback_exhausted",
        "agent_id": agent_id,
        "primary_model": resolved_primary_model,
        "attempted_cross_provider": list(attempted_cross_provider),
        "attempted_context_models": list(attempted_context_models),
        "final_exception_class": type(last_exc).__name__
        if last_exc
        else "UnknownError",
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


# ---------------------------------------------------------------------------
# Async parallel specialist dispatch (DD4)
# ---------------------------------------------------------------------------


async def _call_single_agent(
    agent_id: str,
    diff_text: str,
    model: str,
    provider_chain: list[str] | None = None,
) -> dict:
    """Dispatch one reviewer agent. Returns findings dict or error entry on any exception."""
    try:
        result = dispatch_review(
            diff_text=diff_text,
            agent_id=agent_id,
            primary_model=model,
            provider_chain=provider_chain or ["anthropic"],
        )
        return result
    except Exception as exc:  # noqa: BLE001
        return {
            "findings": [
                {
                    "type": "specialist_error",
                    "agent_id": agent_id,
                    "severity": "important",
                    "category": "correctness",
                    "description": f"Specialist {agent_id} failed: {type(exc).__name__}: {exc}",
                    "cited_lines": [],
                }
            ]
        }


async def async_dispatch_specialists(
    agents: list[dict],
) -> list[dict]:
    """Dispatch all specialist agents concurrently via asyncio.gather.

    Uses return_exceptions=True so one failure does not cancel sibling tasks.
    Any task that raises an exception produces an error findings entry.
    Returns list of findings dicts (one per agent, in same order as input).
    Never raises — all errors are captured into error entries.

    Args:
        agents: List of agent descriptor dicts, each containing:
            - agent_id (str): Identifier for the reviewing agent.
            - diff_text (str): Unified diff text to review.
            - model (str): Primary model identifier to use.
            - provider_chain (list[str] | None): Optional provider chain override.
    """
    if not agents:
        return []

    tasks = [
        _call_single_agent(
            agent_id=a["agent_id"],
            diff_text=a["diff_text"],
            model=a["model"],
            provider_chain=a.get("provider_chain"),
        )
        for a in agents
    ]
    results = await asyncio.gather(*tasks, return_exceptions=True)

    findings_list = []
    for i, result in enumerate(results):
        if isinstance(result, Exception):
            findings_list.append(
                {
                    "findings": [
                        {
                            "type": "specialist_error",
                            "agent_id": agents[i]["agent_id"],
                            "severity": "important",
                            "category": "correctness",
                            "description": str(result),
                            "cited_lines": [],
                        }
                    ]
                }
            )
        else:
            findings_list.append(result)
    return findings_list
