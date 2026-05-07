"""dso_ci_review.runner — CLI entry point for CI code-review.

Environment variables (all optional):
    DSO_CI_REVIEW_DIFF_PATH   Path to a unified diff file to review.
                              If unset, reads from stdin.
    DSO_CI_REVIEW_OUTPUT_PATH Path to write findings JSON.
                              If unset, writes to stdout.
    DSO_CI_REVIEW_DRY_RUN     When set to "1", emit a canned empty-findings
                              response without calling any LLM. Useful for
                              smoke-testing the subprocess invocation path.
    DSO_CI_REVIEW_MODEL       Model identifier passed to the active provider
                              (optional; provider default is used when absent).
    CI_REVIEW_PROVIDER        Provider name (e.g. "anthropic", "openai").
                              Resolved by providers/config.py.

Exit codes:
    0  Success (findings JSON written)
    1  Error (details on stderr)
"""

from __future__ import annotations

import asyncio
import json
import os
import subprocess
import sys
import tempfile

from dso_ci_review.classifier import classify_tier
from dso_ci_review.dispatch import async_dispatch_specialists
from dso_ci_review.findings import merge_findings
from dso_ci_review.providers.config import AuthError, ConfigError, get_provider

# Severity values that must block merge — match local record-review.sh enforcement.
# fragile is treated identically to important per CLAUDE.md rule 11 / reviewer-base.md.
_BLOCKING_SEVERITIES = frozenset({"critical", "important", "fragile"})

# Synthetic finding types — produced by infrastructure failures, not real review work.
# These carry a severity field for schema conformance but must not count toward the
# severity gate (the all-specialist-errors check below handles infra failures separately).
_SYNTHETIC_TYPES = frozenset({"specialist_error", "fallback_exhausted", "parse_error"})


def _real_blocking_findings(findings: list[dict]) -> list[dict]:
    """Return the subset of findings that should block merge.

    A finding blocks when:
    - severity is in _BLOCKING_SEVERITIES (case-insensitive), AND
    - type is NOT in _SYNTHETIC_TYPES (real review work, not an infra failure)
    """
    out: list[dict] = []
    for f in findings or []:
        if f.get("type", "") in _SYNTHETIC_TYPES:
            continue
        sev = str(f.get("severity", "")).lower()
        if sev in _BLOCKING_SEVERITIES:
            out.append(f)
    return out


def _resolve_pr_number() -> str | None:
    """Resolve the current PR number from GitHub Actions env vars.

    Returns the PR number as a string when running in pull_request event context,
    else None. Sources checked, in order:
      1. GITHUB_REF (format: refs/pull/<N>/merge on PR events)
      2. PR_NUMBER env var (host-project override)
    """
    if os.environ.get("GITHUB_EVENT_NAME", "") != "pull_request":
        return None
    ref = os.environ.get("GITHUB_REF", "")
    # GITHUB_REF on PR events is "refs/pull/<N>/merge"
    if ref.startswith("refs/pull/"):
        rest = ref[len("refs/pull/") :]
        num = rest.split("/", 1)[0]
        if num.isdigit():
            return num
    pr_num = os.environ.get("PR_NUMBER", "")
    if pr_num.isdigit():
        return pr_num
    return None


def _safe_inline(s: object) -> str:
    """Strip newlines / carriage returns from any LLM-controlled string before
    interpolation into a markdown heading. Prevents heading-line escape via \\n."""
    return str(s).replace("\n", " ").replace("\r", " ")


