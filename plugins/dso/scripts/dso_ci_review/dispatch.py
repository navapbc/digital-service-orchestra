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
import fcntl
import functools
import hashlib
import json
import logging
import os
import pathlib
import re
import sys
import threading
import time
from datetime import datetime, timezone
from typing import Any

from dso_ci_review.dispatch_ratelimit import (
    DispatchContext,
    calculate_backoff,
    extract_anthropic_ratelimit_headers,
    parse_retry_after,
    should_retry,
)

logger = logging.getLogger(__name__)

_PLUGIN_ROOT = pathlib.Path(
    os.environ.get(
        "CLAUDE_PLUGIN_ROOT", str(pathlib.Path(__file__).resolve().parent.parent.parent)
    )
)
# CI dispatch uses the CI-variant agent prompts at agents/ci/. The orchestrator
# variant at agents/ is preserved for Claude Code Agent-tool dispatch; the two
# are generated from the same source (reviewer-base.md) via build-review-agents.sh
# (DISPATCH_VARIANT env var). See bug 4a30-2937-b404-4a8e.
_AGENTS_DIR = _PLUGIN_ROOT / "agents" / "ci"
# Git-relative path to this module (used in synthetic cited_lines to avoid literal plugin paths).
# Always derived from __file__ itself (5 levels up to repo root), independent of _PLUGIN_ROOT
# so that CLAUDE_PLUGIN_ROOT overrides don't break the computation.
_THIS_FILE_RESOLVED = pathlib.Path(__file__).resolve()
_REPO_ROOT_FROM_FILE = _THIS_FILE_RESOLVED.parent.parent.parent.parent.parent
_THIS_FILE_GIT_REL = str(_THIS_FILE_RESOLVED.relative_to(_REPO_ROOT_FROM_FILE))

# SC4: context-augmentation soft cap (default 15 turns).
# Module-level so tests can patch it without modifying the function signature.
CONTEXT_AUG_SOFT_CAP: int = 15
# Number of additional turns after soft_cap before the second nudge fires.
_NUDGE_SECOND_OFFSET: int = 3
# Number of additional turns after soft_cap before fail-closed triggers.
_FAIL_CLOSED_OFFSET: int = 4

# Canonical set of valid severity values for review findings.
# "fallback_exhausted" is a sentinel written by dispatch_review() when the full
# provider chain is exhausted; it is NOT a reviewer-assigned severity but is
# returned in the findings list and must be tolerated by callers.
_VALID_SEVERITIES: frozenset[str] = frozenset(
    {"critical", "important", "minor", "fragile", "fallback_exhausted"}
)

# Canonical 5-value enum for finding `category`. MUST stay in sync with
# valid_categories in validate-review-output.sh (currently sha256
# cb48a66fc3292083). Used by the scoped exception in the frozen-field loop
# below to allow correction iff the original category is off-enum.
_VALID_CATEGORIES: frozenset[str] = frozenset(
    {"correctness", "design", "hygiene", "maintainability", "verification"}
)

# Frozen fields that must be preserved byte-for-byte during schema correction.
# finding_id is handled separately below — it may be regenerated when the original
# is absent, empty, or structurally malformed (not matching _FINDING_ID_RE).
#
# `category` exception (bug 0623-54f4-d31b-4623): category is treated as
# conditionally frozen — when the original `category` is OFF the canonical
# 5-value enum, correction MAY re-map it to a canonical bucket (otherwise
# schema-correction is structurally incapable of repairing the very class of
# violation the validator rejects, since validate-review-output.sh hard-rejects
# any non-canonical category). When the original category IS canonical, the
# frozen-field invariant remains in force — see the scoped check inside the
# correction loop at the `field == "category"` branch.
_FROZEN_FIELDS: tuple[str, ...] = (
    "severity",
    "category",
    "description",
    "file",
    "cited_lines",
)

# finding_id format: f-<8 lowercase hex characters>
_FINDING_ID_RE: re.Pattern[str] = re.compile(r"^f-[0-9a-f]{8}$")

# cited_lines entry format: <path>:<line> or ~<path>:<line> (approximate).
# <line> may be a single line number or a range (e.g. 83-112 or 83~112).
# The optional ~ prefix on the whole entry marks approximate line references.
_CITED_LINE_RE: re.Pattern[str] = re.compile(
    r"^~?[^:]+:[1-9][0-9]*(?:[-~][1-9][0-9]*)?$"
)


# ---------------------------------------------------------------------------
# Usage capture — review-cycle-usage.json
# ---------------------------------------------------------------------------

# Thread-local call-index counter so concurrent dispatch_review invocations
# (via asyncio.gather) each get their own monotone sequence.
_usage_call_counter = threading.local()

_USAGE_SCHEMA_VERSION = "1.0.0"
_USAGE_FILE_NAME = "review-cycle-usage.json"
_USAGE_LOCK_FILE_NAME = ".review-cycle-usage.lock"

# Bounded non-blocking lock acquisition for _write_usage_entry. The outer
# try/except in the function cannot rescue a hung blocking flock — adding a
# retry budget ensures the function fails open instead of stalling the
# review dispatch when a prior holder dies without releasing the lock.
_USAGE_LOCK_MAX_RETRIES = 20
_USAGE_LOCK_RETRY_DELAY_SEC = 0.05


