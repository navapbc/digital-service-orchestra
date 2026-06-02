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
import hashlib
import json  # used by _validate_findings_schema (json.dump to tmpfile)
import os
import re
import subprocess
import sys
import tempfile
from typing import Literal, NamedTuple

from dso_ci_review.dispatch import (
    _FINDING_ID_RE,
    async_dispatch_specialists,
    _validate_agent_files,
    dispatch_arch_synthesis,
    dispatch_schema_correction,
    dispatch_two_call_review,
)
from dso_ci_review._config import default_config_path, read_config_int
from dso_ci_review.cycle_dispatcher import next_action as cycle_next_action
from dso_ci_review.cycle_ledger import (
    read_ledger as _read_cycle_ledger,
    append_cycle as _append_cycle,
    _resolve_artifacts_dir as _ledger_artifacts_dir,
    _SENTINEL_PR_NUMBER,
)
from dso_ci_review.findings import merge_findings, _parse_line_range
from dso_ci_review.providers.config import AuthError, ConfigError, get_provider
from dso_ci_review.proximity import compute_proximity_overlap, validate_escape_rationale
from dso_ci_review.dispatch_ratelimit import DispatchContext
from dso_ci_review.region_split import (
    _cluster_concurrency,
    run_region_split_strategy_f,
)
from dso_ci_review import cycle_ledger
from dso_ci_review.arbiter import dispatch_cycle_end_arbiter
from dso_ci_review.arbiter_processor import process_rulings
from dso_ci_review.cycle_marker_format import (
    cycle_dedup_key,
    format_arbiter_marker,
    format_cycle_marker,
)
from dso_ci_review.file_filter import (
    filter_files as _filter_files,
    load_filter_config as _load_filter_config,
)
from dso_ci_review.aggregator import (
    aggregate_cluster_findings as _aggregate_cluster_findings,
)
from dso_ci_review.telemetry_emit_wrapper import emit_event as _telemetry_emit


# ── Telemetry schema enum normalisers ─────────────────────────────────────────
# The canonical lambda-handler schema enforces per_type_field enums on every
# review_finding / tool_finding emit. LLM reviewers occasionally produce
# off-enum severity labels (e.g. "high", "medium") or off-enum categories
# (e.g. "performance") that would otherwise be rejected at the Lambda
# validator with HTTP 400. These normalisers map common variants to the
# canonical enum and fall back to a safe default for unknown values so a
# malformed reviewer payload still produces a valid telemetry envelope.
_REVIEW_SEVERITY_ENUM = ("critical", "important", "minor", "suggestion")
_REVIEW_SEVERITY_ALIASES = {
    "high": "important",
    # "fragile" is a DSO-internal severity emitted by every reviewer agent
    # (see ${CLAUDE_PLUGIN_ROOT}/agents/code-reviewer-*.md) for findings that
    # need a reachability statement. The Lambda canonical enum does not
    # include "fragile"; map it to "important" to preserve the warning
    # weight rather than silently downgrading into the minor noise.
    "fragile": "important",
    "medium": "minor",
    "low": "minor",
    "info": "suggestion",
    "informational": "suggestion",
}
_REVIEW_CATEGORY_ENUM = (
    "correctness",
    "design",
    "hygiene",
    "maintainability",
    "verification",
)
_REVIEW_CATEGORY_ALIASES = {
    "performance": "correctness",
    "security": "correctness",
    "style": "hygiene",
    "documentation": "maintainability",
    "test": "verification",
    "tests": "verification",
}
_TOOL_SEVERITY_FROM_REVIEW = {
    "critical": "error",
    "important": "warning",
    "minor": "info",
    "suggestion": "info",
}


def _normalise_review_severity(raw: object) -> str:
    """Map a finding's severity to the canonical review-finding enum.

    Falls back to "minor" for unknown / missing values so an off-spec reviewer
    payload still produces a schema-valid emit (the Lambda would otherwise
    reject the event entirely).
    """
    if not isinstance(raw, str):
        return "minor"
    raw_lower = raw.lower().strip()
    if raw_lower in _REVIEW_SEVERITY_ENUM:
        return raw_lower
    return _REVIEW_SEVERITY_ALIASES.get(raw_lower, "minor")


def _normalise_review_category(raw: object) -> str:
    """Map a finding's category to the canonical review-finding enum.

    Falls back to "correctness" for unknown / missing values.
    """
    if not isinstance(raw, str):
        return "correctness"
    raw_lower = raw.lower().strip()
    if raw_lower in _REVIEW_CATEGORY_ENUM:
        return raw_lower
    return _REVIEW_CATEGORY_ALIASES.get(raw_lower, "correctness")


def _normalise_tool_severity(raw: object) -> str:
    """Map a review-side severity to the tool_finding 3-bucket enum
    (error / warning / info). Unknown inputs fall back to "info".
    """
    if not isinstance(raw, str):
        return "info"
    return _TOOL_SEVERITY_FROM_REVIEW.get(raw.lower().strip(), "info")


def _format_merged_for_arch(merged: dict) -> str:
    """Format the merged-specialist findings for ``dispatch_arch_synthesis``.

    The ``dso:code-reviewer-deep-arch`` agent's Sonnet Findings Guard
    requires three explicit markers in its dispatch prompt:

      === SONNET-A FINDINGS (correctness) ===
      === SONNET-B FINDINGS (verification) ===
      === SONNET-C FINDINGS (hygiene/design) ===

    Without all three markers the agent refuses to proceed and returns a
    prose refusal that downstream JSON parsing rejects as ValueError
    (observed in CI on PR #448 — bug 7f55 / f148 follow-up). Partition
    findings by category (defaulting unknowns to "correctness", matching
    ``_normalise_review_category``) and emit each section's findings as a
    JSON array under its required marker. Empty categories still get
    their marker plus an empty array — the guard checks for the marker
    string, not for content.
    """
    findings: list[dict] = list(merged.get("findings") or [])
    a_findings: list[dict] = []
    b_findings: list[dict] = []
    c_findings: list[dict] = []
    for f in findings:
        if not isinstance(f, dict):
            continue
        category = _normalise_review_category(f.get("category"))
        if category == "verification":
            b_findings.append(f)
        elif category in {"hygiene", "design", "maintainability"}:
            c_findings.append(f)
        else:
            a_findings.append(f)
    return (
        "=== SONNET-A FINDINGS (correctness) ===\n"
        + json.dumps(a_findings, indent=2)
        + "\n\n=== SONNET-B FINDINGS (verification) ===\n"
        + json.dumps(b_findings, indent=2)
        + "\n\n=== SONNET-C FINDINGS (hygiene/design) ===\n"
        + json.dumps(c_findings, indent=2)
    )


# Finding `type` values that correspond to operational/tool emits rather than
# real LLM review findings. Used by _emit_finding_telemetry below to route
# each finding to the correct event_type.
_TOOL_FINDING_TYPES = frozenset(
    {"specialist_error", "fallback_exhausted", "parse_error", "tool_finding"}
)


def _emit_finding_telemetry(
    finding: dict,
    finding_idx: int,
    cycle_number: int,
    emit_fn=None,
) -> None:
    """Emit one telemetry event per review finding.

    Dispatches to ``tool_finding`` for operational/specialist-meta finding
    types (lint/type/syntax/infra/specialist-meta) and ``review_finding`` for
    real LLM review findings. Severity / category values flow through the
    canonical enum normalisers so an off-spec reviewer payload still produces
    a schema-valid emit.

    ``emit_fn`` is injectable for tests; defaults to the module-level
    ``_telemetry_emit`` (which is ``telemetry_emit_wrapper.emit_event``).
    """
    if emit_fn is None:
        emit_fn = _telemetry_emit
    f_type = finding.get("type", "")
    f_file = finding.get("file", "")
    f_lines = finding.get("cited_lines", []) or []
    f_desc = finding.get("description", "") or finding.get("message", "")
    if f_type in _TOOL_FINDING_TYPES:
        # tool_finding event — schema requires: tool_name, tool_rule,
        # tool_severity, file, message.
        emit_fn(
            "tool_finding",
            tool_name="dso-llm-review",
            tool_rule=f_type,
            tool_severity=_normalise_tool_severity(finding.get("severity")),
            file=f_file,
            message=f_desc or f_type,
            cycle=cycle_number,
        )
    else:
        # review_finding event — schema requires: finding_id, severity,
        # category, description, file, cited_lines. Use the parent-generated
        # key path so the event_id stays linkable from arbiter_ruling emits.
        emit_fn(
            "review_finding",
            key=f"dso-llm:{cycle_number}:{finding_idx}",
            cycle=cycle_number,
            finding_id=finding.get(
                "finding_id", f"unknown-{cycle_number}-{finding_idx}"
            ),
            severity=_normalise_review_severity(finding.get("severity")),
            category=_normalise_review_category(finding.get("category")),
            description=f_desc,
            file=f_file,
            cited_lines=f_lines,
        )


def _emit_review_cycle_telemetry(
    findings: list[dict],
    cycle_number: int,
    tier: str,
    reviewed_sha: str,
    usage_input_tokens: int | None = None,
    usage_output_tokens: int | None = None,
    emit_fn=None,
) -> None:
    """Emit the per-cycle ``review_cycle`` aggregate event.

    Schema requires: cycle_number, tier, finding_count, critical_count,
    important_count, minor_count, pass, resolution_attempts, diff_hash.
    Counts are derived from the verifier-filtered ``findings`` list; ``pass``
    is True when no critical/important remain. ``input_tokens`` /
    ``output_tokens`` are additive-optional and only added when usage data was
    aggregated from review-cycle-usage.json. ``resolution_attempts`` = max(0,
    cycle_number - 1) since each prior cycle counted as a resolution attempt.

    ``emit_fn`` is injectable for tests; defaults to the module-level
    ``_telemetry_emit``.
    """
    if emit_fn is None:
        emit_fn = _telemetry_emit
    critical_count = sum(1 for f in findings if f.get("severity") == "critical")
    important_count = sum(1 for f in findings if f.get("severity") == "important")
    minor_count = sum(
        1 for f in findings if f.get("severity") in ("minor", "suggestion")
    )
    kwargs: dict = {
        "cycle": cycle_number,
        "cycle_number": cycle_number,
        "tier": tier,
        "finding_count": len(findings),
        "critical_count": critical_count,
        "important_count": important_count,
        "minor_count": minor_count,
        "pass": (critical_count == 0 and important_count == 0),
        "resolution_attempts": max(0, cycle_number - 1),
        "diff_hash": reviewed_sha,
    }
    if usage_input_tokens is not None:
        kwargs["input_tokens"] = usage_input_tokens
    if usage_output_tokens is not None:
        kwargs["output_tokens"] = usage_output_tokens
    emit_fn("review_cycle", **kwargs)


class _SchemaValidationResult(NamedTuple):
    """Result of schema validation for merged review findings.

    status values:
      "schema_pass"      — findings conform to the code-review-dispatch schema
      "schema_fail"      — findings violate the schema (S-B correction handoff point)
      "validator_error"  — infrastructure failure (ENOENT, timeout, unrecognized exit)
    errors: empty on schema_pass; schema error lines on schema_fail;
            diagnostic message on validator_error.
    """

    status: Literal["schema_pass", "schema_fail", "validator_error"]
    errors: list[str]


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
# fragile is treated identically to important per CLAUDE.md `rule:severity-override` / reviewer-base.md.
_BLOCKING_SEVERITIES = frozenset({"critical", "important", "fragile"})

# Synthetic finding types — produced by infrastructure failures, not real review work.
# These carry a severity field for schema conformance but must not count toward the
# severity gate (the all-specialist-errors check below handles infra failures separately).
_SYNTHETIC_TYPES = frozenset({"specialist_error", "fallback_exhausted", "parse_error"})

# ---------------------------------------------------------------------------
# Large-diff pipeline — OVER_BOUND status and config validation
# ---------------------------------------------------------------------------

# Status string emitted when the cluster × call budget is exceeded.
# Distinct from FP-suspected, BLOCK, etc. Routed to admin/FP-recovery by T8.
OVER_BOUND = "OVER_BOUND"


def _validate_large_diff_config(config: dict) -> None:
    """Validate large-diff pipeline config values; emit warnings or raise.

    Rules (per DD1 / AC amendment F6):
      - max_files=0 → emit warning to stderr; do NOT raise.
      - max_calls=0 → emit warning to stderr; do NOT raise.
      - ignore.glob empty → emit warning to stderr; do NOT raise.
      - max_calls < max_files + 1 → raise ValueError (one aggregation pass
        requires at least max_files dispatches + 1 synthesis call).

    Args:
        config: dict from _load_filter_config() or equivalent.
    """
    max_files = config.get("max_files")
    max_calls = config.get("max_calls")
    ignore_globs = config.get("ignore_globs", [])

    if max_files == 0:
        print(
            "WARNING: review.large_diff.max_files=0 disables chunking; "
            "reviews on oversized diffs will fail open",
            file=sys.stderr,
        )
    if max_calls == 0:
        print(
            "WARNING: review.large_diff.max_calls=0 disables chunking; "
            "reviews on oversized diffs will fail open",
            file=sys.stderr,
        )
    if not ignore_globs:
        print(
            "WARNING: review.large_diff.ignore.glob empty; consider defaults",
            file=sys.stderr,
        )

    # F6 constraint: max_calls must accommodate at least (max_files dispatches
    # + 1 aggregation call). Only enforced when both values are explicitly set
    # and non-zero.
    if (
        max_files is not None
        and max_calls is not None
        and max_files > 0
        and max_calls > 0
        and max_calls < max_files + 1
    ):
        raise ValueError(
            f"review.large_diff config invalid: max_calls ({max_calls}) must be "
            f">= max_files + 1 ({max_files + 1}); one aggregation pass requires "
            f"at least max_files={max_files} dispatches plus 1 synthesis call."
        )


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


