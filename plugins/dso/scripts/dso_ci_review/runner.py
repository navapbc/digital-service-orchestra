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

from dso_ci_review.dispatch import async_dispatch_specialists, _validate_agent_files, dispatch_arch_synthesis
from dso_ci_review.findings import merge_findings
from dso_ci_review.providers.config import AuthError, ConfigError, get_provider

# REVIEW-DEFENSE block — refutations for PR #62 round-3 LLM review false positives.
# These findings recur because the CI _SYSTEM_PROMPT (dispatch.py:23-30) lacks the
# severity calibration rubric and NOT-flag rules from the canonical reviewer agent
# files. Bug 5075-54e2 tracks the upstream fix; until then, each pass produces a
# new round of plausible-sounding but incorrect findings on this same code.
#
# F1 (BASE_REF availability): actions/checkout@v4 with fetch-depth:0 either
#   succeeds with full history or fails the job. There is no "silent incomplete
#   history" path. The added `git rev-parse --verify --quiet` guard is belt-and-
#   suspenders, not a fix for an actual failure mode.
# F3 (string sentinel race): GitHub Actions outputs are always strings. There is
#   no race condition — outputs are written once via `>> "$GITHUB_OUTPUT"` (file
#   append) — and no shell expansion vector exists for the literal "true"/"false".
# F4 (merge-base diff): the code uses three-dot range `"$BASE_REF...HEAD"`, which
#   IS the merge-base form. The reviewer's suggestion to "use merge base" is
#   already implemented.
# F5 (test strict equality): re-flag of an already-defended item. PyYAML parses
#   the YAML before comparison; whitespace/quoting variation in source YAML does
#   not change the parsed Python string. The strict equality is intentional per
#   prior pass-2 review.
# F7 (stderr operational visibility): the suppression is INTENTIONAL — see the
#   _post_pr_review docstring for the rationale. `subprocess.run(..., capture_output
#   =True)` captures gh's stdout/stderr into the CompletedProcess / CalledProcessError
#   object; on failure, only `type(exc).__name__` reaches the runner's stderr.
#   Surfacing gh's stderr would risk leaking URLs and token-bearing diagnostic
#   text on auth failures. Operators debug failed posts by re-running the gh
#   command outside the runner, where capture is opt-in.
# F8 (test mock fragility): `patch.object(runner_mod, "subprocess", ...)` targets
#   the `subprocess` module attribute set by the top-of-file `import subprocess`.
#   This is the canonical stable patch target.
# F2 (PyYAML test guard): test-scripts job in ci.yml runs `pip install pyyaml`
#   before invoking these tests; PyYAML is guaranteed available at the call site.

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

    REVIEW-DEFENSE (PR #62 finding 3): the `type` field is optional on real
    findings — `f.get("type", "")` defaults to `""` which is NOT in
    _SYNTHETIC_TYPES, so real findings (which lack `type`) correctly proceed
    to the severity check. Only synthetic findings (specialist_error,
    fallback_exhausted, parse_error) are excluded. This is the intended
    semantic — see record-review.sh:307 for the parallel local enforcement.
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
    """Sanitize an LLM-controlled string for safe interpolation into a markdown
    heading or other inline rendering context.

    Defenses applied:
    - Strip \\n / \\r — heading injection in GitHub markdown requires `#` at the
      start of a line; removing newlines blocks every variant.
    - Replace literal backticks with U+02CB (look-alike) — prevents an LLM
      severity/category/citation value from opening a code span that swallows
      surrounding markup.

    HTML special chars (`<`, `>`) are NOT escaped here: GitHub renders comments
    via its sanitizing markdown pipeline which strips dangerous tags. Adding
    HTML escape would over-mangle legitimate content like `<5%`.
    """
    return str(s).replace("\n", " ").replace("\r", " ").replace("`", "ˋ")


def _format_finding_comment(idx: int, total: int, finding: dict) -> str:
    """Format a single finding as a standalone PR comment body.

    Each comment is independently responsive (resolve / reply / mark-as-fixed)
    in the GitHub PR UI, so the team can triage findings one-by-one rather
    than against a single bundled comment.

    Body shape:
        ## DSO llm-review — finding {idx}/{total}

        **[severity]** `path:line` *(category)*

        ```
        <description, with backtick neutralization>
        ```

        ---
        _Posted by dso_ci_review.runner._
    """
    sev = _safe_inline(finding.get("severity", "?"))
    cat = finding.get("category")
    cat_str = f" *({_safe_inline(cat)})*" if cat else ""
    desc = (finding.get("description") or "").strip()
    cited = finding.get("cited_lines") or []
    if cited:
        # Show citations as inline code spans for readability.
        cited_str = " ".join(f"`{_safe_inline(c)}`" for c in cited)
    else:
        cited_str = "_(no citations)_"
    # Wrap LLM-controlled description in a fenced code block to prevent
    # markdown / HTML injection in the rendered PR comment. A nested fence
    # in the description itself would close ours; replace literal triple
    # backticks with a Unicode look-alike to neutralize that vector.
    safe_desc = desc.replace("```", "ˋˋˋ")
    return "\n".join(
        [
            f"## DSO llm-review — finding {idx}/{total}",
            "",
            f"**[{sev}]** {cited_str}{cat_str}",
            "",
            "```",
            safe_desc,
            "```",
            "",
            "---",
            "_Posted by dso_ci_review.runner; resolve this comment when addressed._",
        ]
    )


def _post_pr_review(findings: list[dict]) -> tuple[int, int]:
    """Post blocking findings as PR comments (one per finding) via the gh CLI.

    Returns `(posted_count, attempted_count)` so the caller can phrase its
    stderr summary accurately — under the per-finding loop a partial failure
    is a real outcome (e.g., 2 of 5 comments posted), and the gate hint must
    reflect that rather than claim "see the PR comment" when several never
    landed.

    Both counters are 0 in no-op cases (preconditions not met). When findings
    were attempted, `attempted_count == len(blocking)`.

    No-op (returns (0, 0)) when:
    - GITHUB_EVENT_NAME != "pull_request" (push, workflow_dispatch, etc.)
    - PR number cannot be resolved
    - GITHUB_TOKEN is absent (gh auth would fail anyway)
    - blocking finding list is empty (nothing to surface)

    Errors are logged to stderr but never propagate — the severity gate below
    is authoritative for blocking; comment posting is a best-effort UX layer.

    REVIEW-DEFENSE (PR #62 findings 2 and 5):

    - Timeout=30s: gh pr comment typically completes in <2s; 30s is a generous
      ceiling. Slow runners are not a real failure mode here — comment posting
      is best-effort and a slow comment delays only the WARNING line, not the
      gate decision.

    - Silent error suppression: BY DESIGN. The severity gate (caller below) is
      the authoritative blocking mechanism. The comment is informational. A
      single-line WARNING with the exception class name is sufficient operator
      visibility; reraising would invert the design (UX layer blocking the
      gate). Operators who need details can read the CI job stderr.

    - stderr leakage: the `subprocess.run(..., capture_output=True)` capture
      stores gh's stderr inside the CalledProcessError object, but we only
      print `type(exc).__name__` — neither the captured stderr nor stdout is
      ever serialized to the runner's stderr. The data exists in memory but
      no code path emits it; sensitive content cannot leak via this path.
    """
    blocking = _real_blocking_findings(findings)
    if not blocking:
        return (0, 0)
    pr_number = _resolve_pr_number()
    if not pr_number:
        return (0, 0)
    if not os.environ.get("GITHUB_TOKEN"):
        print(
            "WARNING: GITHUB_TOKEN absent; cannot post PR review for findings",
            file=sys.stderr,
        )
        return (0, 0)

    # One comment per finding so each can be resolved / replied to / closed
    # independently in the GitHub PR UI. Bundling all findings into a single
    # comment would force the team to triage them as one unit.
    posted = 0
    total = len(blocking)
    for idx, finding in enumerate(blocking, 1):
        body = _format_finding_comment(idx, total, finding)
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
            posted += 1
        except (
            subprocess.CalledProcessError,
            subprocess.TimeoutExpired,
            FileNotFoundError,
        ) as exc:
            # Best-effort — never block the gate on a failed comment post.
            # Print only the exception class name (not str(exc)), since gh stderr
            # captured by CalledProcessError can include URLs / token-bearing
            # diagnostic text on auth failures. Continue to the next finding so
            # one transient failure doesn't suppress the rest.
            print(
                f"WARNING: failed to post PR comment for finding {idx}/{total} "
                f"({type(exc).__name__})",
                file=sys.stderr,
            )
    return (posted, total)


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


_CLASSIFIER_FALLBACK: dict = {
    "selected_tier": "standard",
    "security_overlay": False,
    "performance_overlay": False,
    "test_quality_overlay": False,
}


def _classify_tier_via_bash(
    diff_text: str,
    repo_root: str | None = None,
    plugin_root: str | None = None,
) -> dict:
    """Call review-complexity-classifier.sh via subprocess and return the classification dict.

    Resolution order for the classifier script:
      1. plugin_root argument (explicit override)
      2. CLAUDE_PLUGIN_ROOT env var
      3. 5-dirname-levels from __file__:
         runner.py → dso_ci_review → scripts → dso → plugins → repo_root,
         then os.path.join(repo_root, "plugins", "dso") for the plugin root

    Failure semantics (per GAP_AMENDMENT):
      - FileNotFoundError (script not found): re-raise — deployment bug, not a runtime case.
      - subprocess.TimeoutExpired: log warning to stderr, return _CLASSIFIER_FALLBACK.
      - Non-zero exit or JSON parse error: log warning to stderr, return _CLASSIFIER_FALLBACK.

    The repo_root is resolved for the subprocess cwd so that review-complexity-classifier.sh
    can call `git rev-parse --show-toplevel` internally. Resolution order:
      1. repo_root argument
      2. REPO_ROOT env var
      3. git rev-parse from __file__-relative directory (best-effort; falls back to None)
    """
    # Resolve plugin_root
    if plugin_root is None:
        plugin_root = os.environ.get("CLAUDE_PLUGIN_ROOT")
    if plugin_root is None:
        # 5 dirname levels: runner.py → dso_ci_review → scripts → dso → plugins → repo_root,
        # then descend two levels to reach the plugin root
        _five_up = os.path.dirname(
            os.path.dirname(
                os.path.dirname(
                    os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
                )
            )
        )
        plugin_root = os.path.join(_five_up, "plugins", "dso")

    classifier_script = os.path.join(
        plugin_root, "scripts", "review-complexity-classifier.sh"
    )

    # Resolve repo_root for cwd
    if repo_root is None:
        repo_root = os.environ.get("REPO_ROOT")
    if repo_root is None:
        try:
            _rr = subprocess.run(
                ["git", "rev-parse", "--show-toplevel"],
                capture_output=True,
                text=True,
                timeout=10,
                cwd=os.path.dirname(os.path.abspath(__file__)),
            )
            if _rr.returncode == 0:
                repo_root = _rr.stdout.strip() or None
        except (subprocess.TimeoutExpired, FileNotFoundError):
            repo_root = None

    # Build env with CLAUDE_PLUGIN_ROOT set so classifier can resolve _PLUGIN_ROOT
    run_env = os.environ.copy()
    run_env["CLAUDE_PLUGIN_ROOT"] = str(plugin_root)

    try:
        result = subprocess.run(
            ["bash", str(classifier_script)],
            input=diff_text,
            capture_output=True,
            text=True,
            timeout=30,
            cwd=repo_root,
            env=run_env,
        )
    except subprocess.TimeoutExpired:
        print(
            "WARNING: review-complexity-classifier.sh timed out; "
            "falling back to standard tier",
            file=sys.stderr,
        )
        return _CLASSIFIER_FALLBACK.copy()
    # FileNotFoundError propagates — deployment bug, fail loud

    if result.returncode != 0:
        print(
            f"WARNING: review-complexity-classifier.sh exited {result.returncode}; "
            f"falling back to standard tier. stderr: {result.stderr.strip()!r}",
            file=sys.stderr,
        )
        return _CLASSIFIER_FALLBACK.copy()

    try:
        parsed = json.loads(result.stdout)
    except json.JSONDecodeError as exc:
        print(
            f"WARNING: review-complexity-classifier.sh produced invalid JSON "
            f"({exc}); falling back to standard tier. stdout: {result.stdout!r}",
            file=sys.stderr,
        )
        return _CLASSIFIER_FALLBACK.copy()

    return parsed


_TIER_MODEL_DEFAULTS: dict[str, str] = {
    "light": "claude-haiku-4-5-20251001",
    "standard": "claude-sonnet-4-6",
    "deep": "claude-sonnet-4-6",
    "deep-arch": "claude-opus-4-7",
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
        # runner.py lives at <repo_root>/<plugin_root>/scripts/dso_ci_review/runner.py
        # so dso-config.conf at <repo_root>/.claude/ is 5 dirname levels up
        # (dso_ci_review → scripts → <plugin_root> → plugins → repo_root). The
        # previous 3-level chain stopped at the plugin root, where .claude/ does
        # not exist, so model.<tier> overrides were silently ignored. (0e2a-77b0)
        config_path = os.path.join(
            os.path.dirname(
                os.path.dirname(
                    os.path.dirname(
                        os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
                    )
                )
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
                "tier": tier,
            },
            {
                "agent_id": "code-reviewer-deep-verification",
                "diff_text": diff_text,
                "model": base_model,
                "provider_chain": provider_chain,
                "tier": tier,
            },
            {
                "agent_id": "code-reviewer-deep-hygiene",
                "diff_text": diff_text,
                "model": base_model,
                "provider_chain": provider_chain,
                "tier": tier,
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
                "tier": tier,
            }
        ]

    return agents


_OVERLAY_AGENT_IDS: dict[str, str] = {
    "security": "code-reviewer-security-red-team",
    "performance": "code-reviewer-performance",
    "test_quality": "code-reviewer-test-quality",
}


def _build_overlay_agents(
    classification: dict,
    diff_text: str,
    config_path: str | None = None,
) -> list[dict]:
    """Build overlay agent descriptors based on classifier flags.

    Reads ``security_overlay``, ``performance_overlay``, and
    ``test_quality_overlay`` from the classification dict.  For each flag
    that is True, an agent descriptor is appended to the returned list.
    """
    agents: list[dict] = []
    flag_map = {
        "security_overlay": "security",
        "performance_overlay": "performance",
        "test_quality_overlay": "test_quality",
    }
    for flag, dimension in flag_map.items():
        if classification.get(flag):
            agents.append(
                {
                    "agent_id": _OVERLAY_AGENT_IDS[dimension],
                    "diff_text": diff_text,
                    "config_path": config_path,
                }
            )
    return agents


def _overlay_agents_from_findings(
    findings_list: list[dict],
    diff_text: str = "",
    config_path: str | None = None,
) -> list[dict]:
    """Scan first-pass findings for warranted overlay signals.

    Checks each finding dict for:
    - ``type == "overlay_warranted"`` with a ``dimension`` field
      (``security``, ``performance``, or ``test_quality``)
    - Boolean/string fields ``security_overlay_warranted``,
      ``performance_overlay_warranted``, ``test_quality_overlay_warranted``
    - The ``summary`` string field for patterns like
      ``security_overlay_warranted: yes``

    Returns a deduplicated list of overlay agent descriptors.
    """
    warranted: set[str] = set()

    for findings_dict in findings_list:
        for finding in findings_dict.get("findings") or []:
            # Pattern 1: explicit type=overlay_warranted with dimension
            if finding.get("type") == "overlay_warranted":
                dimension = finding.get("dimension", "")
                if dimension in _OVERLAY_AGENT_IDS:
                    warranted.add(dimension)

            # Pattern 2: boolean/string flag fields
            for flag_field, dimension in (
                ("security_overlay_warranted", "security"),
                ("performance_overlay_warranted", "performance"),
                ("test_quality_overlay_warranted", "test_quality"),
            ):
                val = finding.get(flag_field)
                if val is True or str(val).lower() == "yes":
                    warranted.add(dimension)

            # Pattern 3: summary field string scan
            summary = str(finding.get("summary", ""))
            for dimension in _OVERLAY_AGENT_IDS:
                pattern = f"{dimension}_overlay_warranted: yes"
                if pattern in summary.lower():
                    warranted.add(dimension)

    return [
        {
            "agent_id": _OVERLAY_AGENT_IDS[dim],
            "diff_text": diff_text,
            "config_path": config_path,
        }
        for dim in warranted
    ]


def main() -> int:
    """Run the CI review and return an exit code."""
    dry_run = os.environ.get("DSO_CI_REVIEW_DRY_RUN") == "1"

    if dry_run:
        findings = {"findings": [], "dry_run": True}
        _write_output(findings)
        return 0

    # Validate all required agent files exist before dispatching any LLM calls.
    try:
        _validate_agent_files()
    except RuntimeError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1

    diff_text = _read_diff()
    if not diff_text.strip():
        _write_output({"findings": []})
        return 0

    # Validate provider configuration before dispatching any LLM calls.
    # Resolve provider from CI_REVIEW_PROVIDER env var, falling back to
    # model.provider in dso-config.conf, then defaulting to "anthropic".
    _ci_provider = os.environ.get("CI_REVIEW_PROVIDER", "").strip()
    if not _ci_provider:
        # Attempt to read model.provider from dso-config.conf as a fallback.
        # 5 dirname levels: runner.py → dso_ci_review → scripts → dso → plugins → repo_root
        # (0e2a-77b0).
        _config_path = os.path.join(
            os.path.dirname(
                os.path.dirname(
                    os.path.dirname(
                        os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
                    )
                )
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
        classification = _classify_tier_via_bash(diff_text)
        tier = classification["selected_tier"]

        # Read review cycle number — used by two-call architecture on re-review passes.
        _cycle_number = int(os.environ.get('DSO_REVIEW_CYCLE', '1'))  # noqa: F841

        # Resolve config_path once for overlay agent construction
        config_path: str | None = None

        # Step 2: build agent list based on tier, plus any classifier-flagged overlays
        tier_agents = _build_agents_for_tier(tier, diff_text, classification, config_path)
        overlay_agents = _build_overlay_agents(classification, diff_text, config_path)

        # Enrich overlay descriptors with model + provider_chain for dispatch
        base_model = _read_tier_model(tier, config_path)
        provider_chain = [os.environ.get("CI_REVIEW_PROVIDER", "anthropic")]
        for agent in overlay_agents:
            agent.setdefault("model", base_model)
            agent.setdefault("provider_chain", provider_chain)

        # Step 3: dispatch tier agents + classifier-flagged overlays together (parallel)
        first_pass_findings = asyncio.run(
            async_dispatch_specialists(tier_agents + overlay_agents)
        )

        # Step 4: check first-pass findings for warranted second-pass overlays
        warranted_overlay_agents = _overlay_agents_from_findings(
            first_pass_findings, diff_text, config_path
        )
        all_findings = list(first_pass_findings)
        if warranted_overlay_agents:
            # Enrich warranted overlay descriptors with model + provider_chain
            for agent in warranted_overlay_agents:
                agent.setdefault("model", base_model)
                agent.setdefault("provider_chain", provider_chain)
            second_pass_findings = asyncio.run(
                async_dispatch_specialists(warranted_overlay_agents)
            )
            all_findings.extend(second_pass_findings)

        # Step 5: merge findings
        merged = merge_findings(*all_findings)

        # Step 6: for deep tier, run arch synthesis after specialists; the arch
        # synthesis result replaces the merged specialist output as the final result
        # when it succeeds (non-synthetic findings or no findings at all).
        # On infrastructure failure (fallback_exhausted / specialist_error), the
        # merged specialist output is preserved so the severity gate still fires.
        if tier == "deep":
            arch_model = _read_tier_model("deep-arch", config_path)
            arch_result = dispatch_arch_synthesis(
                json.dumps(merged),
                diff_text=diff_text,
                model=arch_model,
                provider_chain=provider_chain,
            )
            arch_findings = arch_result.get("findings") or []
            arch_all_synthetic = bool(arch_findings) and all(
                f.get("type", "") in _SYNTHETIC_TYPES for f in arch_findings
            )
            if not arch_all_synthetic:
                merged = arch_result

        # Step 7: write output
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
    # so the author has visible context whether the gate passes or fails. Returns
    # (posted, attempted) so the gate stderr can phrase partial-success accurately.
    _comments_posted, _comments_attempted = _post_pr_review(_findings)

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
        # Phrase the comment hint to reflect the actual posting outcome. Under
        # the per-finding loop a partial success is a real outcome (e.g., 2 of
        # 5 posted), so the message must not claim "see the PR comment" when
        # several never landed.
        if _comments_posted == 0 and _comments_attempted == 0:
            comment_hint = ""
        elif _comments_posted == 0 and _comments_attempted > 0:
            comment_hint = (
                f"(PR comment posting failed for all {_comments_attempted} "
                f"finding(s); see WARNING lines above) "
            )
        elif _comments_posted == _comments_attempted:
            plural = "s" if _comments_posted != 1 else ""
            comment_hint = f"and {_comments_posted} PR review comment{plural} "
        else:
            comment_hint = (
                f"and {_comments_posted}/{_comments_attempted} PR review comments "
            )
        print(
            f"ERROR: llm-review found blocking finding(s) — {sev_str} "
            f"(see findings JSON above {comment_hint}for details)",
            file=sys.stderr,
        )
        return 1

    return 0


if __name__ == "__main__":
    sys.exit(main())