def _locked_append_usage_record(entry: dict[str, object]) -> None:
    """Append ``entry`` to ``${ARTIFACTS_DIR}/review-cycle-usage.json`` under
    fcntl.LOCK_EX with bounded non-blocking retry, then atomic temp+rename.

    Shared by ``_write_usage_entry`` (per-call usage) and
    ``_write_cooldown_event`` (cross-cluster cooldown engagement). Both
    callers use the same lock file so writers serialize across paths.

    Fail-open: any exception is swallowed so observability writes never
    interrupt review dispatch. Dead lock-holders are bounded by
    ``_USAGE_LOCK_MAX_RETRIES * _USAGE_LOCK_RETRY_DELAY_SEC`` total wait,
    after which the function returns without writing.

    SYNCHRONOUS — this function calls ``time.sleep`` in its retry loop and
    MUST be invoked from a worker thread (via ``asyncio.to_thread``) when
    called from an async context. ``_write_usage_entry`` is already invoked
    only from synchronous ``dispatch_review`` (which itself runs inside
    ``asyncio.to_thread``); ``_write_cooldown_event`` callers must wrap
    explicitly.
    """
    try:
        from dso_ci_review.cycle_ledger import _resolve_artifacts_dir  # noqa: PLC0415

        artifacts_dir = _resolve_artifacts_dir()
        usage_path = os.path.join(artifacts_dir, _USAGE_FILE_NAME)
        lock_path = os.path.join(artifacts_dir, _USAGE_LOCK_FILE_NAME)

        lock_fd = open(lock_path, "w")  # noqa: WPS515
        try:
            for _attempt in range(_USAGE_LOCK_MAX_RETRIES):
                try:
                    fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    break
                except (BlockingIOError, OSError):
                    if _attempt + 1 >= _USAGE_LOCK_MAX_RETRIES:
                        raise
                    time.sleep(_USAGE_LOCK_RETRY_DELAY_SEC)
            if os.path.exists(usage_path):
                try:
                    with open(usage_path, encoding="utf-8") as _f:
                        data = json.load(_f)
                except (json.JSONDecodeError, OSError):
                    data = {"schema_version": _USAGE_SCHEMA_VERSION, "cycles": []}
            else:
                data = {"schema_version": _USAGE_SCHEMA_VERSION, "cycles": []}
            if not isinstance(data.get("cycles"), list):
                data["cycles"] = []
            data["cycles"].append(entry)
            tmp_path = usage_path + ".tmp"
            with open(tmp_path, "w", encoding="utf-8") as _f:
                json.dump(data, _f, indent=2)
            os.replace(tmp_path, usage_path)
        finally:
            try:
                fcntl.flock(lock_fd, fcntl.LOCK_UN)
            except OSError:
                pass
            lock_fd.close()
    except Exception:  # noqa: BLE001
        pass


def _write_usage_entry(
    *,
    agent_id: str,
    cycle: int,
    call_index: int,
    model: str,
    response: object | None,
    review_outcome: str | None = None,
    exception_class: str | None = None,
    exception_message: str | None = None,
) -> None:
    """Append one usage entry to the cycle usage JSONL.

    Usage fields are read from ``response.usage`` using the litellm
    OpenAI-shape (``prompt_tokens`` / ``completion_tokens``); cache fields
    are extracted defensively via ``getattr``. Delegates the locked write
    to ``_locked_append_usage_record`` so the on-disk format and atomicity
    invariants are shared with ``_write_cooldown_event``.
    """
    usage_obj = getattr(response, "usage", None) if response is not None else None
    if usage_obj is not None:
        input_tokens = getattr(usage_obj, "prompt_tokens", None)
        output_tokens = getattr(usage_obj, "completion_tokens", None)
        cache_read = getattr(usage_obj, "cache_read_input_tokens", None)
        cache_creation = getattr(usage_obj, "cache_creation_input_tokens", None)
    else:
        input_tokens = None
        output_tokens = None
        cache_read = None
        cache_creation = None

    rate_limit_headers = (
        extract_anthropic_ratelimit_headers(response)
        if response is not None
        else {}
    )

    entry: dict[str, object] = {
        "agent_id": agent_id,
        "cycle": cycle,
        "call_index": call_index,
        "model": model,
        "input_tokens": input_tokens,
        "output_tokens": output_tokens,
        "cache_read_input_tokens": cache_read,
        "cache_creation_input_tokens": cache_creation,
        "timestamp_iso": datetime.now(timezone.utc).isoformat(),
    }
    if rate_limit_headers:
        entry["anthropic_ratelimit"] = rate_limit_headers
    if review_outcome is not None:
        entry["review_outcome"] = review_outcome
    if exception_class is not None:
        entry["exception_class"] = exception_class
    if exception_message is not None:
        entry["exception_message"] = exception_message
    _locked_append_usage_record(entry)


def _next_call_index() -> int:
    """Return a monotone per-thread call index (starting at 0)."""
    if not hasattr(_usage_call_counter, "index"):
        _usage_call_counter.index = 0
    idx = _usage_call_counter.index
    _usage_call_counter.index += 1
    return idx


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
    # CI-dispatched code-reviewer-* agents live at agents/ci/ (dispatch-split,
    # bug 4a30). Other CI-dispatched agents (schema-correction, arbiter,
    # verifier, etc.) do not have CI variants and live at agents/. Try ci/
    # first; fall back to agents/ when the file is absent.
    agent_file = _AGENTS_DIR / f"{agent_id}.md"
    if not agent_file.exists():
        agent_file = _PLUGIN_ROOT / "agents" / f"{agent_id}.md"
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
        "claude-haiku-4-5",
        "claude-sonnet-4-6",
        "claude-opus-4-7",
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
    "anthropic": "claude-haiku-4-5",
    "openai": "openai/gpt-4o-mini",
}