# ---------------------------------------------------------------------------
# Component #3' — filter-before-split (R-1) and fallback re-chunk (R-2) helpers
# ---------------------------------------------------------------------------


def _partition_reviewable_files(
    diff_text: str, config: dict
) -> tuple[list[str], list[tuple[str, str]]]:
    """Compute the reviewable / skipped file sets for a diff ONCE, upstream of
    the should_split decision (component #3' R-1).

    The same partition feeds BOTH the gate decision (via
    ``_should_region_split_on_files``) and, when the chunked path runs, the
    dispatch filtering. This eliminates the previous asymmetry where the
    generated/binary file-filter only ran inside the chunked branch — so a
    generated-heavy diff that reviews single-pass now still has its generated
    files filtered out of scope.

    The diff TEXT is NOT mutated: only the file path sets are derived. This
    preserves the OVER_BOUND budget math and the visibility trailer's
    skipped-file list, which depend on the unmodified diff.

    Returns the (reviewable, skipped_with_reasons) tuple from
    ``file_filter.filter_files``.
    """
    from dso_ci_review.region_split import (
        _extract_filenames as _rs_extract_filenames,
    )  # noqa: PLC0415

    all_files = _rs_extract_filenames(diff_text)
    reviewable, skipped = _filter_files(all_files, config=config)
    return reviewable, skipped


def _should_region_split_on_files(
    diff_text: str, reviewable_files: list[str]
) -> bool:
    """Region-split GATE decision computed against the FILTERED reviewable set
    (component #3' R-1).

    The LOC component still uses the full diff text (LOC accounting is
    text-derived and the diff is not mutated), but the file-count component is
    measured on the reviewable set so generated/binary files that will be
    filtered out of scope do not push a diff over the file-count gate.

    The single-file atomicity floor (bug 532e-6ab7) is honored: a reviewable
    set of <= 1 file never region-splits.
    """
    from dso_ci_review.region_split import (
        _gate_file_count_threshold,
        _gate_loc_threshold,
    )  # noqa: PLC0415

    # File-atomicity floor on the reviewable set (bug 532e-6ab7): never
    # region-split when one or zero reviewable files remain after filtering.
    if len(set(reviewable_files)) <= 1:
        return False

    # File-count gate measured on the FILTERED reviewable set, so generated /
    # binary files (which will be filtered out of dispatch scope) cannot push
    # the diff over the file-count gate.
    if len(set(reviewable_files)) > _gate_file_count_threshold():
        return True

    # LOC gate: text-derived from the (unmutated) diff. The diff is not
    # rewritten — filtered files still contribute to the raw LOC count, which is
    # acceptable because the LOC gate is a context-pressure proxy and the
    # threshold (~20000) is far above any realistic generated-file inflation;
    # mutating the diff to exclude them would drift the OVER_BOUND budget math
    # (R-1 constraint). The single-reviewable-file floor above already prevents
    # a single huge real file from chunking.
    loc_count = 0
    for line in diff_text.splitlines():
        if line.startswith("+") and not line.startswith("+++"):
            loc_count += 1
        elif line.startswith("-") and not line.startswith("---"):
            loc_count += 1
    return loc_count > _gate_loc_threshold()


def _result_has_fallback_exhausted(result: dict) -> bool:
    """Return True when a single-pass review result carries a
    ``fallback_exhausted`` synthetic finding (component #3' R-2).

    ``fallback_exhausted`` is the surfaced form of a swallowed
    ``ContextWindowExceededError`` (dispatch.py): the exception is caught inside
    the dispatch fallback chain and only re-emerges as this sentinel finding, so
    a try/except at the dispatch call site would catch nothing. Detecting the
    sentinel in the result is the only reliable signal that a token-dense diff
    slipped the LOC gate and exhausted the single-pass context chain.
    """
    for f in result.get("findings") or []:
        if isinstance(f, dict) and f.get("type") == "fallback_exhausted":
            return True
    return False


def _rechunk_on_fallback_exhausted(
    result: dict, diff_text: str
) -> list[dict] | None:
    """If a single-pass result is a context-exhaustion sentinel, re-route the
    diff to the chunked path (component #3' R-2).

    Returns the Strategy-F dispatch specs when a re-chunk is triggered, or
    ``None`` when no re-chunk should occur. The caller is responsible for
    dispatching/aggregating the returned specs in place of emitting the
    synthetic ``fallback_exhausted`` finding.

    A re-chunk is triggered only when BOTH hold:
      1. the result carries a ``fallback_exhausted`` sentinel, AND
      2. Strategy F actually partitions the diff into MORE than one cluster.

    Condition (2) is the discriminator between the two failure modes a
    ``fallback_exhausted`` sentinel can represent:
      - A token-dense diff that slipped the LOC gate — chunking yields >1
        cluster, so re-chunking genuinely reduces per-call context. RE-CHUNK.
      - A single-file (or otherwise un-partitionable) diff that exhausted
        context — Strategy F returns one cluster covering the same file, so
        re-dispatching it is identical to the failed single-pass review and
        would loop. This is a true infrastructure failure; leave the sentinel
        in place so the all-synthetic infra-failure gate fires. NO re-chunk.
    """
    if not _result_has_fallback_exhausted(result):
        return None
    specs = run_region_split_strategy_f(diff_text=diff_text)
    if len(specs) <= 1:
        return None
    return specs


# ---------------------------------------------------------------------------
# Cycle-ledger helpers (Step 8a / Step 8b)
# ---------------------------------------------------------------------------


def _init_cycle_ledger(
    artifacts_dir: str,
    pr_number: str | None,
    repo: str | None,
) -> tuple[dict, int]:
    """Load (or reconstruct) the cycle ledger and return (ledger, cycle_number).

    Resolution order:
      1. Read cycle-ledger.json from artifacts_dir.
      2. If empty and pr_number+repo are available, reconstruct from PR comments.
    """
    ledger_path = os.path.join(artifacts_dir, "cycle-ledger.json")
    ledger = _read_cycle_ledger(ledger_path)

    # Reconstruct from PR comments if ledger is empty and context is available.
    if not ledger.get("cycles") and pr_number and repo:
        from dso_ci_review.cycle_ledger import reconstruct_from_pr_comments  # noqa: PLC0415

        ledger = reconstruct_from_pr_comments(int(pr_number), repo)

    # Derive cycle_number from ledger (ledger is authoritative per cycle_dispatcher).
    # Filter to cycles belonging to this pr_number. v1.1.0 sentinel entries
    # (pr_number=_SENTINEL_PR_NUMBER=0) match any pr_number for backward-compat
    # until superseded by a v1.2.0 entry for that specific pr_number.
    cycles = ledger.get("cycles", [])
    if pr_number is not None:
        pr_num_int = int(pr_number)
        matching = [
            c
            for c in cycles
            if isinstance(c, dict)
            and (
                c.get("pr_number") == pr_num_int
                or c.get("pr_number") == _SENTINEL_PR_NUMBER
            )
        ]
    else:
        matching = [c for c in cycles if isinstance(c, dict)]
    if matching and "cycle_num" in matching[-1]:
        cycle_number = matching[-1]["cycle_num"] + 1
    else:
        cycle_number = int(os.environ.get("DSO_REVIEW_CYCLE", "1"))

    return ledger, cycle_number


def _resolve_max_cycles(config_path: str | None = None) -> int:
    """Read review.max_cycles from dso-config.conf (default: 3)."""
    return read_config_int("review.max_cycles", 3, config_path)


def _resolve_artifacts_dir() -> str:
    """Resolve the artifacts directory for this session."""
    return _ledger_artifacts_dir()


def _resolve_repo() -> str | None:
    """Resolve <owner>/<repo> from GITHUB_REPOSITORY env var."""
    return os.environ.get("GITHUB_REPOSITORY") or None


def _resolve_validator_script(plugin_root: str | None = None) -> str:
    """Return the absolute path to validate-review-output.sh.

    Resolution order mirrors _classify_tier_via_bash():
      1. plugin_root argument (explicit override)
      2. CLAUDE_PLUGIN_ROOT env var
      3. 5-dirname-levels from __file__:
         runner.py → dso_ci_review → scripts → dso → plugins → repo_root,
         then os.path.join(repo_root, "plugins", "dso") for the plugin root
    """
    if plugin_root is None:
        plugin_root = os.environ.get("CLAUDE_PLUGIN_ROOT")
    if plugin_root is None:
        _five_up = os.path.dirname(
            os.path.dirname(
                os.path.dirname(
                    os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
                )
            )
        )
        plugin_root = os.path.join(_five_up, "plugins", "dso")
    return os.path.join(plugin_root, "scripts", "validate-review-output.sh")


# Schema hash from validate-review-output.sh (HASH_CODE_REVIEW_DISPATCH).
# Exposed as a module constant so tests can assert drift against the script.
# When validate-review-output.sh changes its schema, update this constant and
# the corresponding test in test_runner_smoke.py.
_VALIDATE_REVIEW_SCHEMA_HASH = "cb48a66fc3292083"


# ---------------------------------------------------------------------------
# Category-remap layer (bug 0623-54f4-d31b-4623)
# ---------------------------------------------------------------------------
# Upstream LLM reviewers occasionally emit off-enum `category` values
# (35 distinct off-enum values observed in PR #257/258 — e.g. "code_smell",
# "missing_test_coverage"). The validator hard-rejects any non-canonical
# category, and the schema-correction loop only allows the corrector to remap
# category iff the original is off-enum (see dispatch._FROZEN_FIELDS comment).
# Without this deterministic pre-validation remap, every off-enum batch would
# spend a correction round-trip just to fix categories; this layer normalizes
# the 35 observed values to canonical buckets BEFORE validation so the
# correction loop is reserved for genuinely-novel schema issues.
#
# Unknown off-enum values (LLM produces novel ones) pass through unchanged so
# the validator can still flag them as a fallback signal and the correction
# loop can then repair them via the dispatch.py category exception.

_CANONICAL_CATEGORIES: frozenset[str] = frozenset(
    {"correctness", "design", "hygiene", "maintainability", "verification"}
)

# Maps off-enum category strings (observed in PR #257/258 and historical
# review logs) → canonical bucket. When extending: add the off-enum string as
# the key and pick the closest canonical bucket as the value.
_CATEGORY_REMAP: dict[str, str] = {
    # → correctness
    "missing_implementation": "correctness",
    "configuration_error": "correctness",
    "data_integrity": "correctness",
    "syntax_error": "correctness",
    "error_handling": "correctness",
    "incomplete_implementation": "correctness",
    "resource_management": "correctness",
    # → verification
    "test_fragility": "verification",
    "test_design_flaw": "verification",
    "test_pattern_weakness": "verification",
    "test_brittleness": "verification",
    "test_state_management": "verification",
    "test_diagnostics": "verification",
    "missing_test_coverage": "verification",
    "test_coverage_gap": "verification",
    # → hygiene
    "code_smell": "hygiene",
    "code_duplication": "hygiene",
    "inconsistent_style": "hygiene",
    "code_style": "hygiene",
    "code_complexity": "hygiene",
    # → maintainability
    "code_clarity": "maintainability",
    "documentation": "maintainability",
}


def _log_category_remap(original: str, mapped: str) -> None:
    """Emit a stderr observability line each time a finding's category is remapped.

    Helps detect upstream-LLM drift over time without spamming when no remap
    occurs. Called only inside `_remap_off_enum_categories` when a remap is
    actually applied.
    """
    print(
        f"INFO: category remap: {original!r} → {mapped!r} (bug 0623-54f4)",
        file=sys.stderr,
    )


def _remap_off_enum_categories(findings: list[dict]) -> list[dict]:
    """Deterministically normalize off-enum `category` values to canonical buckets.

    Mutates each finding dict's `category` in place when an off-enum value is
    found in `_CATEGORY_REMAP`. Canonical-enum and unknown-off-enum values are
    left unchanged. Emits a stderr observability line per remap so upstream
    LLM drift is detectable from CI logs.

    Returns the same list (mutated) for ergonomic chaining at call sites.

    See bug 0623-54f4-d31b-4623. Called immediately before
    `_validate_findings_schema` so the schema-correction loop only fires for
    genuinely-novel schema issues, not for the well-known 35 off-enum values.
    """
    for finding in findings:
        if not isinstance(finding, dict):
            continue
        cat = finding.get("category")
        if not isinstance(cat, str) or cat in _CANONICAL_CATEGORIES:
            continue
        mapped = _CATEGORY_REMAP.get(cat)
        if mapped is None:
            continue  # unknown off-enum — leave for validator + correction loop
        finding["category"] = mapped
        _log_category_remap(cat, mapped)
    return findings