def _format_review_body(blocking: list[dict], total_count: int) -> str:
    """Format a PR review body summarizing blocking findings."""
    lines = [
        "## DSO CI llm-review — blocking findings",
        "",
        f"{len(blocking)} of {total_count} finding(s) require attention before merge "
        f"(severity in critical/important/fragile per CLAUDE.md rule 11).",
        "",
    ]
    for i, f in enumerate(blocking, 1):
        sev = _safe_inline(f.get("severity", "?"))
        cat = _safe_inline(f.get("category", "?"))
        desc = (f.get("description") or "").strip()
        cited = f.get("cited_lines") or []
        cited_str = (
            ", ".join(_safe_inline(c) for c in cited) if cited else "(no citations)"
        )
        lines.append(f"### {i}. [{sev}/{cat}] {cited_str}")
        lines.append("")
        # Wrap LLM-controlled description in a fenced code block to prevent
        # markdown / HTML injection in the rendered PR comment. A nested fence
        # in the description itself would close ours; replace literal triple
        # backticks with a Unicode look-alike to neutralize that vector.
        safe_desc = desc.replace("```", "ˋˋˋ")
        lines.append("```")
        lines.append(safe_desc)
        lines.append("```")
        lines.append("")
    lines.append("---")
    lines.append(
        "_Posted by dso_ci_review.runner; see CI llm-review job logs for full output._"
    )
    return "\n".join(lines)


def _post_pr_review(findings: list[dict]) -> bool:
    """Post blocking findings as a PR review via the gh CLI.

    Returns True when a comment was successfully posted; False otherwise
    (no-op preconditions OR posting failure). The caller uses this to phrase
    the gate's stderr message accurately — claiming "see the PR comment" when
    no comment exists is misleading.

    No-op (returns False) when:
    - GITHUB_EVENT_NAME != "pull_request" (push, workflow_dispatch, etc.)
    - PR number cannot be resolved
    - GITHUB_TOKEN is absent (gh auth would fail anyway)
    - blocking finding list is empty (nothing to surface)

    Errors are logged to stderr but never propagate — the severity gate below
    is authoritative for blocking; comment posting is a best-effort UX layer.
    """
    blocking = _real_blocking_findings(findings)
    if not blocking:
        return False
    pr_number = _resolve_pr_number()
    if not pr_number:
        return False
    if not os.environ.get("GITHUB_TOKEN"):
        print(
            "WARNING: GITHUB_TOKEN absent; cannot post PR review for findings",
            file=sys.stderr,
        )
        return False

    body = _format_review_body(blocking, total_count=len(findings))
    try:
        subprocess.run(
            [
                "gh",
                "pr",
                "comment",
                pr_number,
                "--body",
                body,
            ],
            check=True,
            capture_output=True,
            text=True,
            timeout=30,
        )
    except (
        subprocess.CalledProcessError,
        subprocess.TimeoutExpired,
        FileNotFoundError,
    ) as exc:
        # Best-effort — never block the gate on a failed comment post.
        # Print only the exception class name (not str(exc)), since gh stderr
        # captured by CalledProcessError can include URLs / token-bearing
        # diagnostic text on auth failures.
        print(
            f"WARNING: failed to post PR review comment ({type(exc).__name__})",
            file=sys.stderr,
        )
        return False
    return True


def _read_diff() -> str:
    """Read the diff from DSO_CI_REVIEW_DIFF_PATH or stdin."""
    diff_path = os.environ.get("DSO_CI_REVIEW_DIFF_PATH")
    if diff_path:
        with open(diff_path, encoding="utf-8") as fh:
            return fh.read()
    return sys.stdin.read()


def _write_output(data: dict) -> None:
    """Serialize data as JSON to DSO_CI_REVIEW_OUTPUT_PATH or stdout.

    When DSO_CI_REVIEW_OUTPUT_PATH is set, the write is performed atomically
    via a temp file + os.replace() (rename syscall on POSIX) to prevent
    parsers from observing a partially-written file (DD3 requirement).
    """
    serialized = json.dumps(data, indent=2)
    output_path = os.environ.get("DSO_CI_REVIEW_OUTPUT_PATH")
    if output_path:
        dir_path = os.path.dirname(os.path.abspath(output_path))
        os.makedirs(dir_path, exist_ok=True)
        with tempfile.NamedTemporaryFile(
            mode="w", dir=dir_path, suffix=".tmp", delete=False, encoding="utf-8"
        ) as tmp:
            tmp.write(serialized)
            tmp_path = tmp.name
        os.replace(tmp_path, output_path)  # atomic on POSIX (rename syscall)
    else:
        print(serialized)