def _build_messages(
    diff_text: str,
    agent_id: str = "unknown",
    provider: str = "unknown",
    review_context: str | None = None,
) -> list[dict[str, Any]]:
    system_prompt = _load_agent_prompt(agent_id)
    context_prefix = (
        f"REVIEW_CONTEXT: {review_context}\n\n" if review_context else ""
    )
    user_text = f"{context_prefix}Review this diff:\n\n{diff_text}"
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
                        "text": user_text,
                        "cache_control": {"type": "ephemeral"},
                    }
                ],
            },
        ]
    return [
        {"role": "system", "content": system_prompt},
        {"role": "user", "content": user_text},
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
    elif (
        turn > 0
        and prev_cache_read is not None
        and cache_read > 0  # skip warming turns where cache_read is still 0
        and cache_read <= prev_cache_read
    ):
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
    # R3 (bug f148): also log a sanitized preview of the raw response. Without
    # the body, a 275-byte non-JSON failure is undiagnosable — operators can't
    # distinguish a safety refusal from an overload string from a friendly
    # preamble. Cap at 1024 bytes and escape control characters to keep the
    # log line single-row and avoid leaking secrets unbounded.
    import unicodedata
    _preview_raw = raw_content[:1024]
    _preview = ''.join(
        ch if (ch in '\n\t' or not unicodedata.category(ch).startswith('C'))
        else f'\\x{ord(ch):02x}'
        for ch in _preview_raw
    )
    _preview = _preview.replace('\n', '\\n').replace('\t', '\\t')
    print(f"ERROR [preview]: {_preview}", file=sys.stderr)
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
    review_context: str | None = None,
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

    messages = _build_messages(
        diff_text, agent_id=agent_id, provider=first_provider,
        review_context=review_context,
    )
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

    # Usage-capture: resolve cycle number from DSO_REVIEW_CYCLE env (default 1)
    _usage_cycle = int(os.environ.get("DSO_REVIEW_CYCLE", "1") or "1")

    # Axis 2: manual context-window escalation loop.
    # NOTE: the `context_window_fallbacks` kwarg is a LiteLLM Router parameter
    # and is silently ignored by litellm.completion() — use a manual loop instead.
    for ctx_model in context_model_chain:
        try:
            _call_idx_main = _next_call_index()
            response = litellm.completion(
                model=ctx_model,
                messages=messages,
                stream=False,  # DD1: never stream
                fallbacks=fallbacks,  # DD1: SDK-native cross-provider fallback (Axis 1)
            )
            _write_usage_entry(
                agent_id=agent_id,
                cycle=_usage_cycle,
                call_index=_call_idx_main,
                model=ctx_model,
                response=response,
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

                while aug_turn <= _AUG_SOFT_CAP + _FAIL_CLOSED_OFFSET:
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
                        _call_idx_nudge1 = _next_call_index()
                        current_response = litellm.completion(
                            model=ctx_model,
                            messages=aug_messages,
                            stream=False,
                            fallbacks=fallbacks,
                        )
                        _write_usage_entry(
                            agent_id=agent_id,
                            cycle=_usage_cycle,
                            call_index=_call_idx_nudge1,
                            model=ctx_model,
                            response=current_response,
                        )
                        _aug_cache_read = _check_cache_usage(
                            current_response, aug_turn, _aug_cache_read, first_provider
                        )
                        aug_turn += 1
                        continue

                    # Second nudge at soft_cap+3
                    if (
                        aug_turn >= _AUG_SOFT_CAP + _NUDGE_SECOND_OFFSET
                        and nudge_count == 1
                    ):
                        nudge_count = 2
                        aug_messages = aug_messages + [
                            {"role": "assistant", "content": assistant_content},
                            {"role": "user", "content": _AUG_SECOND_NUDGE},
                        ]
                        _call_idx_nudge2 = _next_call_index()
                        current_response = litellm.completion(
                            model=ctx_model,
                            messages=aug_messages,
                            stream=False,
                            fallbacks=fallbacks,
                        )
                        _write_usage_entry(
                            agent_id=agent_id,
                            cycle=_usage_cycle,
                            call_index=_call_idx_nudge2,
                            model=ctx_model,
                            response=current_response,
                        )
                        _aug_cache_read = _check_cache_usage(
                            current_response, aug_turn, _aug_cache_read, first_provider
                        )
                        aug_turn += 1
                        continue

                    # Fail-closed: reviewer ignored both nudges
                    if (
                        aug_turn >= _AUG_SOFT_CAP + _FAIL_CLOSED_OFFSET
                        and nudge_count >= 2
                    ):
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
                        _call_idx_aug = _next_call_index()
                        current_response = litellm.completion(
                            model=ctx_model,
                            messages=aug_messages,
                            stream=False,
                            fallbacks=fallbacks,
                        )
                        _write_usage_entry(
                            agent_id=agent_id,
                            cycle=_usage_cycle,
                            call_index=_call_idx_aug,
                            model=ctx_model,
                            response=current_response,
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
                                    f"continued emitting context requests after second nudge at turn "
                                    f"{_AUG_SOFT_CAP + _NUDGE_SECOND_OFFSET}, reaching fail-closed threshold "
                                    f"at turn {_AUG_SOFT_CAP + _FAIL_CLOSED_OFFSET} without providing final findings."
                                ),
                                "cited_lines": [f"{_THIS_FILE_GIT_REL}:418"],
                            }
                        ],
                        "augmentation_failed": True,
                    }
                    if fallback_hops:
                        failed_result["fallback_hops"] = fallback_hops
                    return failed_result

            try:
                result = _parse_response(response)
            except Exception as _parse_exc:  # noqa: BLE001
                _write_usage_entry(
                    agent_id=agent_id,
                    cycle=_usage_cycle,
                    call_index=_next_call_index(),
                    model=ctx_model,
                    response=response,
                    review_outcome="failed",
                    exception_class=type(_parse_exc).__name__,
                    exception_message=str(_parse_exc),
                )
                raise

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

        except ValueError as parse_exc:
            # R2 (bug f148): parse failure re-raised from the inner _parse_response
            # try/except above. The LLM call succeeded but returned non-JSON.
            # The PRIOR behavior was to fall through to `except Exception` below
            # and `break` — exhausting the entire context chain on the first
            # parse failure, even when later models in the chain (or the same
            # model on retry) would have produced parseable JSON. `continue`
            # here so the next ctx_model is actually tried.
            last_exc = parse_exc
            logger.debug(
                "Parse failure for model %s — trying next context model: %s",
                ctx_model, parse_exc,
            )
            continue

        except Exception as exc:  # noqa: BLE001
            # Non-context, non-parse error (rate limit, auth, etc.) — break;
            # cross-provider fallbacks= will have already been attempted by
            # the SDK within this call.
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
    review_context: str | None = None,
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

    # Usage-capture: resolve cycle number from DSO_REVIEW_CYCLE env (default 1)
    _usage_cycle = int(os.environ.get("DSO_REVIEW_CYCLE", "1") or "1")

    # --- Call 1: pass only the stripped index (no defense_text) ---
    index_context = (
        "\n\n## Prior review findings index (no defenses — evaluate independently)\n\n"
        + json.dumps(prior_findings_index, indent=2)
    )
    call1_diff = diff_text + index_context
    call1_messages = _build_messages(
        call1_diff, agent_id=agent_id, provider=first_provider,
        review_context=review_context,
    )

    call1_response = _litellm.completion(
        model=resolved_model,
        messages=call1_messages,
        stream=False,
        fallbacks=fallbacks,
    )
    _write_usage_entry(
        agent_id=agent_id,
        cycle=_usage_cycle,
        call_index=_next_call_index(),
        model=resolved_model,
        response=call1_response,
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
    call2_messages = _build_messages(
        call2_diff, agent_id=agent_id, provider=first_provider,
        review_context=review_context,
    )

    call2_response = _litellm.completion(
        model=resolved_model,
        messages=call2_messages,
        stream=False,
        fallbacks=fallbacks,
    )
    _write_usage_entry(
        agent_id=agent_id,
        cycle=_usage_cycle,
        call_index=_next_call_index(),
        model=resolved_model,
        response=call2_response,
    )
    call2_result = _parse_response(call2_response)

    return call2_result


async def _call_single_agent(
    agent_id: str,
    diff_text: str,
    model: str,
    provider_chain: list[str] | None = None,
    tier: str = "standard",
    review_context: str | None = None,
    dispatch_context: "DispatchContext | None" = None,
) -> dict:
    """Dispatch one reviewer agent. Returns findings dict or error entry on any exception.

    Runs the synchronous dispatch_review on a worker thread via asyncio.to_thread
    so that sibling specialists in async_dispatch_specialists' gather() can run
    in parallel. Without this, the gather is a no-op — sync work blocks the
    event loop and serializes all siblings (spike_01_serialization.py).

    When dispatch_context is provided, the coroutine awaits its cooldown_event
    before submitting work, and signals cooldown if the call raises a rate-limit
    error. The cooldown gates new submissions; in-flight to_thread calls cannot
    be interrupted but their failures will configure the cooldown for retries
    and follow-on submissions.
    """
    if dispatch_context is not None:
        await dispatch_context.cooldown_event.wait()
    try:
        result = await asyncio.to_thread(
            dispatch_review,
            diff_text=diff_text,
            agent_id=agent_id,
            primary_model=model,
            provider_chain=provider_chain or ["anthropic"],
            tier=tier,
            review_context=review_context,
        )
        return result
    except Exception as exc:  # noqa: BLE001
        if dispatch_context is not None and should_retry(exc):
            headers = getattr(exc, "litellm_response_headers", None)
            retry_after = parse_retry_after(headers) if headers is not None else None
            delay = calculate_backoff(0, retry_after)
            dispatch_context.signal_cooldown(delay)
            # Offload the synchronous locked-write to a worker thread so we
            # don't block the event loop on lock contention. _write_cooldown_
            # event calls _locked_append_usage_record which contains a
            # time.sleep retry loop (up to ~1s under heavy contention with
            # _write_usage_entry workers).
            await asyncio.to_thread(
                _write_cooldown_event,
                agent_id=agent_id,
                delay_s=delay,
                retry_after_header=retry_after,
                cooldown_index=dispatch_context.cooldown_count,
                exception_class=type(exc).__name__,
            )
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


def _write_cooldown_event(
    *,
    agent_id: str,
    delay_s: float,
    retry_after_header: float | None,
    cooldown_index: int,
    exception_class: str,
) -> None:
    """Append a cooldown_engaged record to the usage JSONL.

    Captures cross-cluster cooldown engagement events for post-mortem
    analysis of 429 storms under Phase 2 shared-context dispatch — what
    logger.warning emits but doesn't structure.

    SYNCHRONOUS — invokes the shared atomic write helper which calls
    ``time.sleep`` under lock contention. Callers in async contexts MUST
    wrap this via ``asyncio.to_thread`` to avoid blocking the event loop.
    """
    entry: dict[str, object] = {
        "event": "cooldown_engaged",
        "agent_id": agent_id,
        "cycle": int(os.environ.get("DSO_REVIEW_CYCLE", "1") or "1"),
        "delay_s": delay_s,
        "retry_after_header": retry_after_header,
        "cooldown_index": cooldown_index,
        "exception_class": exception_class,
        "timestamp_iso": datetime.now(timezone.utc).isoformat(),
    }
    _locked_append_usage_record(entry)


def dispatch_arch_synthesis(
    merged_findings_json: str,
    diff_text: str,
    model: str,
    provider_chain: list[str],
) -> dict:
    """Approximate opus arch synthesis: sequential call after 3 parallel specialists."""
    augmented_input = (
        f"{diff_text}\n\n## Prior specialist findings\n\n{merged_findings_json}"
    )
    return dispatch_review(
        diff_text=augmented_input,
        agent_id="code-reviewer-deep-arch",
        primary_model=model,
        provider_chain=provider_chain,
        tier="deep",
    )


def dispatch_schema_correction(
    original_findings: list[dict[str, Any]],
    schema_errors: list[str] | None = None,
    *,
    diff_text: str = "",
    provider_chain: list[str] | None = None,
    agent_id: str = "unknown",
    primary_model: str | None = None,
    environ: dict[str, str] | None = None,
    max_attempts: int = 1,
    validate_cmd: list[str] | None = None,
    plugin_root: pathlib.Path | None = None,
) -> dict[str, Any]:
    """Attempt to correct schema-invalid findings by re-dispatching the review.

    If the corrected response is schema-valid and preserves all frozen fields
    byte-for-byte with the same finding count, the corrected result is returned.
    Otherwise, each failed attempt consumes one retry. After all attempts are
    exhausted (or if max_attempts=0), a synthetic schema_error finding is appended
    to the last response and returned.

    Args:
        original_findings: The original findings list (for frozen-field comparison).
        schema_errors: List of schema validation error messages to prepend to correction prompt.
        diff_text: Unified diff text to review.
        provider_chain: Ordered list of provider names. Defaults to ["anthropic"].
        agent_id: Identifier of the reviewing agent.
        primary_model: Override the primary model for the first provider call.
        environ: Environment variable mapping for credential checks.
        max_attempts: Maximum number of correction attempts. 0 skips dispatch entirely.
        validate_cmd: Unused; kept for interface compatibility.
        plugin_root: Override for plugin root path resolution.

    Returns:
        A dict with "findings" key. On success, contains corrected findings.
        On failure, contains a synthetic schema_error finding appended.
    """
    import dso_ci_review.runner as _runner_mod

    # Guard against None provider_chain
    if provider_chain is None:
        provider_chain = ["anthropic"]

    # Resolve plugin_root using the same approach as _resolve_validator_script()
    if plugin_root is None:
        _env_root = os.environ.get("CLAUDE_PLUGIN_ROOT")
        if _env_root is not None:
            plugin_root = pathlib.Path(_env_root)
        else:
            _five_up = (
                pathlib.Path(__file__).resolve().parent.parent.parent.parent.parent
            )
            plugin_root = _five_up / "plugins" / "dso"

    # Load correction prompt fragment
    prompt_fragment_path = (
        plugin_root / "docs" / "workflows" / "prompts" / "reviewer-schema-correction.md"
    )
    try:
        prompt_fragment = prompt_fragment_path.read_text(encoding="utf-8")
    except OSError:
        prompt_fragment = ""

    # Build correction prompt
    original_findings_json = json.dumps({"findings": original_findings}, indent=2)
    _schema_errors = schema_errors or []
    schema_errors_text = (
        "\n\n## Schema errors to fix\n\n" + "\n".join(f"- {e}" for e in _schema_errors)
        if _schema_errors
        else ""
    )
    _CORRECTION_DIFF_CHAR_LIMIT = 50_000
    _diff_section = (
        "\n\n## Diff\n\n" + diff_text
        if len(diff_text) <= _CORRECTION_DIFF_CHAR_LIMIT
        else "\n\n## Diff\n\n(omitted — diff exceeds correction prompt size limit)\n"
    )
    correction_prompt = (
        prompt_fragment
        + schema_errors_text
        + "\n\n## Original findings\n\n"
        + original_findings_json
        + _diff_section
    )

    def _make_synthetic_error(error_details: str) -> dict[str, Any]:
        # severity=important (not critical): a pipeline-internal schema-correction
        # failure is not a code-review finding about the PR's code. Demoting to
        # important keeps the signal visible while making the finding eligible
        # for R5 autonomous resolution / defense rather than hard-blocking PRs
        # on pipeline-internal issues (bug 5126-dc68).
        return {
            "type": "parse_error",
            "severity": "important",
            "category": "schema_error",
            "description": f"Schema correction failed after {max_attempts} attempt(s): {error_details}",
            "finding_id": f"schema_error_{hashlib.md5(error_details.encode()).hexdigest()[:8]}",
            "file": "",
            "cited_lines": [],
            "cited_excerpt": "",
            "reachability": "",
        }

    # Short-circuit: max_attempts=0 skips dispatch entirely
    if max_attempts == 0:
        error_details = "max_attempts=0, dispatch skipped"
        return {
            "findings": [_make_synthetic_error(error_details)],
            "summary": "Schema correction applied: skipped (max_attempts=0)",
        }

    last_error: str = "unknown error"
    last_result: dict[str, Any] | None = None

    for _attempt in range(max_attempts):
        # Dispatch the correction review
        attempt_result = dispatch_review(
            diff_text=correction_prompt,
            provider_chain=provider_chain,
            agent_id=agent_id,
            primary_model=primary_model,
            environ=environ,
        )
        _raw_findings = attempt_result.get("findings", [])
        attempt_findings = _raw_findings if isinstance(_raw_findings, list) else []

        # When dispatch_review itself fails (API overload, network error), it returns
        # {"findings": [fallback_exhausted_entry]} with no "summary" key. Treating
        # this as a correction attempt would fail schema validation ("missing summary")
        # rather than correctly falling through to the reachability fallback.
        # Preserve original_findings as last_result so the reachability fallback can
        # still apply programmatic boilerplate to recover from missing-reachability errors.
        _infra_failed = any(
            isinstance(f, dict) and f.get("type") == "fallback_exhausted"
            for f in attempt_findings
        )
        if _infra_failed:
            _exc_msg = next(
                (
                    f.get("final_exception_message", "unknown")
                    for f in attempt_findings
                    if isinstance(f, dict) and f.get("type") == "fallback_exhausted"
                ),
                "unknown",
            )
            last_error = f"correction dispatch infrastructure failure: {_exc_msg[:200]}"
            # Only fall back to original_findings when no prior attempt produced a
            # non-infra result. With max_attempts > 1, a successful correction on
            # iteration N must not be overwritten by an infra-failure on iteration N+1.
            if last_result is None:
                last_result = {
                    "findings": list(original_findings),
                    "summary": "schema correction — api unavailable, reverting to original findings for reachability fallback",
                }
            continue

        last_result = attempt_result

        # Validate schema via runner._validate_findings_schema
        schema_result = _runner_mod._validate_findings_schema(
            attempt_result,
            plugin_root=str(plugin_root),
        )

        if schema_result.status != "schema_pass":
            last_error = (
                "; ".join(schema_result.errors)
                if schema_result.errors
                else "schema_fail"
            )
            continue

        # Check finding count matches original — but compare REAL findings only.
        # Synthetic types (fallback_exhausted, specialist_error, parse_error) are
        # sentinel markers the dispatch layer injects when the LLM call failed or
        # the response couldn't be parsed; they are not real review findings.
        # Schema correction validly drops these when the corrected payload is
        # well-formed (e.g., the original was a sole fallback_exhausted entry and
        # the corrected response is the empty array — no real review feedback).
        # Counting them as "expected" would force the corrector to fabricate
        # findings to satisfy a count it never should match (bug 881d-e5cc).
        _SYNTHETIC_TYPE_NAMES = {
            "fallback_exhausted",
            "specialist_error",
            "parse_error",
        }
        _real_original = [
            f
            for f in original_findings
            if not (isinstance(f, dict) and f.get("type") in _SYNTHETIC_TYPE_NAMES)
        ]
        _real_attempt = [
            f
            for f in attempt_findings
            if not (isinstance(f, dict) and f.get("type") in _SYNTHETIC_TYPE_NAMES)
        ]
        if len(_real_attempt) != len(_real_original):
            last_error = (
                f"finding count mismatch (real findings): got {len(_real_attempt)}, "
                f"expected {len(_real_original)} "
                f"(total: got {len(attempt_findings)}, original {len(original_findings)})"
            )
            continue

        # Check frozen fields are byte-for-byte identical. Compare real findings
        # only — synthetic markers (filtered above) are not subject to frozen-field
        # preservation; they are sentinels the dispatch layer injects when no real
        # findings exist (bug 881d-e5cc).
        frozen_ok = True
        for i, (orig, corrected) in enumerate(zip(_real_original, _real_attempt)):
            for field in _FROZEN_FIELDS:
                if field not in orig:
                    continue  # absent fields may be added by correction
                # cited_lines: frozen only when original is schema-valid (non-empty
                # list with all entries matching <path>:<line> format). When malformed,
                # the correction must be allowed to fix the format — identical to the
                # finding_id exception below.
                if field == "cited_lines":
                    orig_cited = orig[field]
                    orig_cited_valid = (
                        isinstance(orig_cited, list)
                        and len(orig_cited) > 0
                        and all(
                            isinstance(e, str) and _CITED_LINE_RE.match(e)
                            for e in orig_cited
                        )
                    )
                    if not orig_cited_valid:
                        continue  # malformed original — allow correction to fix format
                    # Range-equivalence exemption: when the corrector collapses
                    # discrete line entries into a contiguous range covering the
                    # same line numbers (e.g. ['x:134', 'x:138'] -> ['x:134-138']),
                    # the citation is semantically preserved — no hallucination.
                    # Skip the strict byte-equality check and let downstream
                    # schema validation decide whether the corrected format is
                    # acceptable (bug 5126-dc68).
                    corr_cited = corrected.get(field)
                    if (
                        isinstance(corr_cited, list)
                        and len(corr_cited) > 0
                        and all(
                            isinstance(e, str) and _CITED_LINE_RE.match(e)
                            for e in corr_cited
                        )
                    ):

                        def _expand(entries: list[str]) -> set[tuple[str, int]]:
                            out: set[tuple[str, int]] = set()
                            for e in entries:
                                path, _, line_part = e.rpartition(":")
                                if "-" in line_part:
                                    lo_s, hi_s = line_part.split("-", 1)
                                    try:
                                        lo, hi = int(lo_s), int(hi_s)
                                    except ValueError:
                                        return set()
                                    for ln in range(lo, hi + 1):
                                        out.add((path, ln))
                                else:
                                    try:
                                        out.add((path, int(line_part)))
                                    except ValueError:
                                        return set()
                            return out

                        orig_lines = _expand(orig_cited)
                        corr_lines = _expand(corr_cited)
                        if orig_lines and orig_lines.issubset(corr_lines):
                            continue  # corrected covers all original lines
                # severity: frozen only when original is enum-valid (in
                # _VALID_SEVERITIES). When the original is enum-invalid (e.g. LLM
                # emits "suggestion" — referenced in plugin docs but not in the
                # dispatch enum), correction must be allowed to repair the enum —
                # otherwise schema correction cannot resolve severity-enum errors
                # and the llm-review job fails closed. Bug 0d1e-e9d5-2fcb-4bc5.
                if field == "severity":
                    if orig.get("severity") not in _VALID_SEVERITIES:
                        continue  # enum-invalid original — allow correction to repair enum
                # category: frozen only when original is enum-valid (in
                # _VALID_CATEGORIES — the canonical 5-value enum). When the
                # original is off-enum (e.g. LLM emits "code_smell",
                # "missing_test_coverage"), correction MUST be allowed to remap
                # it to a canonical bucket — otherwise schema correction cannot
                # resolve category-enum errors and the llm-review job fails
                # closed (bug 0623-54f4-d31b-4623; 35 off-enum values observed
                # in one PR #257/258 run). Mirrors the severity exception above.
                if field == "category":
                    if orig.get("category") not in _VALID_CATEGORIES:
                        continue  # off-enum original — allow correction to remap to canonical
                if corrected.get(field) != orig[field]:
                    last_error = (
                        f"frozen field {field!r} mutated at index {i}: "
                        f"original={orig[field]!r}, corrected={corrected.get(field)!r}"
                    )
                    frozen_ok = False
                    break
            if not frozen_ok:
                break
            # finding_id: frozen when original is structurally valid; regeneration
            # allowed only when original is absent, empty, or malformed.
            orig_fid = str(orig.get("finding_id") or "")
            if (
                _FINDING_ID_RE.match(orig_fid)
                and corrected.get("finding_id") != orig_fid
            ):
                last_error = (
                    f"frozen field 'finding_id' mutated at index {i}: "
                    f"original={orig_fid!r}, corrected={corrected.get('finding_id')!r}"
                )
                frozen_ok = False

        if not frozen_ok:
            continue

        # All checks passed — return corrected result
        return attempt_result

    # Programmatic reachability fallback: if the ONLY remaining errors are
    # missing/empty 'reachability' fields, inject a category-appropriate boilerplate
    # rather than failing closed. This handles the case where the correction LLM
    # repeatedly forgets to add reachability despite explicit prompting (observed
    # in CI cycles 9+: important/maintainability and important/hygiene findings in
    # test files where a caller-input→harm chain is not semantically applicable).
    _reach_fallback_applied = False
    if last_result is not None:
        _last_findings = list(last_result.get("findings", []))
        # Validate to find remaining errors against a fresh copy
        _revalidate = _runner_mod._validate_findings_schema(
            last_result, plugin_root=str(plugin_root)
        )
        # Filter out header lines (SCHEMA_VALID:, Validation errors:) to get
        # only the actual field-level validation errors (lines containing "findings[")
        _field_errors = [_e for _e in _revalidate.errors if "findings[" in _e]
        # Filter out soft-mode WARNING: lines (absence-claim findings missing
        # verification_evidence in soft mode go to stderr but may appear in
        # _revalidate.errors); exclude them when checking "only reachability errors"
        # so the reachability fallback still fires when WARNINGs are interleaved.
        _hard_field_errors = [
            _e for _e in _field_errors if not _e.startswith("WARNING:")
        ]
        _only_reach_errors = bool(_hard_field_errors) and all(
            "reachability" in _e for _e in _hard_field_errors
        )
        # Absence-claim evidence fallback: inject boilerplate verification_evidence
        # into findings flagged by soft-mode absence-claim WARNINGs before the
        # reachability fallback runs, so both can be applied in a single pass.
        _absence_warn_re = None
        _absence_indices: set[int] = set()
        import re as _re_ac

        _absence_warn_re = _re_ac.compile(
            r"WARNING:.*findings\[(\d+)\]\.verification_evidence absent on absence-claim"
        )
        for _err in _revalidate.errors:
            _wm = _absence_warn_re.search(_err)
            if _wm:
                _absence_indices.add(int(_wm.group(1)))
        _ABSENCE_EVIDENCE_BOILERPLATE = {
            "command": "fallback",
            "output": (
                "fallback-injected; reviewer did not run an explicit verification "
                "command for this absence claim"
            ),
        }
        if _absence_indices:
            _patched_ac = list(_last_findings)
            for _idx in sorted(_absence_indices):
                if _idx < len(_patched_ac):
                    _f = dict(_patched_ac[_idx])
                    if "verification_evidence" not in _f:
                        _f["verification_evidence"] = _ABSENCE_EVIDENCE_BOILERPLATE
                    _patched_ac[_idx] = _f
            _last_findings = _patched_ac
        if _only_reach_errors:
            # Parse which finding indices need reachability
            import re as _re

            _reach_idx_re = _re.compile(r"findings\[(\d+)\].*reachability")
            _indices_needing_reach: set[int] = set()
            for _err in _revalidate.errors:
                _m = _reach_idx_re.search(_err)
                if _m:
                    _indices_needing_reach.add(int(_m.group(1)))
            # Generate per-finding boilerplate keyed by category
            _CAT_BOILERPLATE: dict[str, str] = {
                "maintainability": (
                    "Code maintainability risk: large or duplicated code accumulates "
                    "cognitive overhead for contributors and increases the probability "
                    "of merge conflicts and missed updates during future changes."
                ),
                "hygiene": (
                    "Code hygiene risk: duplicated or inconsistent patterns create "
                    "maintenance burden and increase the probability that future "
                    "changes will miss one of the copies, leading to drift."
                ),
                "design": (
                    "Design risk: structural complexity increases the surface area "
                    "for misuse by callers, raising the likelihood of incorrect "
                    "usage and subtle integration bugs over time."
                ),
                "verification": (
                    "Test coverage risk: uncovered paths will not catch regressions "
                    "when future changes alter the affected logic, allowing bugs to "
                    "reach production undetected."
                ),
            }
            _DEFAULT_BOILERPLATE = (
                "Risk path: the identified concern degrades code quality over "
                "time, increasing the probability of defects introduced by future "
                "contributors who rely on the affected component."
            )
            _patched_findings = list(_last_findings)
            for _idx in sorted(_indices_needing_reach):
                if _idx < len(_patched_findings):
                    _f = dict(_patched_findings[_idx])
                    _cat = str(_f.get("category", "")).lower()
                    _f["reachability"] = _CAT_BOILERPLATE.get(
                        _cat, _DEFAULT_BOILERPLATE
                    )
                    _patched_findings[_idx] = _f
            _patched_result = {**last_result, "findings": _patched_findings}
            _revalidate2 = _runner_mod._validate_findings_schema(
                _patched_result, plugin_root=str(plugin_root)
            )
            if _revalidate2.status == "schema_pass":
                print(
                    f"INFO: schema correction reachability fallback applied to "
                    f"{len(_indices_needing_reach)} finding(s) — "
                    f"boilerplate reachability injected for indices "
                    f"{sorted(_indices_needing_reach)}",
                    file=sys.stderr,
                )
                return _patched_result
            _reach_fallback_applied = True  # fallback attempted but still failed
        elif _absence_indices and not _only_reach_errors:
            # Absence-claim boilerplate was injected but there were no pure-reachability
            # errors: validate the absence-patched result on its own.
            _patched_ac_result = {**last_result, "findings": _last_findings}
            _revalidate_ac = _runner_mod._validate_findings_schema(
                _patched_ac_result, plugin_root=str(plugin_root)
            )
            if _revalidate_ac.status == "schema_pass":
                print(
                    f"INFO: schema correction absence-claim fallback applied to "
                    f"{len(_absence_indices)} finding(s) — "
                    f"boilerplate verification_evidence injected for indices "
                    f"{sorted(_absence_indices)}",
                    file=sys.stderr,
                )
                return _patched_ac_result

    # All attempts exhausted — append synthetic schema_error to last result
    _fallback_note = (
        " (reachability fallback also failed)" if _reach_fallback_applied else ""
    )
    synthetic_error = _make_synthetic_error(last_error + _fallback_note)
    if last_result is not None:
        findings_out = list(last_result.get("findings", []))
        findings_out.append(synthetic_error)
        exhausted_result = {**last_result, "findings": findings_out}
        exhausted_result.setdefault(
            "summary", "Schema correction applied: all attempts exhausted"
        )
        return exhausted_result
    return {
        "findings": [synthetic_error],
        "summary": "Schema correction applied: all attempts exhausted",
    }


async def async_dispatch_specialists(
    agents: list[dict],
    *,
    dispatch_context: "DispatchContext | None" = None,
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
        dispatch_context: Per-asyncio.run rate-limit coordination state. When
            None, a fresh context is created and cleaned up for this call. Phase 2
            cluster-level dispatch passes a shared context so cooldowns coordinate
            across clusters within a single asyncio.run.
    """
    if not agents:
        return []

    owns_context = dispatch_context is None
    if owns_context:
        dispatch_context = DispatchContext.create()
    try:
        tasks = [
            _call_single_agent(
                agent_id=a["agent_id"],
                diff_text=a["diff_text"],
                model=a["model"],
                provider_chain=a.get("provider_chain"),
                tier=a.get("tier", "standard"),
                review_context=a.get("review_context"),
                dispatch_context=dispatch_context,
            )
            for a in agents
        ]
        results = await asyncio.gather(*tasks, return_exceptions=True)
    finally:
        if owns_context:
            dispatch_context.cleanup()

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