def _validate_findings_schema(
    merged: dict,
    plugin_root: str | None = None,
    timeout: int = 60,
) -> _SchemaValidationResult:
    """Validate merged findings against the code-review-dispatch schema.

    Shells out to validate-review-output.sh code-review-dispatch <tmpfile>.
    Exit-code contract:
      0  = schema-pass → return _SchemaValidationResult("schema_pass", [])
      1  = schema-fail → return _SchemaValidationResult("schema_fail", <stderr_lines>)
      other, ENOENT, EACCES, TimeoutExpired → return _SchemaValidationResult("validator_error", <diagnostic>)

    Schema hash: _VALIDATE_REVIEW_SCHEMA_HASH (see module constant above)

    Writes findings to a tmpfile as JSON and passes it as the second positional argument
    to validate-review-output.sh (consistent with write-reviewer-findings.sh invocation,
    which uses: "$SCRIPT_DIR/validate-review-output.sh" code-review-dispatch "$PENDING_FILE" >&2).
    Tmpfile is always cleaned up in a try/finally block.
    """
    validator_script = _resolve_validator_script(plugin_root)

    tmp_path: str | None = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="w", suffix=".json", delete=False, encoding="utf-8"
        ) as tmp:
            json.dump(merged, tmp)
            tmp_path = tmp.name

        try:
            result = subprocess.run(
                ["bash", str(validator_script), "code-review-dispatch", tmp_path],
                capture_output=True,
                text=True,
                timeout=timeout,
            )
        except subprocess.TimeoutExpired:
            return _SchemaValidationResult(
                "validator_error",
                [f"validate-review-output.sh subprocess timed out after {timeout}s"],
            )
        except FileNotFoundError as exc:
            return _SchemaValidationResult(
                "validator_error",
                [f"validate-review-output.sh not found: {exc}"],
            )
        except PermissionError as exc:
            return _SchemaValidationResult(
                "validator_error",
                [f"validate-review-output.sh not executable: {exc}"],
            )
        except OSError as exc:
            return _SchemaValidationResult(
                "validator_error",
                [f"OS error invoking validate-review-output.sh: {exc}"],
            )

        if result.returncode == 0:
            return _SchemaValidationResult("schema_pass", [])
        if result.returncode == 1:
            # validate-review-output.sh emits all diagnostic output to stderr
            # (echo "..." >&2 throughout the script; stdout is reserved for
            # the SCHEMA_VALID:yes confirmation line on success).
            errors = [line for line in result.stderr.splitlines() if line.strip()] or [
                result.stderr.strip() or "schema validation failed (exit 1)"
            ]
            return _SchemaValidationResult("schema_fail", errors)
        # Any other non-zero exit → infrastructure failure
        return _SchemaValidationResult(
            "validator_error",
            [
                f"validate-review-output.sh returned unexpected exit code "
                f"{result.returncode}: {result.stderr.strip()!r}"
            ],
        )
    finally:
        if tmp_path is not None:
            try:
                os.unlink(tmp_path)
            except OSError:
                pass  # already removed or never created


def _build_reviewer_breakdown(merged: dict) -> dict:
    """Extract finding_id -> [reviewer_agent_id] from merged findings' provenance fields."""
    breakdown: dict[str, list[str]] = {}
    for finding in merged.get("findings", []):
        finding_id = finding.get("finding_id") or finding.get("id", "")
        if not finding_id:
            continue
        provenance = finding.get("provenance") or {}
        agent_ids = []
        if isinstance(provenance, dict):
            reviewer = provenance.get("reviewer_agent_id") or provenance.get("agent_id")
            if reviewer:
                agent_ids.append(reviewer)
        elif isinstance(provenance, list):
            for p in provenance:
                if isinstance(p, dict):
                    reviewer = p.get("reviewer_agent_id") or p.get("agent_id")
                    if reviewer:
                        agent_ids.append(reviewer)
        breakdown[finding_id] = agent_ids
    return breakdown


def _post_arbiter_comment(
    cycle_num: int,
    commit_sha: str,
    rulings: list[dict],
    finding_map: dict,
    pr_number: str | None,
    body: str | None = None,
) -> None:
    """Post (or update) the DSO-Arbiter-Ruling marker comment on the PR.

    No-op when pr_number is None.
    Idempotent: checks existing comments for the marker; UPDATEs if found for
    the same cycle+sha, CREATEs otherwise.

    The ``body`` parameter is the full comment text to post. When not provided
    it is constructed from the marker string and rulings summary.
    """
    if not pr_number:
        return

    marker = format_arbiter_marker(cycle_num=cycle_num, commit_sha=commit_sha)
    if body is None:
        rulings_summary = json.dumps(rulings, indent=2)
        body = f"{marker}\n\n### Arbiter Rulings\n\n```json\n{rulings_summary}\n```"

    # Check existing PR comments for the marker (idempotency).
    try:
        result = subprocess.run(
            ["gh", "pr", "view", str(pr_number), "--json", "comments"],
            capture_output=True,
            text=True,
        )
        if result.returncode == 0:
            comments_data = json.loads(result.stdout or "{}")
            for comment in comments_data.get("comments", []):
                comment_body = comment.get("body", "")
                if marker in comment_body:
                    # UPDATE existing comment
                    comment_id = comment.get("databaseId") or comment.get("id")
                    if comment_id:
                        try:
                            repo = os.environ.get("GITHUB_REPOSITORY", "")
                            subprocess.run(
                                [
                                    "gh",
                                    "api",
                                    "-X",
                                    "PATCH",
                                    f"/repos/{repo}/issues/comments/{comment_id}",
                                    "-f",
                                    f"body={body}",
                                ],
                                capture_output=True,
                                text=True,
                            )
                        except Exception:  # noqa: BLE001
                            pass
                    return
    except Exception:  # noqa: BLE001
        pass

    # CREATE new comment
    try:
        subprocess.run(
            ["gh", "pr", "comment", str(pr_number), "--body", body],
            capture_output=True,
            text=True,
        )
    except Exception:  # noqa: BLE001
        pass


def _resolve_pr_number() -> int | None:
    """Resolve the current PR number from GitHub Actions env vars.

    Returns the PR number as an int when a PR context is detectable, else None.
    Sources checked, in order:
      1. PR_NUMBER env var (explicit override — works for push-triggered workflows
         where the caller resolves the PR number via gh pr list and sets this var)
      2. GITHUB_REF (format: refs/pull/<N>/merge on pull_request events)
    """
    # Check PR_NUMBER first — works for both push and pull_request events.
    pr_num = os.environ.get("PR_NUMBER", "")
    if pr_num.isdigit():
        return int(pr_num)
    # Fallback: GITHUB_REF on pull_request events is "refs/pull/<N>/merge"
    if os.environ.get("GITHUB_EVENT_NAME", "") == "pull_request":
        ref = os.environ.get("GITHUB_REF", "")
        if ref.startswith("refs/pull/"):
            rest = ref[len("refs/pull/") :]
            num = rest.split("/", 1)[0]
            if num.isdigit():
                return int(num)
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


def _resolve_pr_head_sha(pr_number: int | str) -> str | None:
    """Resolve the HEAD SHA of the PR branch — event-aware.

    R1 (bug f148): on ``pull_request`` and ``pull_request_target`` events
    GitHub Actions sets ``GITHUB_SHA`` to the SYNTHESIZED MERGE-COMMIT SHA
    (refs/pull/N/merge), not the actual PR HEAD. The Reviews API rejects
    a posted review whose ``commit_id`` is not on the PR's commit list,
    so the prior "GITHUB_SHA-first" order produced HTTP 422 on every
    session→main PR.

    Resolution order:
      1. ``pull_request`` / ``pull_request_target`` event → ``gh pr view
         <pr> --json headRefOid -q .headRefOid`` (authoritative for these
         events). Fall through to GITHUB_SHA only if gh is unavailable.
      2. All other events (push, workflow_dispatch, schedule, …) →
         ``GITHUB_SHA`` (correct for those events).
      3. Last-resort: ``gh pr view headRefOid``.
    """
    event_name = os.environ.get("GITHUB_EVENT_NAME", "").strip()
    pr_events = {"pull_request", "pull_request_target"}

    if event_name in pr_events:
        # Prefer gh for PR events: GITHUB_SHA is the merge-commit ref here,
        # not the PR HEAD.
        sha = _gh_pr_head_oid(pr_number)
        if sha:
            return sha
        # Degraded: fall back to GITHUB_SHA with a warning so the operator
        # can investigate the gh failure.
        fallback = os.environ.get("GITHUB_SHA", "").strip()
        if fallback:
            print(
                f"WARNING [_resolve_pr_head_sha]: gh pr view failed for "
                f"PR #{pr_number}; falling back to GITHUB_SHA={fallback[:12]}… "
                "(may be the merge-commit ref, not the PR HEAD — Reviews API may 422).",
                file=sys.stderr,
            )
            return fallback
        return None

    # Non-PR events: GITHUB_SHA is the correct value.
    sha = os.environ.get("GITHUB_SHA", "").strip()
    if sha:
        return sha
    # Last-resort: try gh.
    return _gh_pr_head_oid(pr_number)


def _gh_pr_head_oid(pr_number: int | str) -> str | None:
    """Return the PR's head ref OID via gh, or None on any failure."""
    try:
        result = subprocess.run(
            [
                "gh",
                "pr",
                "view",
                str(pr_number),
                "--json",
                "headRefOid",
                "--jq",
                ".headRefOid",
            ],
            capture_output=True,
            text=True,
            timeout=15,
        )
        if result.returncode == 0:
            sha = result.stdout.strip()
            if sha:
                return sha
    except (subprocess.TimeoutExpired, FileNotFoundError):
        return None
    return None


def _extract_anchor(finding: dict) -> tuple[str, int] | None:
    """Extract (path, line) anchor from a finding's first cited_lines entry.

    Returns (path, line) using the start of the range, or None if the finding
    cannot be anchored (empty or unparseable cited_lines).
    """
    cited = finding.get("cited_lines") or []
    if not cited:
        return None
    first = cited[0]
    parsed = _parse_line_range(first)
    if parsed is None:
        return None
    path, _, _ = first.rpartition(":")
    if not path:
        return None
    return (path, parsed[0])