_TIER_MODEL_DEFAULTS: dict[str, str] = {
    "light": "claude-haiku-4-5-20251001",
    "standard": "claude-sonnet-4-6",
    "deep": "claude-sonnet-4-6",
}


def _read_tier_model(tier: str, config_path: str | None = None) -> str:
    """Return the model for the given tier, reading from dso-config.conf when available.

    Resolution order:
      1. DSO_CI_REVIEW_MODEL env var (explicit override, any tier)
      2. model.<tier> key in config_path (or auto-detected repo config)
      3. _TIER_MODEL_DEFAULTS[tier] (haiku=light, sonnet=standard/deep)
    """
    env_override = os.environ.get("DSO_CI_REVIEW_MODEL")
    if env_override:
        return env_override

    # Locate config file
    if config_path is None:
        config_path = os.path.join(
            os.path.dirname(
                os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
            ),
            ".claude",
            "dso-config.conf",
        )

    config_key = f"model.{tier}="
    if os.path.isfile(config_path):
        with open(config_path, encoding="utf-8") as fh:
            for line in fh:
                line = line.strip()
                if line.startswith(config_key):
                    value = line[len(config_key) :].strip()
                    if value:
                        return value

    return _TIER_MODEL_DEFAULTS.get(tier, "claude-sonnet-4-6")


def _build_agents_for_tier(
    tier: str,
    diff_text: str,
    classification: dict,  # noqa: ARG001 — reserved for overlay use
    config_path: str | None = None,
) -> list[dict]:
    """Build agent dispatch list based on classifier tier."""
    base_model = _read_tier_model(tier, config_path)
    provider = os.environ.get("CI_REVIEW_PROVIDER", "anthropic")
    provider_chain = [provider]

    if tier == "deep":
        # Deep tier: 3 parallel specialists
        agents = [
            {
                "agent_id": "code-reviewer-deep-correctness",
                "diff_text": diff_text,
                "model": base_model,
                "provider_chain": provider_chain,
            },
            {
                "agent_id": "code-reviewer-deep-verification",
                "diff_text": diff_text,
                "model": base_model,
                "provider_chain": provider_chain,
            },
            {
                "agent_id": "code-reviewer-deep-hygiene",
                "diff_text": diff_text,
                "model": base_model,
                "provider_chain": provider_chain,
            },
        ]
    else:
        # light or standard: single agent
        agents = [
            {
                "agent_id": f"code-reviewer-{tier}",
                "diff_text": diff_text,
                "model": base_model,
                "provider_chain": provider_chain,
            }
        ]

    return agents


