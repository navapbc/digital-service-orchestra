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
import hashlib
import json
import logging
import os
import pathlib
import sys
from typing import Any

logger = logging.getLogger(__name__)

_PLUGIN_ROOT = pathlib.Path(
    os.environ.get(
        "CLAUDE_PLUGIN_ROOT", str(pathlib.Path(__file__).resolve().parent.parent.parent)
    )
)
_AGENTS_DIR = _PLUGIN_ROOT / "agents"
# Git-relative path to this module (used in synthetic cited_lines to avoid literal plugin paths).
# Always derived from __file__ itself (5 levels up to repo root), independent of _PLUGIN_ROOT
# so that CLAUDE_PLUGIN_ROOT overrides don't break the computation.
_THIS_FILE_RESOLVED = pathlib.Path(__file__).resolve()
_REPO_ROOT_FROM_FILE = _THIS_FILE_RESOLVED.parent.parent.parent.parent.parent
_THIS_FILE_GIT_REL = str(_THIS_FILE_RESOLVED.relative_to(_REPO_ROOT_FROM_FILE))

# SC4: context-augmentation soft cap (default 15 turns).
# Module-level so tests can patch it without modifying the function signature.
CONTEXT_AUG_SOFT_CAP: int = 15


@functools.lru_cache(maxsize=32)
def _load_agent_prompt(agent_id: str) -> str:
    """Load the canonical agent file body for ``agent_id``.

    Resolves ``<plugin-root>/agents/<agent_id>.md``, strips YAML frontmatter
    (the leading ``---\\n...\\n---\\n`` block), and returns the body. Raises
    RuntimeError when the agent file is missing or empty.
    """
    if not agent_id or agent_id == "unknown":
        raise RuntimeError(
            f'agent_id must not be empty or "unknown"; got: {agent_id!r}'
        )
    agent_file = _AGENTS_DIR / f"{agent_id}.md"
    try:
        text = agent_file.read_text(encoding="utf-8")
    except OSError:
        raise RuntimeError(
            f"Agent file not found: {agent_file}. "
            "Ensure CLAUDE_PLUGIN_ROOT points to the plugin directory containing agents/."
        ) from None
    if text.startswith("---\n"):
        end = text.find("\n---\n", 4)
        if end != -1:
            text = text[end + len("\n---\n") :]
    body = text.strip()
    if not body:
        raise RuntimeError(f"Agent file is empty: {agent_file}")
    return body


_REQUIRED_AGENT_IDS: list[str] = [
    "code-reviewer-light",
    "code-reviewer-standard",
    "code-reviewer-deep-arch",
    "code-reviewer-deep-correctness",
    "code-reviewer-deep-verification",
    "code-reviewer-deep-hygiene",
    "code-reviewer-security-red-team",
    "code-reviewer-security-blue-team",
    "code-reviewer-performance",
    "code-reviewer-test-quality",
]