def _post_issue_comments(blocking: list[dict], pr_number: str, total: int) -> int:
    """Post findings as issue-level PR comments (gh pr comment), best-effort.

    Returns the count of successfully posted comments.
    """
    posted = 0
    for idx, finding in enumerate(blocking, 1):
        body = _format_finding_comment(idx, total, finding)
        try:
            subprocess.run(
                ["gh", "pr", "comment", str(pr_number), "--body", body],
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
            print(
                f"WARNING: failed to post PR comment for finding {idx}/{total} "
                f"({type(exc).__name__})",
                file=sys.stderr,
            )
    return posted


def _post_pr_review(findings: list[dict]) -> tuple[int, int]:
    """Post blocking findings as PR review thread comments via the GitHub Pulls Reviews API.

    Primary path (bug 59e3-8b8b fix): posts findings with file:line anchors via
    `gh api -X POST .../pulls/{n}/reviews` with a batched `comments[]` payload.
    This creates resolvable review threads that PR-FINALIZE-WORKFLOW.md can
    operate on (resolveReviewThread graphql mutation).

    Fallback paths:
    - Finding has no cited_lines anchor → posted as issue comment (gh pr comment)
    - HEAD SHA cannot be resolved → ALL findings posted as issue comments
    - GITHUB_REPOSITORY not set → ALL findings posted as issue comments
    - Reviews API call fails → ALL findings re-routed to issue comments

    Returns `(posted_count, attempted_count)`. Both 0 in no-op cases.

    No-op (returns (0, 0)) when:
    - PR number cannot be resolved
    - GITHUB_TOKEN is absent
    - blocking finding list is empty

    Errors are logged to stderr but never propagate — comment posting is a
    best-effort UX layer; the severity gate is the authoritative block.
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

    total = len(blocking)
    head_sha = _resolve_pr_head_sha(pr_number)
    repository = os.environ.get("GITHUB_REPOSITORY", "")

    if not head_sha or not repository or "/" not in repository:
        if not head_sha:
            print(
                "WARNING: cannot resolve PR HEAD SHA; falling back to issue comments",
                file=sys.stderr,
            )
        return (_post_issue_comments(blocking, pr_number, total), total)

    # Partition findings into anchored (Reviews API) and unanchored (issue comments)
    anchored: list[tuple[int, dict, str, int]] = []  # (idx, finding, path, line)
    unanchored: list[tuple[int, dict]] = []
    for idx, finding in enumerate(blocking, 1):
        anchor = _extract_anchor(finding)
        if anchor:
            path, line = anchor
            anchored.append((idx, finding, path, line))
        else:
            unanchored.append((idx, finding))

    # Synthesize an anchor for unanchored findings using the first added line of
    # the first changed file in the PR diff. This promotes findings that lack a
    # natural file:line (e.g. fragile findings about diff-level patterns or
    # external behavior) into resolvable PR review threads instead of standalone
    # issue comments — which are invisible to merge-to-main.sh resolve_phase,
    # /dso:respond-to-pr-comments, and the GitHub review-thread UX (bug 6f6f-df2f).
    # If synthesis fails for any reason, the unanchored findings fall through to
    # the existing issue-comment path below.
    if unanchored:
        try:
            _diff_proc = subprocess.run(
                ["gh", "pr", "diff", str(pr_number), "--patch"],
                capture_output=True,
                text=True,
                timeout=30,
                check=True,
            )
            _syn_path: str | None = None
            _syn_line: int | None = None
            _cur_path: str | None = None
            _cur_new_line = 0
            for _ln in _diff_proc.stdout.splitlines():
                if _ln.startswith("+++ b/"):
                    _cur_path = _ln[6:]
                    _cur_new_line = 0
                elif _ln.startswith("@@"):
                    # @@ -a,b +c,d @@ — extract c
                    try:
                        _hunk = _ln.split("+", 1)[1].split(" ", 1)[0]
                        _cur_new_line = int(_hunk.split(",", 1)[0]) - 1
                    except (IndexError, ValueError):
                        _cur_new_line = 0
                elif _ln.startswith("+") and not _ln.startswith("+++"):
                    _cur_new_line += 1
                    if _cur_path and _syn_path is None:
                        _syn_path = _cur_path
                        _syn_line = _cur_new_line
                        break
                elif not _ln.startswith("-"):
                    _cur_new_line += 1
            if _syn_path and _syn_line:
                _promoted: list[tuple[int, dict]] = []
                for idx, finding in unanchored:
                    finding = dict(finding)
                    finding["_synthetic_anchor"] = True
                    anchored.append((idx, finding, _syn_path, _syn_line))
                    _promoted.append((idx, finding))
                for entry in _promoted:
                    unanchored.remove(entry)
        except (
            subprocess.CalledProcessError,
            subprocess.TimeoutExpired,
            FileNotFoundError,
        ):
            pass  # fall through to issue-comment path

    posted = 0

    if anchored:
        comments_payload = [
            {
                "path": path,
                "line": line,
                "side": "RIGHT",
                "body": _format_finding_comment(idx, total, finding),
            }
            for idx, finding, path, line in anchored
        ]
        review_body = json.dumps(
            {"commit_id": head_sha, "event": "COMMENT", "comments": comments_payload}
        )
        try:
            subprocess.run(
                [
                    "gh",
                    "api",
                    "-X",
                    "POST",
                    f"/repos/{repository}/pulls/{pr_number}/reviews",
                    "--input",
                    "-",
                ],
                input=review_body,
                check=True,
                capture_output=True,
                text=True,
                timeout=60,
            )
            posted += len(anchored)
        except (
            subprocess.CalledProcessError,
            subprocess.TimeoutExpired,
            FileNotFoundError,
        ) as exc:
            # Surface gh stderr so failures are diagnosable: the Reviews API's
            # 422/403/etc. responses (e.g., "Commit SHA is not in the pull
            # request" when head_sha has been superseded by a mid-cycle push)
            # only appear in gh's stderr. Without this, the warning tells
            # operators a fallback happened but not why.
            _stderr = (getattr(exc, "stderr", "") or "")[:500].strip()
            print(
                f"WARNING: Reviews API failed ({type(exc).__name__}); "
                f"re-routing anchored findings to issue comments. "
                f"gh stderr: {_stderr!r}",
                file=sys.stderr,
            )
            # Fall back: add anchored findings to the issue comment queue
            unanchored.extend((idx, finding) for idx, finding, _, _ in anchored)

    # Post unanchored (and Reviews-API-failed) findings as issue comments
    for idx, finding in unanchored:
        body = _format_finding_comment(idx, total, finding)
        try:
            subprocess.run(
                ["gh", "pr", "comment", str(pr_number), "--body", body],
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
            # Surface gh stderr — same rationale as the Reviews API failure
            # branch above. Under systemic problems (read-only token, missing
            # pull-requests:write scope, rate-limit) this loop fires once per
            # finding, so without the underlying gh message operators get N
            # opaque warnings with no diagnostic path.
            _stderr = (getattr(exc, "stderr", "") or "")[:500].strip()
            print(
                f"WARNING: failed to post PR comment for finding {idx}/{total} "
                f"({type(exc).__name__}). gh stderr: {_stderr!r}",
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


def init_cycle_ledger(
    artifacts_dir: str, pr_number: str | None = None, repo: str | None = None
) -> int:
    """Read cycle-ledger.json and return the next cycle number.

    Reads pr_number and repo from environment (PR_NUMBER, GITHUB_REPOSITORY)
    when not provided as arguments.

    Falls back to PR comment reconstruction when file is absent and
    pr_number/repo are available. Logs a WARNING when DSO_REVIEW_CYCLE env var
    disagrees with the ledger-derived cycle_num. Ledger wins.

    Returns:
        int: cycle number >= 1. Callers treat >= 2 as a re-review pass.
    """
    ledger_path = os.path.join(artifacts_dir, "cycle-ledger.json")
    ledger = cycle_ledger.read_ledger(ledger_path)

    # Resolve pr_number and repo from env when not passed explicitly
    if pr_number is None:
        pr_number = _resolve_pr_number()
    if repo is None:
        repo = os.environ.get("GITHUB_REPOSITORY", "") or None

    if not ledger.get("cycles") and pr_number is not None and repo is not None:
        try:
            pr_int = int(pr_number)
        except ValueError:
            print(
                f"WARNING: pr_number={pr_number!r} is not a valid integer — skipping PR reconstruction",
                file=sys.stderr,
            )
        else:
            ledger = cycle_ledger.reconstruct_from_pr_comments(pr_int, repo)

    cycles = ledger.get("cycles", [])
    cycle_num = len(cycles) + 1  # next cycle number

    env_cycle = os.environ.get("DSO_REVIEW_CYCLE")
    if env_cycle is not None:
        try:
            env_cycle_int = int(env_cycle)
            if env_cycle_int != cycle_num:
                print(
                    f"WARNING: DSO_REVIEW_CYCLE={env_cycle_int} disagrees with "
                    f"ledger-derived cycle_num={cycle_num}; ledger wins",
                    file=sys.stderr,
                )
        except ValueError:
            pass

    return cycle_num


def _fetch_pr_defenses(pr_number: int | str) -> list[dict]:
    """Fetch DEFENSE_RECORD entries from GitHub PR comments via gh CLI.

    Reads all PR comments, extracts lines starting with "DEFENSE_RECORD: ",
    and returns parsed JSON records. Returns an empty list when:
    - GITHUB_TOKEN is absent
    - gh CLI is unavailable or fails
    - No DEFENSE_RECORD lines are found

    Best-effort: errors are logged to stderr but never propagate.
    """
    if not os.environ.get("GITHUB_TOKEN"):
        return []
    try:
        result = subprocess.run(
            [
                "gh",
                "pr",
                "view",
                pr_number,
                "--json",
                "comments",
                "--jq",
                ".comments[].body",
            ],
            capture_output=True,
            text=True,
            timeout=30,
        )
        if result.returncode != 0:
            print(
                f"WARNING: gh pr view failed (exit {result.returncode}); "
                "cannot fetch prior defenses for cycle-2 suppression",
                file=sys.stderr,
            )
            return []
    except (subprocess.TimeoutExpired, FileNotFoundError) as exc:
        print(
            f"WARNING: gh CLI unavailable ({type(exc).__name__}); "
            "cannot fetch prior defenses for cycle-2 suppression",
            file=sys.stderr,
        )
        return []

    defenses: list[dict] = []
    for line in result.stdout.splitlines():
        line = line.strip()
        if not line.startswith("DEFENSE_RECORD: "):
            continue
        json_str = line[len("DEFENSE_RECORD: ") :]
        try:
            record = json.loads(json_str)
            if isinstance(record, dict):
                defenses.append(record)
        except json.JSONDecodeError:
            pass  # malformed record; skip silently

    return defenses


def _normalize_cited_ref(entry: str) -> str:
    # Strip leading approximate marker and surrounding whitespace so proximity
    # matching uses exact path equality (~path.py:42 → path.py:42).
    cleaned = entry.strip().lstrip("~")
    parts = cleaned.split(":", 2)
    return f"{parts[0]}:{parts[1]}" if len(parts) >= 2 else cleaned


_GIT_SHA_RE = re.compile(r"^[0-9a-fA-F]{7,64}$")


def _inter_cycle_diff_modified_region(
    defense: dict, repo_root: str | None = None
) -> bool:
    base_sha = defense.get("story_branch_base_sha", "")
    tip_sha = defense.get("story_branch_tip_sha", "")
    if not base_sha or not tip_sha:
        return False
    # SHAs come from PR comments (DEFENSE_RECORD); treat as untrusted input.
    # Reject anything that doesn't look like a hex SHA before passing to git
    # to prevent option-injection via crafted "sha" strings.
    if not (_GIT_SHA_RE.match(base_sha) and _GIT_SHA_RE.match(tip_sha)):
        return False
    cited = defense.get("cited_lines", [])
    if not cited:
        return False
    try:
        import subprocess

        result = subprocess.run(
            ["git", "diff", f"{base_sha}..{tip_sha}", "--unified=0", "--"],
            capture_output=True,
            text=True,
            cwd=repo_root or ".",
            timeout=30,  # bound subprocess to prevent hang/DoS from crafted SHAs
        )
        if result.returncode != 0:
            return False
        modified: list[str] = []
        current_file = ""
        for line in result.stdout.splitlines():
            if line.startswith("+++ b/"):
                current_file = line[6:]
            elif line.startswith("+++ "):
                # +++ /dev/null (deletion) or other non-b/ header — reset so the
                # following hunk doesn't get mis-attributed to the previous file.
                current_file = ""
            elif line.startswith("@@ ") and current_file:
                parts = line.split(" ")
                if len(parts) >= 3:
                    new_range = parts[2].lstrip("+")
                    if "," in new_range:
                        start, count = new_range.split(",", 1)
                    else:
                        start, count = new_range, "1"
                    try:
                        start_i = int(start)
                        count_i = int(count) if count else 1
                        # count_i == 0 means pure deletion, no new lines — skip.
                        if count_i > 0:
                            for ln in range(start_i, start_i + count_i):
                                modified.append(f"{current_file}:{ln}")
                    except ValueError:
                        # Malformed hunk range — skip silently and continue.
                        pass
        if not modified:
            return False
        normalized_cited = [_normalize_cited_ref(c) for c in cited]
        return compute_proximity_overlap(normalized_cited, modified)
    except Exception:
        return False


def _apply_novelty_gate(
    findings: list[dict],
    defenses: list[dict],
    diff_text: str = "",
    cycle_number: int = 1,
) -> tuple[list[dict], dict]:
    """Downgrade unjustified NEW_INTRODUCED findings on cycle >= 2.

    A finding is 'unjustified' when its relation is NEW_INTRODUCED (or absent),
    its cited_lines do not overlap any prior defense's cited_lines within +/-5 lines,
    and its escape_rationale is missing or fails the three-criterion check.

    Returns (processed_findings, stats_dict) where stats_dict has keys:
        new_introduced_justified, new_introduced_unjustified,
        resustain_of_count, reframe_of_count
    """
    stats: dict[str, int] = {
        "new_introduced_justified": 0,
        "new_introduced_unjustified": 0,
        "resustain_of_count": 0,
        "reframe_of_count": 0,
    }
    if cycle_number < 2:
        return findings, stats

    result: list[dict] = []
    for finding in findings:
        relation = finding.get("relation")
        if relation is None:
            import sys as _sys  # noqa: PLC0415

            print(
                "WARNING: finding missing relation field — treating as NEW_INTRODUCED "
                f"(desc: {str(finding.get('description', ''))[:60]})",
                file=_sys.stderr,
            )
            relation = "NEW_INTRODUCED"

        relation_upper = str(relation).upper()
        if relation_upper == "RESUSTAIN_OF":
            stats["resustain_of_count"] += 1
            result.append(finding)
            continue
        if relation_upper == "REFRAME_OF":
            stats["reframe_of_count"] += 1
            result.append(finding)
            continue
        if relation_upper != "NEW_INTRODUCED":
            # NEW_PRE_EXISTING and any unrecognized relation are out of scope for
            # the novelty gate — the schema's NEW_PRE_EXISTING auto-downgrade to
            # `minor` is enforced elsewhere; don't double-downgrade here.
            result.append(finding)
            continue

        # NEW_INTRODUCED only
        f_cited = [_normalize_cited_ref(c) for c in finding.get("cited_lines") or []]
        # Union of prior defense cited_lines, normalized to 2-part path:lineno
        # so validate_escape_rationale's criteria 2/3 can actually fire.
        prior_cited: list[str] = []
        for d in defenses:
            for c in d.get("cited_lines") or []:
                prior_cited.append(_normalize_cited_ref(c))
        proximity_anchored = any(
            compute_proximity_overlap(
                f_cited, [_normalize_cited_ref(c) for c in d.get("cited_lines") or []]
            )
            for d in defenses
            if d.get("cited_lines")
        )
        if proximity_anchored:
            stats["new_introduced_justified"] += 1
            result.append(finding)
            continue

        escape_rationale = str(finding.get("escape_rationale") or "")
        valid_escape = (
            validate_escape_rationale(escape_rationale, prior_cited, [], diff_text)
            if escape_rationale
            else False
        )
        if valid_escape:
            stats["new_introduced_justified"] += 1
            result.append(finding)
        else:
            stats["new_introduced_unjustified"] += 1
            downgraded = dict(finding)
            downgraded["severity"] = "suggestion"
            downgraded["_novelty_gate_reason"] = "unjustified-novelty-claim"
            result.append(downgraded)

    return result, stats


def _suppress_defended_findings(
    findings: list[dict],
    defenses: list[dict],
) -> list[dict]:
    """Downgrade findings that match a prior defense to 'suggestion' severity.

    When a defense has cited_lines, uses proximity matching (±5-line window,
    same file) instead of description-prefix comparison. Falls back to the
    description[:80] prefix approach when cited_lines is absent.

    Findings are downgraded to 'suggestion' rather than removed so authors
    can see they were reconsidered.
    """
    if not defenses:
        return findings

    # Precompute per-defense modified-region check once (O(M)) instead of
    # invoking git diff inside the findings × defenses loop (O(N×M)). The result
    # depends only on the defense's SHA pair and cited_lines, not the finding.
    modified_region_cache: dict[int, bool] = {}
    for d in defenses:
        if d.get("cited_lines"):
            modified_region_cache[id(d)] = _inter_cycle_diff_modified_region(d)

    suppressed: list[dict] = []
    for f in findings:
        matched = False
        f_cited = [_normalize_cited_ref(c) for c in f.get("cited_lines", [])]
        f_sev = str(f.get("severity", "")).lower()
        f_desc = str(f.get("description", ""))[:80].lower()

        for d in defenses:
            d_cited = d.get("cited_lines", [])
            if d_cited:
                # Proximity path: skip if lines were modified between cycles.
                # When both sides have cited_lines, proximity is the canonical
                # match — non-overlap means a different finding, even if the
                # description happens to prefix-match. We intentionally do NOT
                # fall back to description-prefix here; that would re-introduce
                # over-suppression that proximity matching was added to prevent.
                if modified_region_cache.get(id(d), False):
                    continue
                d_cited_norm = [_normalize_cited_ref(c) for c in d_cited]
                if f_cited and compute_proximity_overlap(f_cited, d_cited_norm):
                    matched = True
                    break
            else:
                # Legacy fallback: description-prefix matching applies when
                # the defense lacks cited_lines (older records or text-only
                # defenses).
                d_sev = str(d.get("severity", "")).lower()
                d_desc = str(d.get("description", "") or d.get("defense_text", ""))[
                    :80
                ].lower()
                if d_sev and d_desc and (f_sev, f_desc) == (d_sev, d_desc):
                    matched = True
                    break

        if matched:
            downgraded = dict(f)
            downgraded["severity"] = "suggestion"
            downgraded["_suppressed_reason"] = (
                "Finding matches a prior defended finding; downgraded "
                "by cycle-2 dismissal-memory filter."
            )
            suppressed.append(downgraded)
        else:
            suppressed.append(f)
    return suppressed


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
    "light": "claude-haiku-4-5",
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

    # Locate config file. runner.py lives at
    # <repo_root>/<plugin_root>/scripts/dso_ci_review/runner.py so dso-config.conf
    # at <repo_root>/.claude/ is 5 dirname levels up (dso_ci_review → scripts →
    # <plugin_root> → plugins → repo_root). The previous 3-level chain stopped at
    # the plugin root, where .claude/ does not exist, so model.<tier> overrides
    # were silently ignored. (0e2a-77b0)
    if config_path is None:
        config_path = default_config_path()

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


# _default_config_path and _read_config_int moved to dso_ci_review._config
# (PR #169 review f-duplicated-helpers). Backward-compat thin wrappers kept for
# any external callers that may import the prior-name symbols.
def _default_config_path() -> str:  # pragma: no cover — thin compat shim
    return default_config_path()


def _read_config_int(  # pragma: no cover — thin compat shim
    key: str, default: int, config_path: str | None = None
) -> int:
    return read_config_int(key, default, config_path)


_SCHEMA_CORRECTION_MAX_ATTEMPTS_CEILING = 3


def _clamp_schema_correction_attempts(raw_value: int) -> int:
    """Clamp schema_correction_max_attempts to the hard ceiling.

    Values above the ceiling are clamped to the ceiling with a warning.
    max_attempts=0 is honored as-is (disables correction).

    Ceiling rationale: 3 attempts is sufficient for LLM correction convergence;
    values above 3 risk runaway LLM cost from misconfiguration.
    """
    if raw_value < 0:
        print(
            f"WARNING: review.schema_correction_max_attempts={raw_value} is negative; "
            f"clamped to 0 (correction disabled)",
            file=sys.stderr,
        )
        return 0
    if raw_value > _SCHEMA_CORRECTION_MAX_ATTEMPTS_CEILING:
        print(
            f"WARNING: review.schema_correction_max_attempts={raw_value} exceeds "
            f"ceiling={_SCHEMA_CORRECTION_MAX_ATTEMPTS_CEILING}; "
            f"clamped to {_SCHEMA_CORRECTION_MAX_ATTEMPTS_CEILING}",
            file=sys.stderr,
        )
        return _SCHEMA_CORRECTION_MAX_ATTEMPTS_CEILING
    return raw_value


def get_schema_correction_max_attempts(config_path: str | None = None) -> int:
    """Return the clamped schema_correction_max_attempts config value.

    Reads review.schema_correction_max_attempts from dso-config.conf (default: 1).
    Clamps to ceiling=3. max_attempts=0 disables correction dispatch.

    This is the single authoritative read point — called by dispatch_schema_correction()
    in dispatch.py (story 394e-d81b-fba4-4161, which adds dispatch.py and its
    dispatch_schema_correction function as a subsequent story in the same epic).
    Do not re-implement config reading for this key in dispatch.py.
    """
    raw = read_config_int("review.schema_correction_max_attempts", 2, config_path)
    return _clamp_schema_correction_attempts(raw)


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
                "review_context": "ci",
            },
            {
                "agent_id": "code-reviewer-deep-verification",
                "diff_text": diff_text,
                "model": base_model,
                "provider_chain": provider_chain,
                "tier": tier,
                "review_context": "ci",
            },
            {
                "agent_id": "code-reviewer-deep-hygiene",
                "diff_text": diff_text,
                "model": base_model,
                "provider_chain": provider_chain,
                "tier": tier,
                "review_context": "ci",
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
                "review_context": "ci",
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
                    "review_context": "ci",
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
            "review_context": "ci",
        }
        for dim in warranted
    ]


def _compute_findings_tuples(findings: list[dict]) -> list[tuple]:
    """Extract (file, line_range, category) tuples from findings, sorted for determinism."""
    return sorted(
        (f.get("file", ""), str(f.get("line_range", "")), f.get("category", ""))
        for f in findings
    )


def _compute_findings_hash(tuples: list[tuple]) -> str:
    """Return a 16-char lowercase hex hash of the findings tuples (order-independent)."""
    raw = "|".join(f"{t[0]}:{t[1]}:{t[2]}" for t in sorted(tuples))
    return hashlib.sha256(raw.encode()).hexdigest()[:16]


def _post_cycle_marker_comment(
    pr_number: str | None,
    cycle_num: int,
    commit_sha: str,
    findings_hash: str,
    tuples: list[tuple],
) -> None:
    """Post or update a DSO-Review-Cycle marker comment on the PR.

    No-op when pr_number is None.
    Deduplicates by checking for an existing comment that matches BOTH cycle_num AND
    commit_sha. If found, PATCHes it; otherwise creates a new comment.
    All gh CLI failures are logged as WARNINGs and are non-fatal.

    Writer/reader endpoint parity (bug 230d): the writer posts via
    `gh pr comment <pr> --body ...`, which targets the same issue-conversation
    endpoint returned by `cycle_marker_list_endpoint` in `cycle_marker_format`.
    The reader (`cycle_ledger.reconstruct_from_pr_comments`) MUST call that
    helper rather than hardcode a URL — see bugs 9788/230d for the regression
    that this parity protects against.
    """
    # Pre-condition guard (see cycle_marker_format.format_cycle_marker docstring):
    # the formatter raises ValueError on pr_number <= 0; convert that into a
    # no-op here so callers without a real PR context (push-event reruns where
    # PR_NUMBER may be unset) do not crash. Bug 9788 v3 fix scope.
    if pr_number is None or int(pr_number) <= 0:
        return

    body = format_cycle_marker(
        cycle_num=cycle_num,
        pr_number=int(pr_number),
        commit_sha=commit_sha,
        findings_hash=findings_hash,
        tuples=tuples,
    )

    # Fetch existing comments to check for dedup
    try:
        list_result = subprocess.run(
            ["gh", "pr", "view", str(pr_number), "--json", "comments"],
            capture_output=True,
            text=True,
            timeout=30,
        )
        if list_result.returncode != 0:
            print(
                f"WARNING: gh pr view failed (exit {list_result.returncode}); "
                "cannot dedup cycle marker comment",
                file=sys.stderr,
            )
            existing_comments: list[dict] = []
        else:
            try:
                pr_data = json.loads(list_result.stdout)
                if isinstance(pr_data, dict):
                    existing_comments = pr_data.get("comments", [])
                elif isinstance(pr_data, list):
                    existing_comments = pr_data
                else:
                    existing_comments = []
            except json.JSONDecodeError:
                existing_comments = []
    except (subprocess.TimeoutExpired, FileNotFoundError) as exc:
        print(
            f"WARNING: gh CLI unavailable ({type(exc).__name__}); "
            "cannot post cycle marker comment",
            file=sys.stderr,
        )
        return

    # Find existing comment matching BOTH cycle_num AND commit_sha. The
    # cycle_dedup_key helper returns two substrings guaranteed (by
    # format_cycle_marker's documented format invariant) to appear verbatim
    # in any well-formed cycle marker; pairing both protects against
    # collision when one finding body coincidentally contains the cycle
    # number or sha. Bug 9788 v3 fix scope (replaces the broken `cycle=K`
    # substring that depended on the now-removed writer format).
    dedup_key_cycle, dedup_key_sha = cycle_dedup_key(cycle_num, commit_sha)
    existing_id: int | None = None
    for comment in existing_comments:
        comment_body = comment.get("body", "")
        if dedup_key_cycle in comment_body and dedup_key_sha in comment_body:
            existing_id = comment.get("id")
            break

    # Resolve owner/repo from GITHUB_REPOSITORY for PATCH path
    repository = os.environ.get("GITHUB_REPOSITORY", "")

    try:
        if existing_id is not None:
            # PATCH existing comment (update in-place to avoid duplicate markers)
            subprocess.run(
                [
                    "gh",
                    "api",
                    "-X",
                    "PATCH",
                    f"/repos/{repository}/issues/comments/{existing_id}",
                    "-f",
                    f"body={body}",
                ],
                capture_output=True,
                text=True,
                timeout=30,
            )
        else:
            # POST new comment
            subprocess.run(
                ["gh", "pr", "comment", str(pr_number), "--body", body],
                capture_output=True,
                text=True,
                timeout=30,
            )
    except (subprocess.TimeoutExpired, FileNotFoundError) as exc:
        print(
            f"WARNING: failed to post/update cycle marker comment ({type(exc).__name__})",
            file=sys.stderr,
        )


_CYCLE_1_STAGGER_S: float = 0.4


async def _gather_clusters(
    *,
    specs: list[dict],
    tier_agents: list[dict],
    sem: asyncio.Semaphore,
    dispatch_ctx: DispatchContext,
    cycle_number: int,
    diff_text_fallback: str,
) -> list[dict]:
    """Gather all clusters' _run_cluster coroutines under a shared
    DispatchContext. Extracted to module scope so the test suite can exercise
    it directly and so the strategy_f block in main() stays small.
    """
    return await asyncio.gather(
        *[
            _run_cluster(
                spec=spec,
                tier_agents=tier_agents,
                sem=sem,
                dispatch_ctx=dispatch_ctx,
                cluster_index=idx,
                cycle_number=cycle_number,
                diff_text_fallback=diff_text_fallback,
            )
            for idx, spec in enumerate(specs)
        ],
        return_exceptions=True,
    )


async def _run_cluster(
    spec: dict,
    tier_agents: list[dict],
    sem: asyncio.Semaphore,
    dispatch_ctx: DispatchContext,
    cluster_index: int,
    cycle_number: int,
    diff_text_fallback: str,
) -> dict:
    """Dispatch one cluster's specialists. Returns a result dict; never raises.

    On cycle 1 only, staggers cluster_index > 0 starts by 0.4s × index so
    cluster 0's response writes the system-prompt cache before clusters 1..N
    fire, avoiding N× cache-creation cost on cold start. Cycle 2+ skips the
    stagger because the cache is warm.

    Concurrency is gated by ``sem``; the caller picks the limit from
    ``review.region_split.cluster_concurrency`` (default 2, capped at
    min(max_clusters, 3) — see region_split._cluster_concurrency).

    Any escape (RateLimitError, network error, unexpected) is caught and
    converted to a dispatch_error result so gather(return_exceptions=True)
    never yields a bare Exception to the aggregator.
    """
    cluster_diff = spec.get("diff", diff_text_fallback)
    cluster_files = spec.get("files", [])
    cluster_dir = spec.get("cluster_dir", ".")
    oversized_single_file = spec.get("oversized_single_file", False)

    if oversized_single_file:
        skip_file = cluster_files[0] if cluster_files else cluster_dir
        print(
            f"INFO: skipping oversized single-file cluster {skip_file!r} "
            f"(diff exceeds loc_threshold — LLM dispatch skipped to prevent "
            f"non-JSON response; file will appear in skipped list)",
            file=sys.stderr,
        )
        return {
            "cluster_id": cluster_dir,
            "file_paths": cluster_files,
            "findings": [],
            "status": "oversized_skip",
        }

    if cycle_number == 1 and cluster_index > 0:
        await asyncio.sleep(_CYCLE_1_STAGGER_S * cluster_index)

    async with sem:
        cluster_agents = [
            {**agent, "diff_text": cluster_diff} for agent in tier_agents
        ]
        try:
            dispatch_results = await async_dispatch_specialists(
                cluster_agents, dispatch_context=dispatch_ctx
            )
            findings: list[dict] = []
            for dr in dispatch_results:
                if not isinstance(dr, dict):
                    continue
                _raw = dr.get("findings", [])
                # Bug 7f55: guard against degraded LLM responses where
                # `findings` is a non-list (e.g. {"findings": "no issues"}).
                # Without this guard, list.extend(str) flattens the string
                # character-by-character into bogus per-char "findings",
                # which then crash aggregator._deduplicate_findings (line 75)
                # with AttributeError: 'str' object has no attribute 'get'.
                # Established pattern at dispatch.py:1274 — applied here.
                if not isinstance(_raw, list):
                    print(
                        f"WARNING: cluster {cluster_dir} dispatch result has "
                        f"non-list findings ({type(_raw).__name__}); skipping. "
                        f"preview: {str(_raw)[:200]!r}",
                        file=sys.stderr,
                    )
                    continue
                # Also filter per-item: an individual finding that isn't a
                # dict cannot be aggregated; drop quietly to preserve the
                # rest of the cluster's valid findings.
                findings.extend(f for f in _raw if isinstance(f, dict))
            return {
                "cluster_id": cluster_dir,
                "file_paths": cluster_files,
                "findings": findings,
                "status": "ok",
            }
        except Exception as exc:  # noqa: BLE001
            print(
                f"WARNING: cluster dispatch failed for {cluster_dir}: "
                f"{type(exc).__name__}: {exc}",
                file=sys.stderr,
            )
            return {
                "cluster_id": cluster_dir,
                "file_paths": cluster_files,
                "findings": [],
                "status": "dispatch_error",
            }


def _infra_failure_exit_code() -> int:
    """Return the exit code main() should use for infrastructure-class failures.

    R4 (bug f148 PR-C): when the review pipeline fails for infrastructure
    reasons — runner crash, all-specialist-errors, or all-synthetic
    findings — we want the CI workflow's classify step to distinguish
    "infrastructure failure" from "review found real problems". Both
    historically returned exit 1, indistinguishable to operators.

    Config-gated for clean rollback: DSO_INFRA_EXIT_CODE_ENABLED.
      - "1" / "true" (default): return 4 for infra failures.
      - "0" / "false": return 1 (legacy behavior, indistinguishable from
        "review found problems"). Use when the workflow's classify step
        hasn't been deployed yet, or when a rollback is needed.

    The CI workflow's "Classify llm-review failure" step reads the exit
    code and emits a different annotation for 4 vs 1; see
    ${CLAUDE_PLUGIN_ROOT}/docs/contracts/review-defenses.md.
    """
    flag = os.environ.get("DSO_INFRA_EXIT_CODE_ENABLED", "1").strip().lower()
    if flag in ("0", "false", "no", ""):
        return 1
    return 4


def main() -> int:
    """Run the CI review and return an exit code.

    CLI-only entry point. The four asyncio.run() invocations inside this
    function (and inside region_split.review_oversized_clusters) assume no
    host event loop is already running. Importing and calling main() from a
    context with a running loop will trip the assertion below — see
    tests/skills/dso_ci_review/litellm_contract_spikes/spike_05_nested_loop_assertion.py
    """
    try:
        asyncio.get_running_loop()
    except RuntimeError:
        pass
    else:
        raise RuntimeError(
            "runner.main() is CLI-only and cannot be invoked from a context "
            "with a running event loop. Run as a subprocess instead."
        )

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
        # R4: missing agent files is an infrastructure setup problem, not a
        # code-review finding (CodeRabbit PR #455 major).
        return _infra_failure_exit_code()

    diff_text = _read_diff()
    if not diff_text.strip():
        # Bug 9788 regression-detection guard: when PR context exists but the
        # diff is empty, the caller likely failed to supply the diff (e.g., a
        # dispatcher wrapper missing `gh pr diff` or DSO_CI_REVIEW_DIFF_PATH).
        # Silent exit 0 with empty findings would mask the upstream wiring
        # break — emit a loud warning AND a structured skip_reason so the
        # "Assert review liveness" invariant downstream can detect the
        # condition.
        _pr_for_context = _resolve_pr_number()
        if _pr_for_context and _pr_for_context > 0:
            print(
                f"WARNING: empty diff received in PR context (PR #{_pr_for_context}) — "
                "likely caller missing `gh pr diff` pipe or DSO_CI_REVIEW_DIFF_PATH env. "
                "This will mask cycle-marker emission (bug 9788).",
                file=sys.stderr,
            )
            _write_output({"findings": [], "skip_reason": "empty_diff_in_pr_context"})
            # R4: an empty diff in PR context is a caller wiring break — the
            # dispatcher didn't supply the diff. Infrastructure-class failure.
            return _infra_failure_exit_code()
        # Non-PR context (local invocation / unit test): preserve historic behavior.
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
        # R4: provider config/auth failure is an infrastructure setup problem
        # — wrong env var, missing API key — not a code-review finding.
        return _infra_failure_exit_code()

    # Initialize cycle ledger and max_cycles before the main try block so
    # cycle_next_action routing has access to these values inside the try.
    # Note: defensive DSO_REVIEW_CYCLE parsing kept inside _init_cycle_ledger;
    # ledger is the source of truth, env var is logged-only (story 5621).
    _artifacts_dir = _resolve_artifacts_dir()
    _pr_number_for_ledger = _resolve_pr_number()
    _repo_for_ledger = _resolve_repo()
    max_cycles = _resolve_max_cycles()
    ledger, _ledger_cycle_number = _init_cycle_ledger(
        _artifacts_dir, _pr_number_for_ledger, _repo_for_ledger
    )

    try:
        # Step 1: classify tier
        classification = _classify_tier_via_bash(diff_text)
        tier = classification["selected_tier"]

        # Ledger-authoritative cycle derivation (replaces DSO_REVIEW_CYCLE as source).
        # On cycle N≥2, fetch prior defenses from PR comments so the LLM can avoid
        # re-emitting already-defended findings. (Bug c59e-a197: dismissal-memory gap.)
        # Use _artifacts_dir from the outer scope (resolved via _resolve_artifacts_dir)
        # so tests and callers that patch _resolve_artifacts_dir get consistent behavior.
        artifacts_dir = _artifacts_dir
        pr_number = _pr_number_for_ledger
        repo = _repo_for_ledger

        # cycle_number: ledger is source of truth (story 5621). Use the value
        # derived by _init_cycle_ledger above; fall back to env-var only if
        # ledger derivation failed (defensive parse mirrors c131-0f34 behavior).
        _raw_cycle = os.environ.get("DSO_REVIEW_CYCLE", "1") or "1"
        try:
            _env_cycle = int(_raw_cycle)
        except ValueError:
            print(
                f"WARNING: DSO_REVIEW_CYCLE={_raw_cycle!r} is not an integer; defaulting to 1",
                file=sys.stderr,
            )
            _env_cycle = 1
        cycle_number = _ledger_cycle_number or _env_cycle

        # Load the raw ledger for SHORT_CIRCUIT pre-check (cycle_next_action needs it).
        _ledger_path = os.path.join(artifacts_dir, "cycle-ledger.json")
        _ledger = cycle_ledger.read_ledger(_ledger_path)

        # Move reviewed_sha resolution ABOVE SHORT_CIRCUIT check.
        reviewed_sha = str(
            subprocess.check_output(
                ["git", "rev-parse", "HEAD"],
                text=True,
                stderr=subprocess.DEVNULL,
            )
        ).strip()

        # SHA-reset: when HEAD changed since the last ledger cycle, reset
        # cycle_number to 1 — mirrors cycle_dispatcher.next_action lines 236-257.
        # Without this, _init_cycle_ledger returns stale cycle counts after
        # force-pushes, causing defense-loading and two-call dispatch gates to
        # use incorrect cycle context (bug 3fb2-23be).
        _last_cycles = ledger.get("cycles", [])
        _last_cycle = _last_cycles[-1] if _last_cycles else None
        if (
            _last_cycle
            and _last_cycle.get("commit_sha")
            and _last_cycle["commit_sha"] != reviewed_sha
            and cycle_number > 1
        ):
            print(
                f"INFO: commit_sha changed ({_last_cycle['commit_sha'][:12]} → "
                f"{reviewed_sha[:12]}); resetting cycle_number from "
                f"{cycle_number} to 1",
                file=sys.stderr,
            )
            cycle_number = 1

        # Pre-review SHORT_CIRCUIT check: when HEAD SHA matches last cycle AND
        # arbiter-rulings.json exists, skip dispatch and return early.
        # Pass pr_number/repo so the durable PR-comment fallback fires when
        # the filesystem arbiter-rulings.json is absent (CI-ephemeral
        # $ARTIFACTS_DIR scenario — bug ab89-4fbb).
        _pre_check = cycle_next_action(
            _ledger,
            max_cycles,
            [],
            reviewed_sha,
            artifacts_dir,
            pr_number=_pr_number_for_ledger,
            repo=_repo_for_ledger,
        )
        if _pre_check.get("action") == "SHORT_CIRCUIT":
            rulings_path = os.path.join(artifacts_dir, "arbiter-rulings.json")
            try:
                with open(rulings_path) as f:
                    rulings_data = json.load(f)
            except (OSError, json.JSONDecodeError):
                rulings_data = {}
            # Support both {"rulings": [...]} and flat list formats.
            if isinstance(rulings_data, list):
                rulings_list = rulings_data
            else:
                rulings_list = rulings_data.get("rulings", [])
            has_block = any(
                r.get("ruling") == "BLOCK" for r in rulings_list if isinstance(r, dict)
            )
            return 1 if has_block else 0

        # Fetch prior defenses for cycle-2+ suppression.
        # Returns [] when not in a PR context or when gh CLI is unavailable.
        # LEDGER-SAFE (task 36cf): When cycle_number is replaced by ledger-derived
        # cycle_num, this guard remains correct. The ledger resets cycle_num to 1 on
        # SHA change — so this block is skipped on a new commit (desired: no stale
        # defenses from a previous SHA). On a true re-review of the same SHA,
        # cycle_num >= 2 holds, and prior defenses are loaded. No behavioral change needed.
        #
        # DSO_SUPPRESS_PRIOR_DEFENSES: when set to "true" (emitted by ci.yml's
        # "Suppress prior defenses for integration review" step), skip prior-defense
        # loading entirely even when cycle_number >= 2. This allows the integration
        # review (session→main PR) to evaluate findings fresh, without sub-PR defenses
        # suppressing findings that the integration reviewer should see. T10: wired here
        # so DSO_SUPPRESS_PRIOR_DEFENSES gates cycle_number-based prior-defense loading.
        _suppress_prior_defenses = (
            os.environ.get("DSO_SUPPRESS_PRIOR_DEFENSES", "").lower() == "true"
        )
        prior_defenses: list[dict] = []
        if cycle_number >= 2 and not _suppress_prior_defenses:
            if pr_number:
                prior_defenses = _fetch_pr_defenses(pr_number)
                if prior_defenses:
                    print(
                        f"INFO: cycle {cycle_number} — loaded {len(prior_defenses)} "
                        "prior defense record(s) for dismissal-memory filter",
                        file=sys.stderr,
                    )
        elif cycle_number >= 2 and _suppress_prior_defenses:
            print(
                f"INFO: cycle {cycle_number} — DSO_SUPPRESS_PRIOR_DEFENSES=true: "
                "prior defenses suppressed for integration review pass",
                file=sys.stderr,
            )

        # Resolve config_path once for overlay agent construction
        config_path: str | None = None

        # Step 2: build agent list based on tier, plus any classifier-flagged overlays
        tier_agents = _build_agents_for_tier(
            tier, diff_text, classification, config_path
        )
        overlay_agents = _build_overlay_agents(classification, diff_text, config_path)

        # Enrich overlay descriptors with model + provider_chain for dispatch
        base_model = _read_tier_model(tier, config_path)
        provider_chain = [os.environ.get("CI_REVIEW_PROVIDER", "anthropic")]
        for agent in overlay_agents:
            agent.setdefault("model", base_model)
            agent.setdefault("provider_chain", provider_chain)

        # Strategy E / F: region-split FALLBACK for large diffs (bed6-3871-f13c-4160).
        # When the diff exceeds the LOC or file-count threshold, bypass the standard
        # tier dispatch path and cluster the diff into per-directory regions, dispatching
        # specialists per cluster in parallel.
        #
        # Strategy F extension (S7.T7): when Strategy F is active, the pipeline is:
        #   1. Pre-filter files via file_filter (linguist tags + ignore.glob)
        #   2. Chunk via run_region_split_strategy_f (per-file fan-out for oversized clusters)
        #   3. OVER_BOUND check: if clusters × calls exceeds budget, emit OVER_BOUND status
        #   4. Dispatch each cluster (reuse existing primary→fallback model chain)
        #   5. Aggregate via aggregate_cluster_findings (cross-file synthesis + visibility trailer)
        #
        # This gate runs BEFORE the two-call and standard dispatch paths so the
        # huge-diff path is a first-class route, not an afterthought.
        #
        # Component #3' R-1: the generated/binary file-filter runs BEFORE the
        # should_split decision. We compute the reviewable/skipped file SET once,
        # upstream, and feed BOTH the gate decision (_should_region_split_on_files)
        # AND the chunked dispatch from it. The diff TEXT is never mutated — only
        # the file path sets are derived — preserving the OVER_BOUND budget math
        # and the visibility trailer's skipped-file list. This also means a
        # generated-heavy diff that now reviews single-pass still has its
        # generated files filtered out of scope (recorded below in Step 1s).
        _large_diff_config = _load_filter_config(config_path)
        _reviewable_files, _skipped_files = _partition_reviewable_files(
            diff_text, config=_large_diff_config
        )
        _skipped_set = {path for path, _ in _skipped_files}

        def _dispatch_and_aggregate_clusters(filtered_specs: list[dict]) -> dict:
            """Dispatch the given (already skip-filtered) cluster specs in
            parallel and aggregate into a merged result with visibility trailer.

            Shared by the primary region-split gate path and the component #3'
            R-2 fallback re-chunk path so the chunked dispatch+aggregate logic
            lives in one place. Captures the surrounding main() locals
            (tier_agents, cycle_number, artifacts_dir, pr_number, reviewed_sha,
            diff_text, _reviewable_files, _skipped_files).
            """
            _dispatch_ctx = DispatchContext.create()
            _max_in_flight = _cluster_concurrency()
            _cluster_sem = asyncio.Semaphore(_max_in_flight)
            print(
                f"INFO: dispatching {len(filtered_specs)} cluster(s) with "
                f"cluster_concurrency={_max_in_flight}",
                file=sys.stderr,
            )
            try:
                _raw_results = asyncio.run(
                    _gather_clusters(
                        specs=filtered_specs,
                        tier_agents=tier_agents,
                        sem=_cluster_sem,
                        dispatch_ctx=_dispatch_ctx,
                        cycle_number=cycle_number,
                        diff_text_fallback=diff_text,
                    )
                )
            finally:
                _dispatch_ctx.cleanup()

            _cluster_results: list[dict] = []
            for _idx, _result in enumerate(_raw_results):
                if isinstance(_result, dict):
                    _cluster_results.append(_result)
                else:
                    # _run_cluster guards every escape, so this branch is a
                    # belt-and-suspenders fallback for genuinely unexpected
                    # exceptions (e.g. asyncio internal errors).
                    _spec = filtered_specs[_idx]
                    print(
                        f"WARNING: cluster {_spec.get('cluster_dir', '.')!r} "
                        f"escaped _run_cluster guard: "
                        f"{type(_result).__name__}: {_result}",
                        file=sys.stderr,
                    )
                    _cluster_results.append(
                        {
                            "cluster_id": _spec.get("cluster_dir", "."),
                            "file_paths": _spec.get("files", []),
                            "findings": [],
                            "status": "dispatch_error",
                        }
                    )

            _pr_num_int = pr_number if isinstance(pr_number, int) else None
            _ledger_path_for_agg = os.path.join(artifacts_dir, "cycle-ledger.json")
            _agg_result = _aggregate_cluster_findings(
                cluster_results=_cluster_results,
                reviewed_files=_reviewable_files,
                skipped_files=_skipped_files,
                pr_number=_pr_num_int,
                commit_sha=reviewed_sha,
                cycle_num=cycle_number,
                ledger_path=_ledger_path_for_agg,
            )
            _agg_findings = _agg_result.get("findings", [])
            _visibility_trailer = _agg_result.get("visibility_trailer", "")
            _merged = {
                "findings": _agg_findings,
                "visibility_trailer": _visibility_trailer,
                "aggregation_status": _agg_result.get("aggregation_status", "ok"),
            }
            if _visibility_trailer:
                print(f"INFO: {_visibility_trailer}", file=sys.stderr)
            return _merged

        if _should_region_split_on_files(diff_text, _reviewable_files):
            print(
                "INFO: diff exceeds region-split threshold — activating Strategy F "
                "file-filter + chunked + aggregated review",
                file=sys.stderr,
            )

            # Validate large-diff config (DD1 / F6 AC amendment).
            try:
                _validate_large_diff_config(_large_diff_config)
            except ValueError as _cfg_exc:
                print(f"ERROR: large-diff config: {_cfg_exc}", file=sys.stderr)
                _write_output(
                    {
                        "findings": [],
                        "status": OVER_BOUND,
                        "over_bound_reason": str(_cfg_exc),
                    }
                )
                return 1

            # Step 2: chunk via Strategy F (per-file fan-out for oversized clusters).
            # _reviewable_files / _skipped_files were computed upstream (R-1).
            _dispatch_specs = run_region_split_strategy_f(diff_text=diff_text)

            # Filter specs to only include reviewable files (remove skipped files).
            _filtered_specs = [
                spec
                for spec in _dispatch_specs
                if not all(f in _skipped_set for f in spec.get("files", []))
            ]

            # Step 3: OVER_BOUND check — clusters × calls exceeds budget.
            _max_files_cfg = _large_diff_config.get("max_files") or 0
            _max_calls_cfg = _large_diff_config.get("max_calls") or 0
            _total_dispatches = len(_filtered_specs)
            _budget_exceeded = False
            if _max_files_cfg > 0 and _total_dispatches > _max_files_cfg:
                _budget_exceeded = True
            if (
                _max_calls_cfg > 0
                and _total_dispatches > _max_files_cfg * _max_calls_cfg
            ):
                _budget_exceeded = True

            if _budget_exceeded:
                _over_bound_msg = (
                    f"{OVER_BOUND}: {_total_dispatches} clusters exceeds "
                    f"max_files ({_max_files_cfg}) × max_calls ({_max_calls_cfg}). "
                    "Routed to admin/FP-recovery."
                )
                print(f"INFO: {_over_bound_msg}", file=sys.stderr)
                _write_output(
                    {
                        "findings": [],
                        "status": OVER_BOUND,
                        "over_bound_reason": _over_bound_msg,
                    }
                )
                return 1

            # Steps 4-5: dispatch clusters in parallel + aggregate (shared closure).
            merged = _dispatch_and_aggregate_clusters(_filtered_specs)

        else:
            # Step 3: dispatch tier agents + classifier-flagged overlays together (parallel).
            # On cycle N≥2 with prior defenses, single-agent tiers (light/standard) use the
            # two-call architecture so the LLM evaluates findings against existing defenses.
            # Deep tier continues to use the standard path; defenses are injected at the
            # arch-synthesis step (Step 6) where the final synthesis happens.
            #
            # LEDGER-SAFE (task 36cf): Under ledger semantics, cycle_num resets to 1 on SHA
            # change, so this two-call path is skipped for new commits. That is correct: the
            # two-call path requires prior_defenses fetched above, which are also skipped when
            # cycle_num < 2. The compound condition (cycle_number >= 2 AND prior_defenses) means
            # SHA-reset → prior_defenses=[] → two-call path never fires. No change needed.
            if (
                cycle_number >= 2
                and prior_defenses
                and tier in ("light", "standard")
                and not overlay_agents
            ):
                # Two-call path: single-agent tier with prior defenses.
                # Build prior_findings_index (no defense_text) and prior_findings (with defense_text).
                prior_findings_index = [
                    {k: v for k, v in d.items() if k != "defense_text"}
                    for d in prior_defenses
                ]
                primary_agent = tier_agents[0]
                two_call_result = dispatch_two_call_review(
                    diff_text=diff_text,
                    prior_findings_index=prior_findings_index,
                    prior_findings=prior_defenses,
                    defenses=prior_defenses,
                    provider_chain=provider_chain,
                    agent_id=primary_agent["agent_id"],
                    primary_model=primary_agent["model"],
                    review_context="ci",
                )
                first_pass_findings = [two_call_result]
            else:
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
            # On cycle N≥2 with prior defenses, the merged specialist context is augmented
            # with defenses so the arch synthesizer can avoid re-emitting defended findings.
            if tier == "deep":
                arch_model = _read_tier_model("deep-arch", config_path)
                # The deep-arch agent's Sonnet Findings Guard refuses any
                # prompt missing the three category markers (SONNET-A/B/C).
                # _format_merged_for_arch partitions by category and emits
                # the markers required by the agent contract — without this,
                # the synthesis call returns a prose refusal and crashes
                # downstream JSON parsing (bug 7f55 / PR #448 cycle 1).
                merged_json = _format_merged_for_arch(merged)
                # LEDGER-SAFE (task 36cf): SHA-reset sets cycle_num=1, so prior_defenses=[]
                # (the fetch is gated on cycle_num >= 2 above). The compound condition below
                # short-circuits to False in that case — no defense context injected. Correct.
                if cycle_number >= 2 and prior_defenses:
                    # Append defense context to the merged JSON passed to arch synthesis.
                    # dispatch_arch_synthesis appends it as "Prior specialist findings" in
                    # the prompt; we extend that context with the defense ledger.
                    defenses_context = (
                        "\n\n## Prior round defenses (do NOT re-emit findings that have been defended)\n\n"
                        + json.dumps(prior_defenses, indent=2)
                    )
                    merged_json_with_defenses = merged_json + defenses_context
                else:
                    merged_json_with_defenses = merged_json
                arch_result = dispatch_arch_synthesis(
                    merged_json_with_defenses,
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

            # Step 6b: component #3' R-2 — fallback re-chunk. A token-dense diff
            # can slip the LOC gate and exhaust the single-pass context chain;
            # the swallowed ContextWindowExceededError only surfaces as a
            # `fallback_exhausted` sentinel finding (dispatch.py), so a
            # try/except at the dispatch call site would catch nothing. When the
            # single-pass result carries that sentinel, re-route the diff to the
            # chunked Strategy-F path (the real fail-safe) instead of emitting
            # the synthetic finding.
            _rechunk_specs = _rechunk_on_fallback_exhausted(merged, diff_text)
            if _rechunk_specs is not None:
                print(
                    "INFO: single-pass review exhausted context (fallback_exhausted "
                    "sentinel) — re-routing to Strategy F chunked review",
                    file=sys.stderr,
                )
                _rechunk_filtered = [
                    spec
                    for spec in _rechunk_specs
                    if not all(f in _skipped_set for f in spec.get("files", []))
                ]
                if _rechunk_filtered:
                    merged = _dispatch_and_aggregate_clusters(_rechunk_filtered)

            # Step 7: apply dismissal-memory filter on cycle N≥2.
            # This is a defence-of-last-resort: if the LLM still re-emits a verbatim
            # defended finding despite receiving the full defense context, downgrade it
            # to 'suggestion' so it no longer blocks merge. (Bug c59e-a197.)
            # LEDGER-SAFE (task 36cf): SHA-reset → cycle_num=1 → prior_defenses=[] above.
            # Compound condition short-circuits to False — suppression skipped for new SHAs. Correct.
            if cycle_number >= 2 and prior_defenses:
                raw_findings = merged.get("findings") or []
                filtered = _suppress_defended_findings(raw_findings, prior_defenses)
                if filtered != raw_findings:
                    suppressed_count = sum(
                        1 for f in filtered if f.get("_suppressed_reason")
                    )
                    print(
                        f"INFO: cycle {cycle_number} — suppressed {suppressed_count} finding(s) "
                        "that matched prior defended findings (dismissal-memory filter)",
                        file=sys.stderr,
                    )
                    merged = dict(merged)
                    merged["findings"] = filtered

            # Novelty gate: downgrade unjustified NEW_INTRODUCED findings on cycle >= 2.
            # LEDGER-SAFE (task 36cf): SHA-reset → cycle_num=1 → this gate is skipped for
            # new commits. That is correct: novelty-gate requires a prior-cycle context; on a
            # fresh SHA there is no prior cycle, so all findings are genuinely NEW_INTRODUCED
            # and should not be downgraded. No behavioral change needed here.
            if cycle_number >= 2 and not _suppress_prior_defenses:
                _gated_findings, _novelty_stats = _apply_novelty_gate(
                    merged.get("findings") or [],
                    prior_defenses,
                    diff_text,
                    cycle_number,
                )
                if _novelty_stats.get("new_introduced_unjustified", 0) > 0:
                    print(
                        f"INFO: cycle {cycle_number} — novelty gate downgraded "
                        f"{_novelty_stats['new_introduced_unjustified']} finding(s) "
                        "(unjustified NEW_INTRODUCED outside prior defense window)",
                        file=sys.stderr,
                    )
                print(
                    f"INFO: cycle {cycle_number} — relation distribution: {_novelty_stats}",
                    file=sys.stderr,
                )
                merged = dict(merged)
                merged["findings"] = _gated_findings

        # Step 7a.5: early-exit for all-specialist-errors.
        # specialist_error findings may be schema-invalid (they lack cited_lines etc.),
        # which would trigger schema correction. But when ALL findings are specialist
        # errors there was no real review — schema correction cannot help. Exit early
        # before schema validation so the accurate diagnostic is surfaced instead of
        # a misleading "schema correction failed" message.
        _pre_schema_findings = merged.get("findings") or []
        if bool(_pre_schema_findings) and all(
            f.get("type") == "specialist_error" for f in _pre_schema_findings
        ):
            _write_output(merged)
            print(
                "ERROR: all specialist dispatches failed — no review findings produced "
                "(check litellm installation and API key configuration)",
                file=sys.stderr,
            )
            # R4: pre-schema all-specialist-errors is the same infrastructure-
            # failure class as the post-cycle check at line ~3200. Both must
            # return the same code so the CI classify step is consistent.
            return _infra_failure_exit_code()

        # Step 7a.75: pre-validation category remap (bug 0623-54f4-d31b-4623).
        # Normalize the 35 known off-enum category values (e.g. "code_smell",
        # "missing_test_coverage") to canonical buckets BEFORE schema validation
        # so the correction loop is reserved for genuinely-novel schema issues.
        # Mutates findings in place; canonical and unknown-off-enum values are
        # left unchanged so the validator + correction loop can still catch
        # genuinely novel off-enum values via the dispatch.py category exception.
        merged["findings"] = _remap_off_enum_categories(
            list(merged.get("findings") or [])
        )

        # Step 7b: schema validation (schema hash 214949ee476be6d0)
        # Shell out to validate-review-output.sh before writing to disk.
        # Exit-code routing:
        #   schema_pass    → continue to _write_output() unchanged
        #   schema_fail    → Step 7.5: dispatch_schema_correction inline; appends
        #                    synthetic schema_error and exits 1 if correction fails
        #   validator_error → fail-loud (CRITICAL stderr + non-zero exit), never silently skip
        _schema_result = _validate_findings_schema(merged)
        if _schema_result.status == "validator_error":
            print(
                "CRITICAL: schema validator failed — cannot validate review findings. "
                f"Errors: {'; '.join(_schema_result.errors)}",
                file=sys.stderr,
            )
            # R4: the schema validator is a subprocess that failed (not a
            # schema_fail outcome on real findings). That is an infrastructure
            # failure of the validation pipeline, not a code-review finding.
            return _infra_failure_exit_code()
        # Step 7.5: schema-correction dispatch on schema_fail
        if _schema_result.status == "schema_fail":
            _max_attempts = get_schema_correction_max_attempts()
            if _max_attempts == 0:
                # Short-circuit: append synthetic schema_error without dispatching
                _synthetic = {
                    "type": "parse_error",
                    "severity": "critical",
                    "category": "schema_error",
                    "description": (
                        "Schema correction skipped (max_attempts=0): "
                        + "; ".join(_schema_result.errors)
                    ),
                    "finding_id": "schema_error_skipped",
                    "file": "",
                    "cited_lines": [],
                    "cited_excerpt": "",
                    "reachability": "",
                }
                merged = dict(merged)
                merged["findings"] = list(merged.get("findings", [])) + [_synthetic]
                _write_output(merged)
                print(
                    "ERROR: schema correction skipped (max_attempts=0) — "
                    "synthetic schema_error appended",
                    file=sys.stderr,
                )
                return 1
            else:
                try:
                    merged = dispatch_schema_correction(
                        merged.get("findings", []),
                        _schema_result.errors,
                        diff_text=diff_text,
                        provider_chain=provider_chain,
                        agent_id="schema-correction",
                        max_attempts=_max_attempts,
                    )
                except Exception as _corr_exc:  # noqa: BLE001
                    print(
                        f"ERROR: dispatch_schema_correction raised {type(_corr_exc).__name__}: {_corr_exc}"
                        " — appending synthetic schema_error (fail-closed)",
                        file=sys.stderr,
                    )
                    _corr_synthetic = {
                        "type": "parse_error",
                        "severity": "critical",
                        "category": "schema_error",
                        "description": (
                            f"Schema correction dispatch raised {type(_corr_exc).__name__}: "
                            + "; ".join(_schema_result.errors)
                        ),
                        "finding_id": "schema_error_dispatch_failed",
                        "file": "",
                        "cited_lines": [],
                        "cited_excerpt": "",
                        "reachability": "",
                    }
                    merged = dict(merged)
                    merged["findings"] = list(merged.get("findings", [])) + [
                        _corr_synthetic
                    ]
                    _write_output(merged)
                    return 1
                # Fail-closed: if correction exhausted all retries, dispatch_schema_correction
                # appends a synthetic parse_error/schema_error finding. These findings failed
                # schema validation and must not be allowed to merge (bug: exit-0 slip-through).
                _corr_exhausted = [
                    f
                    for f in merged.get("findings", [])
                    if f.get("type") == "parse_error"
                    and f.get("category") == "schema_error"
                ]
                if _corr_exhausted:
                    merged = dict(merged)
                    merged["cycle_number"] = cycle_number
                    _write_output(merged)
                    print(
                        f"ERROR: schema correction exhausted all {_max_attempts} attempt(s) — "
                        f"synthetic schema_error present; blocking merge (fail-closed)",
                        file=sys.stderr,
                    )
                    return 1

        # Step 7c: absence-claim verifier dispatch
        # Filters minor findings (bypass); applies verifier rulings to critical/important/fragile.
        # Fail-open per-finding: verifier errors annotate finding with verifier_status="failed"
        # but do not block the review. Config gate: if review.verifier_enabled
        # is absent, verifier runs in default mode (soft).
        from dso_ci_review.verifier import dispatch_verifier  # noqa: PLC0415

        _verifier_findings = dispatch_verifier(
            merged.get("findings", []),
            reviewed_sha=reviewed_sha,
        )
        merged = dict(merged)
        merged["findings"] = _verifier_findings

        # Step 7c.5: generate finding_id for findings that lack one.
        # Agent prompts do not require the LLM to generate finding_id, and
        # no prior pipeline step assigns them. Use a content-derived hash
        # so identical findings produce stable IDs across cycles.
        for _f in merged.get("findings") or []:
            if not _f.get("finding_id") or not _FINDING_ID_RE.match(
                str(_f.get("finding_id", ""))
            ):
                _id_source = (
                    _f.get("file", "")
                    + str(_f.get("cited_lines", ""))
                    + _f.get("description", "")
                )
                _f["finding_id"] = f"f-{hashlib.sha256(_id_source.encode()).hexdigest()[:8]}"

        # Step 7d: telemetry emission (fire-and-forget, fail-open).
        # Emit one event per finding (review_finding or tool_finding), then
        # one review_cycle event aggregating usage data. All calls are
        # fire-and-forget via telemetry_emit_wrapper — any exception is
        # swallowed by the wrapper and never propagates here.
        _telemetry_findings = merged.get("findings") or []
        for _t_idx, _t_finding in enumerate(_telemetry_findings):
            _emit_finding_telemetry(_t_finding, _t_idx, cycle_number)

        # review_cycle event: aggregate usage from review-cycle-usage.json
        _usage_path = os.path.join(_artifacts_dir, "review-cycle-usage.json")
        _usage_input_tokens: int | None = None
        _usage_output_tokens: int | None = None
        try:
            if os.path.exists(_usage_path):
                with open(_usage_path, encoding="utf-8") as _uf:
                    _usage_data = json.load(_uf)
                _usage_cycles = _usage_data.get("cycles", [])
                _in_total = 0
                _out_total = 0
                for _ue in _usage_cycles:
                    if isinstance(_ue, dict):
                        _in = _ue.get("input_tokens")
                        _out = _ue.get("output_tokens")
                        if isinstance(_in, (int, float)):
                            _in_total += int(_in)
                        if isinstance(_out, (int, float)):
                            _out_total += int(_out)
                _usage_input_tokens = _in_total
                _usage_output_tokens = _out_total
        except (OSError, json.JSONDecodeError, TypeError):
            pass
        _emit_review_cycle_telemetry(
            _telemetry_findings,
            cycle_number,
            tier,
            reviewed_sha,
            usage_input_tokens=_usage_input_tokens,
            usage_output_tokens=_usage_output_tokens,
        )

        # Step 8: write output
        # Stamp the cycle number so the NEXT cycle's workflow can read it back
        # from the persisted findings.json (per-branch-review.yml uses this
        # to compute DSO_REVIEW_CYCLE for cycle 3+). Use a dict copy so we
        # don't mutate a caller-shared object.
        merged = dict(merged)
        merged["cycle_number"] = cycle_number
        _write_output(merged)

        # Step 8a: append cycle ledger entry and post cycle marker comment.
        _current_findings = merged.get("findings", [])
        _tuples = _compute_findings_tuples(_current_findings)
        _findings_hash_val = _compute_findings_hash(_tuples)
        _ledger_path = os.path.join(_artifacts_dir, "cycle-ledger.json")
        _append_cycle(
            _ledger_path,
            cycle_number,
            _tuples,
            reviewed_sha,
            _findings_hash_val,
            halt_reason=None,
            pr_number=_pr_number_for_ledger,
        )
        _post_cycle_marker_comment(
            pr_number=_pr_number_for_ledger,
            cycle_num=cycle_number,
            commit_sha=reviewed_sha,
            findings_hash=_findings_hash_val,
            tuples=_tuples,
        )

        # Step 8b: route on cycle_dispatcher action.
        # Use the PRE-APPEND ledger here, not a re-read after Step 8a.
        # cycle_dispatcher.next_action computes cycle_num as
        # last_cycle.cycle_num + 1 and uses last_cycle.findings as prior
        # for the Jaccard STABLE_HALT comparison. Passing the post-append
        # ledger would make last_cycle the cycle we JUST appended (Jaccard
        # of current findings against themselves = 1.0 → guaranteed
        # STABLE_HALT → DISPATCH_ARBITER on every cycle). The pre-append
        # ledger gives last_cycle = previous cycle, which is the correct
        # comparison surface. (Earlier "fix" for review-finding 2026-05-18
        # introduced the self-comparison bug; this reverts to the correct
        # semantics. The bug was not caught at sub-PR time because Python
        # Skill/Doc Tests is gated to base=main — bug 69e5-824a-ec7e-4bd9.)
        _action_result = cycle_next_action(
            ledger,
            max_cycles,
            _current_findings,
            reviewed_sha,
            _artifacts_dir,
            pr_number=_pr_number_for_ledger,
            repo=_repo_for_ledger,
        )
        _action = _action_result.get("action", "DISPATCH_NEXT")

        if _action == "PASS":
            _post_cycle_marker_comment(
                pr_number=_pr_number_for_ledger,
                cycle_num=cycle_number,
                commit_sha=reviewed_sha,
                findings_hash="pass",
                tuples=[],
            )
            return 0

        if _action == "SHORT_CIRCUIT":
            print(
                "WARNING: unexpected SHORT_CIRCUIT post-review — "
                "pre-check should have caught this",
                file=sys.stderr,
            )
            return 0

        if _action == "DISPATCH_ARBITER":
            _reviewer_breakdown = _build_reviewer_breakdown(merged)
            _finding_map = {i: f for i, f in enumerate(_current_findings)}
            _arbiter_result = dispatch_cycle_end_arbiter(
                findings=_current_findings,
                defenses=prior_defenses,
                diff_text=diff_text,
                model=base_model,
                provider_chain=provider_chain,
                cycle_num=cycle_number,
                max_cycles=max_cycles,
                reviewer_breakdown=_reviewer_breakdown,
                ledger_history=ledger.get("cycles", []),
            )
            # dispatch_cycle_end_arbiter returns a list of ruling dicts directly.
            _rulings = (
                _arbiter_result
                if isinstance(_arbiter_result, list)
                else _arbiter_result.get("rulings", [])
            )
            _process_result = process_rulings(
                _rulings,
                _finding_map,
                cycle_number,
                commit_sha=reviewed_sha,
                pr_number=int(pr_number) if pr_number else None,
                branch_name=None,
                ticket_cmd_path=".claude/scripts/dso",
                artifacts_dir=artifacts_dir,
                repo_root=repo,
            )
            _arbiter_marker = format_arbiter_marker(
                cycle_num=cycle_number, commit_sha=reviewed_sha
            )
            _arbiter_body = (
                f"{_arbiter_marker}\n\n### Arbiter Rulings\n\n"
                f"```json\n{json.dumps(_rulings, indent=2)}\n```"
            )
            _post_arbiter_comment(
                cycle_number,
                reviewed_sha,
                _rulings,
                _finding_map,
                pr_number,
                body=_arbiter_body,
            )
            return 1 if _process_result.get("block") else 0

        # DISPATCH_NEXT: fall through to existing severity gate below the try/except.
    except Exception as exc:  # noqa: BLE001
        # Bug 7f55: this except wraps the entire post-dispatch pipeline
        # (LLM dispatch + aggregator + schema correction + telemetry —
        # roughly 770 lines), not just the LLM HTTP call. Naming the log
        # "LLM call failed" misleads operators who go hunting for an
        # HTTP-call defect when the actual crash was in aggregation or
        # schema. Surface the exception class AND the traceback so the
        # call site is identifiable from the CI log alone — without
        # this, we lose minutes per cycle re-deriving the file:line.
        import traceback as _tb
        print(
            f"ERROR: review pipeline crashed: {type(exc).__name__}: {exc}",
            file=sys.stderr,
        )
        print(
            "TRACEBACK:\n" + _tb.format_exc(),
            file=sys.stderr,
        )
        # c131-0f34 defense-in-depth: always write a findings record before
        # returning so the workflow-side liveness assertion has something to
        # observe. Without this, an unhandled exception between Step 1 and
        # Step 8 left the gating job with exit 1 but no artifact — a future
        # regression that swallowed the exception would silently exit 0 with
        # no signal at all. The synthetic specialist_error stamps the
        # cycle_number so downstream consumers can still attribute the run.
        # Sanitize the exception text before serializing — `repr(exc)` can
        # include sensitive values (API keys embedded in URL paths or
        # request headers when an HTTP client surfaces them in the message)
        # and this artifact is uploaded for inspection (c131-0f34 review
        # cycle 3). Emit the class name plus a 200-char message tail with
        # common secret-looking patterns redacted.
        _exc_class = type(exc).__name__
        _exc_msg = str(exc)[:200]
        # Redact bearer-token / Authorization-header / sk-… style patterns.
        _exc_msg = re.sub(
            r"(?i)(bearer|authorization|api[-_]?key|token)[=:\s]+\S+",
            r"\1=[REDACTED]",
            _exc_msg,
        )
        _exc_msg = re.sub(r"\bsk-[A-Za-z0-9_-]{8,}", "sk-[REDACTED]", _exc_msg)
        try:
            _write_output(
                {
                    "findings": [
                        {
                            "type": "specialist_error",
                            "severity": "critical",
                            "category": "infrastructure",
                            "description": f"runner exception before Step 8: {_exc_class}: {_exc_msg}",
                        }
                    ],
                    "cycle_number": cycle_number,
                }
            )
        except Exception:  # noqa: BLE001
            pass  # ensure the original failure is not masked by a write error
        # R4: runner crash is an infrastructure failure, not a code-review finding.
        return _infra_failure_exit_code()

    # Detect all-specialist-error: every finding is a specialist_error with no real review.
    # Exit 4 (R4: infrastructure failure) instead of 1 so the CI workflow's classify
    # step can distinguish this from "review found problems" (fcea-6e83 originally
    # exited 1; PR-C reframes the meaning rather than removing the gate).
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
        return _infra_failure_exit_code()

    # Block (fail-closed) when all findings are synthetic (a8f6-4c5e reverses e840-327f).
    # An all-synthetic outcome means zero usable review content was produced — no valid
    # reviewer ever ran. Blocking prevents silent approval of unreviewed PRs.
    # R4: also exit 4 (infrastructure failure) for the same operator-clarity reason —
    # all-synthetic findings explicitly mean "no usable review content", which is an
    # infrastructure outcome rather than a real-code finding.
    if _findings and all(f.get("type", "") in _SYNTHETIC_TYPES for f in _findings):
        print(
            f"ERROR: all {len(_findings)} finding(s) are synthetic "
            f"({'/'.join(sorted(_SYNTHETIC_TYPES))}) — no valid review content produced",
            file=sys.stderr,
        )
        return _infra_failure_exit_code()

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