def main() -> int:
    """Run the CI review and return an exit code."""
    dry_run = os.environ.get("DSO_CI_REVIEW_DRY_RUN") == "1"

    if dry_run:
        findings = {"findings": [], "dry_run": True}
        _write_output(findings)
        return 0

    diff_text = _read_diff()
    if not diff_text.strip():
        _write_output({"findings": []})
        return 0

    # Validate provider configuration before dispatching any LLM calls.
    # Resolve provider from CI_REVIEW_PROVIDER env var, falling back to
    # model.provider in dso-config.conf, then defaulting to "anthropic".
    _ci_provider = os.environ.get("CI_REVIEW_PROVIDER", "").strip()
    if not _ci_provider:
        # Attempt to read model.provider from dso-config.conf as a fallback
        _config_path = os.path.join(
            os.path.dirname(
                os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
            ),
            ".claude",
            "dso-config.conf",
        )
        if os.path.isfile(_config_path):
            with open(_config_path, encoding="utf-8") as _f:
                for _line in _f:
                    _line = _line.strip()
                    if _line.startswith("ci_review.provider="):
                        _ci_provider = _line[len("ci_review.provider=") :].strip()
                        break
                    if not _ci_provider and _line.startswith("model.provider="):
                        _ci_provider = _line[len("model.provider=") :].strip()
        if not _ci_provider:
            _ci_provider = "anthropic"
    # get_provider(name=...) raises AuthError when the required API key is absent.
    try:
        get_provider(name=_ci_provider)
    except (ConfigError, AuthError) as exc:
        kind = "provider config" if isinstance(exc, ConfigError) else "provider auth"
        print(f"ERROR: {kind}: {exc}", file=sys.stderr)
        return 1

    try:
        # Step 1: classify tier
        classification = classify_tier(diff_text)
        tier = classification["selected_tier"]

        # Step 2: build agent list based on tier
        agents = _build_agents_for_tier(tier, diff_text, classification)

        # Step 3: dispatch agents (async)
        all_findings = asyncio.run(async_dispatch_specialists(agents))

        # Step 4: merge findings
        merged = merge_findings(*all_findings)

        # Step 5: write output
        _write_output(merged)
    except Exception as exc:  # noqa: BLE001
        print(f"ERROR: LLM call failed: {exc}", file=sys.stderr)
        return 1

    # Detect all-specialist-error: every finding is a specialist_error with no real review.
    # Exit 1 so the CI job fails visibly instead of silently no-op'ing (fcea-6e83).
    _findings = merged.get("findings") or []
    all_specialist_errors = bool(_findings) and all(
        f.get("type") == "specialist_error" for f in _findings
    )
    if all_specialist_errors:
        print(
            "ERROR: all specialist dispatches failed — no review findings produced "
            "(check litellm installation and API key configuration)",
            file=sys.stderr,
        )
        return 1

    # Warn (non-blocking) when all findings are synthetic (e840-327f).
    # fallback_exhausted / specialist_error / parse_error findings indicate review
    # infrastructure issues but are not hard failures — alert the operator without
    # blocking CI. Use _SYNTHETIC_TYPES (single source of truth for what counts as
    # synthetic) so this WARNING and _real_blocking_findings agree.
    if _findings and all(f.get("type", "") in _SYNTHETIC_TYPES for f in _findings):
        print(
            f"WARNING: all {len(_findings)} finding(s) are synthetic "
            f"({'/'.join(sorted(_SYNTHETIC_TYPES))}) — review content may be incomplete",
            file=sys.stderr,
        )

    # Surface blocking findings to the PR (best-effort) before deciding exit code,
    # so the author has visible context whether the gate passes or fails.
    _comment_posted = _post_pr_review(_findings)

    # Severity gate (bug f2c7-257e): block merge when any real finding is
    # critical / important / fragile, matching local record-review.sh enforcement.
    # Synthetic findings (specialist_error, fallback_exhausted, parse_error) are
    # excluded — those represent infrastructure failures and are handled by the
    # all-specialist-errors check above.
    _blocking = _real_blocking_findings(_findings)
    if _blocking:
        sev_summary: dict[str, int] = {}
        for f in _blocking:
            sev = str(f.get("severity", "?")).lower()
            sev_summary[sev] = sev_summary.get(sev, 0) + 1
        sev_str = ", ".join(f"{c} {s}" for s, c in sorted(sev_summary.items()))
        # Only mention the PR comment when one was actually posted (return value
        # of _post_pr_review). Avoids "see the PR comment" pointing at a comment
        # that was never created (failed gh auth, missing event context, etc.).
        comment_hint = "and PR review comment " if _comment_posted else ""
        print(
            f"ERROR: llm-review found blocking finding(s) — {sev_str} "
            f"(see findings JSON above {comment_hint}for details)",
            file=sys.stderr,
        )
        return 1

    return 0


if __name__ == "__main__":
    sys.exit(main())