def _validate_agent_files(required_ids: list[str] | None = None) -> None:
    """Verify all required agent .md files exist. Raises RuntimeError listing all missing files."""
    if required_ids is None:
        required_ids = _REQUIRED_AGENT_IDS
    missing = [
        str(_AGENTS_DIR / f"{agent_id}.md")
        for agent_id in required_ids
        if not (_AGENTS_DIR / f"{agent_id}.md").exists()
    ]
    if missing:
        raise RuntimeError(
            "Missing agent files (check CLAUDE_PLUGIN_ROOT): " + ", ".join(missing)
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


def _build_messages(
    diff_text: str, agent_id: str = "unknown", provider: str = "unknown"
) -> list[dict[str, Any]]:
    system_prompt = _load_agent_prompt(agent_id)
    if provider == "anthropic":
        # SC3: place cache_control breakpoints at system-prompt and diff boundaries
        # derived from the rendered message structure (not hardcoded by index).
        return [
            {
                "role": "system",
                "content": [
                    {
                        "type": "text",
                        "text": system_prompt,
                        "cache_control": {"type": "ephemeral"},
                    }
                ],
            },
            {
                "role": "user",
                "content": [
                    {
                        "type": "text",
                        "text": f"Review this diff:\n\n{diff_text}",
                        "cache_control": {"type": "ephemeral"},
                    }
                ],
            },
        ]
    return [
        {"role": "system", "content": system_prompt},
        {"role": "user", "content": f"Review this diff:\n\n{diff_text}"},
    ]


def _stable_prefix_hash(messages: list[dict[str, Any]]) -> str:
    """Compute a SHA-256 hash of the stable cached prefix (first two messages).

    The first two messages (system prompt + diff) must never change across turns
    within a single dispatch_review call — any drift invalidates the Anthropic
    cache and causes a 5-10× token cost overrun.
    """
    prefix = messages[:2]
    serialized = json.dumps(prefix, sort_keys=True, ensure_ascii=False)
    return hashlib.sha256(serialized.encode("utf-8")).hexdigest()


def _check_cache_usage(
    response: Any,
    turn: int,
    prev_cache_read: int | None,
    provider: str,
) -> int | None:
    """Log warnings when Anthropic prompt-cache tokens are absent.

    Returns the current cache_read_input_tokens value for use on the next turn.
    No-op for non-Anthropic providers.
    """
    if provider != "anthropic":
        return None
    usage = getattr(response, "usage", None)
    if usage is None:
        return None
    creation = getattr(usage, "cache_creation_input_tokens", 0) or 0
    cache_read = getattr(usage, "cache_read_input_tokens", 0) or 0
    if turn == 0 and creation == 0 and cache_read == 0:
        logger.warning(
            "Anthropic cache miss on turn 0: neither cache_creation_input_tokens "
            "nor cache_read_input_tokens > 0 — cache_control breakpoints may be "
            "misplaced or the provider downgraded the request"
        )
    elif turn > 0 and prev_cache_read is not None and cache_read <= prev_cache_read:
        logger.warning(
            "Anthropic cache_read_input_tokens did not increase on turn %d "
            "(prev=%d, current=%d) — stable prefix may have been invalidated",
            turn,
            prev_cache_read,
            cache_read,
        )
    return cache_read


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
    repo_root: str | None = None,
    tier: str = "standard",
    soft_cap: int | None = None,
) -> dict[str, Any]:
    """Dispatch a code review using LiteLLM with manual context-window escalation.

    Uses litellm.completion with:
      - fallbacks=[...]: cross-provider fallback models (Axis 1, SDK-native)
      - Manual loop over context_model_chain catching ContextWindowExceededError (Axis 2)
      - stream=False: DD1 compliance
      - Single-turn context-augmentation loop for non-light tiers (Axis 3)

    Args:
        diff_text: Unified diff text to review.
        provider_chain: Ordered list of provider names to attempt (e.g. ["anthropic", "openai"]).
        environ: Environment variable mapping used for credential checks.
                 Defaults to os.environ when None.
        agent_id: Identifier of the reviewing agent (used in fallback_exhausted entries).
        context_model_chain: Explicit list of models to try on ContextWindowExceededError.
                             When None, uses the default chain for the first provider.
        primary_model: Override the primary model for the first provider call.
        repo_root: Repository root path for the context-augmentation file jail.
                   Defaults to the current working directory when None.
        tier: Review tier — "light" skips context augmentation; all others enable it.
        soft_cap: Per-call soft cap override for context-augmentation turns. When None,
                  falls back to the module-level CONTEXT_AUG_SOFT_CAP constant (patchable
                  in tests). Use this to set per-tier caps at the call site.

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
        environ = dict(os.environ)

    # --- Credential pre-check (DD startup gate) ---
    for provider in provider_chain:
        key_var = _PROVIDER_API_KEY.get(provider)
        if not key_var:
            raise ConfigError(f"Unknown provider: {provider!r}")
        if not environ.get(key_var):
            raise ConfigError(f"Missing {key_var} for provider {provider!r}")

    # Determine the primary provider early — needed for cache_control placement.
    first_provider = provider_chain[0]

    messages = _build_messages(diff_text, agent_id=agent_id, provider=first_provider)
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

    # Resolve repo root for the context-augmentation file jail (Axis 3)
    resolved_repo_root = (
        os.path.realpath(repo_root) if repo_root else os.path.realpath(".")
    )

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

            # Axis 3: multi-turn context-augmentation loop (non-light tiers only, SC4).
            # Light tier: single-shot, no augmentation.
            if tier != "light":
                from dso_ci_review.context_request import (
                    execute_grep,
                    execute_read_files,
                    parse_request_blocks,
                )

                # SC4: per-call soft_cap parameter takes precedence over module constant.
                _AUG_SOFT_CAP = (
                    soft_cap if soft_cap is not None else CONTEXT_AUG_SOFT_CAP
                )
                _AUG_FIRST_NUDGE = (
                    "You have reached the context-augmentation turn limit. "
                    "Please provide your final code review findings now without "
                    "issuing any additional context requests."
                )
                _AUG_SECOND_NUDGE = (
                    "FINAL WARNING: You must provide your final review findings "
                    "immediately. No further context requests will be processed. "
                    "Failure to comply will result in this review being recorded as failed."
                )

                aug_messages = list(messages)
                current_response = response
                aug_turn = 0
                nudge_count = (
                    0  # 0=pre-nudge, 1=after first nudge, 2=after second nudge
                )
                aug_failed = False
                # SC3: track cache tokens across turns for cache-hit assertion.
                _aug_cache_read: int | None = _check_cache_usage(
                    response, 0, None, first_provider
                )

                while aug_turn <= _AUG_SOFT_CAP + 4:
                    assistant_content = (
                        current_response.choices[0].message.content or ""
                    )
                    turn_msgs = [{"role": "assistant", "content": assistant_content}]
                    request_blocks = parse_request_blocks(turn_msgs)

                    # Check if this turn has parseable final findings
                    has_findings = False
                    try:
                        parsed_attempt = _parse_response(current_response)
                        has_findings = bool(parsed_attempt.get("findings") is not None)
                    except (ValueError, KeyError, AttributeError):
                        has_findings = False

                    # No context requests → assistant provided final findings
                    if not request_blocks:
                        response = current_response
                        break

                    # Post-nudge state machine (SC4): when both request AND findings
                    # are present, ignore the request and count as a strike.
                    if nudge_count >= 1 and has_findings:
                        # Request is ignored; treat this turn as final findings.
                        response = current_response
                        break

                    # Soft-cap nudge at turn soft_cap
                    if aug_turn >= _AUG_SOFT_CAP and nudge_count == 0:
                        nudge_count = 1
                        aug_messages = aug_messages + [
                            {"role": "assistant", "content": assistant_content},
                            {"role": "user", "content": _AUG_FIRST_NUDGE},
                        ]
                        current_response = litellm.completion(
                            model=ctx_model,
                            messages=aug_messages,
                            stream=False,
                            fallbacks=fallbacks,
                        )
                        _aug_cache_read = _check_cache_usage(
                            current_response, aug_turn, _aug_cache_read, first_provider
                        )
                        aug_turn += 1
                        continue

                    # Second nudge at soft_cap+3
                    if aug_turn >= _AUG_SOFT_CAP + 3 and nudge_count == 1:
                        nudge_count = 2
                        aug_messages = aug_messages + [
                            {"role": "assistant", "content": assistant_content},
                            {"role": "user", "content": _AUG_SECOND_NUDGE},
                        ]
                        current_response = litellm.completion(
                            model=ctx_model,
                            messages=aug_messages,
                            stream=False,
                            fallbacks=fallbacks,
                        )
                        _aug_cache_read = _check_cache_usage(
                            current_response, aug_turn, _aug_cache_read, first_provider
                        )
                        aug_turn += 1
                        continue

                    # Fail-closed: reviewer ignored both nudges
                    if aug_turn >= _AUG_SOFT_CAP + 4 and nudge_count >= 2:
                        aug_failed = True
                        break

                    # Normal turn: execute context requests and re-complete
                    augmentation_parts: list[str] = []
                    for req in request_blocks:
                        action = req.get("action")
                        if action == "read_files":
                            paths = req.get("paths", [])
                            file_content = execute_read_files(
                                paths=paths,
                                repo_root=resolved_repo_root,
                            )
                            augmentation_parts.append(file_content)
                        elif action == "grep":
                            grep_result = execute_grep(
                                request=req,
                                repo_root=resolved_repo_root,
                            )
                            grep_output = grep_result.get("output") or grep_result.get(
                                "error", ""
                            )
                            if grep_output:
                                augmentation_parts.append(
                                    f"Grep results:\n\n{grep_output}"
                                )

                    if augmentation_parts:
                        augmented_user_content = (
                            "File contents requested:\n\n"
                            + "\n\n".join(augmentation_parts)
                        )
                        aug_messages = aug_messages + [
                            {"role": "assistant", "content": assistant_content},
                            {"role": "user", "content": augmented_user_content},
                        ]
                        current_response = litellm.completion(
                            model=ctx_model,
                            messages=aug_messages,
                            stream=False,
                            fallbacks=fallbacks,
                        )
                        _aug_cache_read = _check_cache_usage(
                            current_response, aug_turn, _aug_cache_read, first_provider
                        )
                    else:
                        # Requests were all unknown actions; treat as done
                        response = current_response
                        break

                    aug_turn += 1

                if aug_failed:
                    # Fail-closed: record as failed (SC4)
                    failed_result: dict[str, Any] = {
                        "findings": [
                            {
                                "severity": "critical",
                                "description": (
                                    "Context-augmentation loop failed-closed: reviewer "
                                    f"continued emitting context requests past turn "
                                    f"{_AUG_SOFT_CAP + 3} without providing final findings."
                                ),
                                "cited_lines": [f"{_THIS_FILE_GIT_REL}:418"],
                            }
                        ],
                        "augmentation_failed": True,
                    }
                    if fallback_hops:
                        failed_result["fallback_hops"] = fallback_hops
                    return failed_result

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


def dispatch_two_call_review(
    diff_text: str,
    prior_findings_index: list[dict[str, Any]],
    prior_findings: list[dict[str, Any]],
    defenses: list[dict[str, Any]],
    provider_chain: list[str],
    environ: dict[str, str] | None = None,
    agent_id: str = "unknown",
    primary_model: str | None = None,
) -> dict[str, Any]:
    """Two-call review architecture for re-review cycles (DSO_REVIEW_CYCLE >= 2).

    Call 1 receives the stripped prior_findings_index (id, cited_lines, dimension only —
    no defense_text) so the reviewer evaluates findings independently without seeing
    existing defenses.

    Call 2 receives Call 1's output plus the full prior_findings (with defense_text)
    and defenses so the reviewer can weigh new findings against existing defenses.

    Args:
        diff_text: Unified diff text to review.
        prior_findings_index: Stripped prior findings — id, cited_lines, dimension only.
                              Must NOT contain defense_text.
        prior_findings: Full prior findings including defense_text.
        defenses: Full defense records for prior findings.
        provider_chain: Ordered list of provider names.
        environ: Environment variable mapping for credential checks. When None, uses
                 os.environ. Applied via os.environ before each dispatch_review call
                 and cleaned up after.
        agent_id: Identifier of the reviewing agent.
        primary_model: Override the primary model for the first provider call.

    Returns:
        The Call 2 result dict — a dict with a "findings" key.
    """
    import litellm  # noqa: PLC0415 — deferred import; test patches dso_ci_review.dispatch.litellm

    from dso_ci_review.providers.config import ConfigError

    _environ = dict(environ) if environ else dict(os.environ)

    # Credential pre-check
    first_provider = provider_chain[0]
    key_var = _PROVIDER_API_KEY.get(first_provider)
    if not key_var:
        raise ConfigError(f"Unknown provider: {first_provider!r}")
    if not _environ.get(key_var):
        raise ConfigError(f"Missing {key_var} for provider {first_provider!r}")

    resolved_model = primary_model or _PROVIDER_DEFAULT_MODEL.get(
        first_provider, first_provider
    )
    fallbacks = _build_fallbacks(provider_chain, first_provider)

    # Resolve litellm via module attribute so tests patching
    # ``dso_ci_review.dispatch.litellm`` intercept these calls.
    import dso_ci_review.dispatch as _self_mod  # noqa: PLC0415
    _litellm = getattr(_self_mod, "litellm", litellm)

    # --- Call 1: pass only the stripped index (no defense_text) ---
    index_context = (
        "\n\n## Prior review findings index (no defenses — evaluate independently)\n\n"
        + json.dumps(prior_findings_index, indent=2)
    )
    call1_diff = diff_text + index_context
    call1_messages = _build_messages(call1_diff, agent_id=agent_id, provider=first_provider)

    call1_response = _litellm.completion(
        model=resolved_model,
        messages=call1_messages,
        stream=False,
        fallbacks=fallbacks,
    )
    call1_result = _parse_response(call1_response)

    # --- Call 2: pass Call 1 output + full prior_findings + defenses ---
    call2_context = (
        "\n\n## Call 1 findings\n\n"
        + json.dumps(call1_result, indent=2)
        + "\n\n## Prior findings (with defenses)\n\n"
        + json.dumps(prior_findings, indent=2)
        + "\n\n## Defenses\n\n"
        + json.dumps(defenses, indent=2)
    )
    call2_diff = diff_text + call2_context
    call2_messages = _build_messages(call2_diff, agent_id=agent_id, provider=first_provider)

    call2_response = _litellm.completion(
        model=resolved_model,
        messages=call2_messages,
        stream=False,
        fallbacks=fallbacks,
    )
    call2_result = _parse_response(call2_response)

    return call2_result


async def _call_single_agent(
    agent_id: str,
    diff_text: str,
    model: str,
    provider_chain: list[str] | None = None,
    tier: str = "standard",
) -> dict:
    """Dispatch one reviewer agent. Returns findings dict or error entry on any exception."""
    try:
        result = dispatch_review(
            diff_text=diff_text,
            agent_id=agent_id,
            primary_model=model,
            provider_chain=provider_chain or ["anthropic"],
            tier=tier,
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


def dispatch_arch_synthesis(
    merged_findings_json: str,
    diff_text: str,
    model: str,
    provider_chain: list[str],
) -> dict:
    """Approximate opus arch synthesis: sequential call after 3 parallel specialists."""
    augmented_input = f"{diff_text}\n\n## Prior specialist findings\n\n{merged_findings_json}"
    return dispatch_review(
        diff_text=augmented_input,
        agent_id="code-reviewer-deep-arch",
        primary_model=model,
        provider_chain=provider_chain,
        tier="deep",
    )


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
            - tier (str | None): Review tier — propagated to dispatch_review so
              light tier skips the augmentation loop.
    """
    if not agents:
        return []

    tasks = [
        _call_single_agent(
            agent_id=a["agent_id"],
            diff_text=a["diff_text"],
            model=a["model"],
            provider_chain=a.get("provider_chain"),
            tier=a.get("tier", "standard"),
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
