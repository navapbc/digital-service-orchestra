"""dso_ci_review.region_split — Region-split FALLBACK for large diffs.

Strategy E: when a diff exceeds the LOC or file-count threshold, split it into
per-directory clusters, dispatch specialists per cluster in parallel, then run
arch synthesis over the merged findings.

Story f5f9-9a3c-c7be-4d11: Strategy E region-split FALLBACK in CI llm-review pipeline.

## File atomicity invariant (bug 532e-6ab7)

A single source file is the atomic unit of code review and MUST NEVER be split
across reviewer clusters. Two consequences are enforced:

1. Diffs that touch exactly one file are NEVER region-split, regardless of how
   large their LOC count is. The single-cluster output of `_cluster_files` would
   be a no-op anyway, and the explicit short-circuit signals intent and avoids
   the synthesis overhead.

2. `_cluster_files` groups by immediate parent directory and is constructed so
   each path lands in exactly one cluster. A runtime assertion enforces this
   invariant so that any future refactor introducing hunk-level splitting (or a
   path appearing in two clusters via overflow) will fail immediately rather
   than silently fragment cross-hunk context within one file.
"""

from __future__ import annotations

import asyncio
import json
import re
import sys
from collections import Counter
from typing import Any

from dso_ci_review._config import read_config_int
from dso_ci_review.dispatch import async_dispatch_specialists, dispatch_arch_synthesis

# Synthesized cluster label for files merged when the directory count exceeds
# _max_clusters(). Double-underscore-wrapped to avoid collision with a real
# directory literally named "overflow/" (PR #169 review f-overflow-sentinel-
# collision: previously a real ``overflow/`` directory could be overwritten by
# the synthesized cluster of the same name).
_OVERFLOW_LABEL = "__overflow__"


class RegionSplitInvariantError(Exception):
    """Raised when region-split's structural invariants are violated.

    Replaces AssertionError for the file-atomicity check (PR #169 review
    f-assertion-error-style): raising AssertionError from production code is
    conventionally reserved for ``assert`` statements and can be rewritten or
    swallowed by some tooling. A domain-specific exception is easier to catch,
    log, and report in CI.
    """


# Threshold defaults — overridable via dso-config.conf keys:
#   review.region_split.loc_threshold        (default 3000)
#   review.region_split.file_count_threshold (default 40)
#   review.region_split.max_clusters         (default 5)
# Resolution is per-call via read_config_int(); these defaults apply when
# the key is absent or the value is not a valid integer.
#
# Sizing rationale (bug 532e-6ab7 re-assessment):
# Region-split exists to keep the reviewer's input under the model's context
# window. For Sonnet 4.6 (200K input tokens, ~180K usable after the output
# reserve) and overhead of ~15-25K tokens for system prompt + finding schema
# + PR metadata + prior defenses, the diff content budget is ~155K tokens.
# At ~4-5 tokens per diff line, that's room for 30,000-38,000 LOC before
# context becomes the bottleneck.
#
# The previous defaults (LOC=400, files=15) used <2% of that budget and
# triggered region-split on routine refactors-with-companion-tests (e.g.,
# PR #165: 688 LOC, 7 files), fragmenting cross-file context with no
# context-pressure justification. The new defaults sit at ~7-10% of the
# Sonnet diff budget, capturing the common-case PR atomically while still
# bounding worst-case prompt growth.
#
# Projects on smaller-context models should lower these via config keys.
_LOC_THRESHOLD_DEFAULT = 3000
_MAX_CLUSTERS_DEFAULT = 5
_CLUSTER_CONCURRENCY_DEFAULT = 2
_CLUSTER_CONCURRENCY_HARD_CAP = 3

# Region-split GATE thresholds — decoupled from the per-cluster Strategy-F
# FAN-OUT thresholds above (component #3' of the chunked-review FP-reduction
# proposal).
#
# Why decouple (M-1 measurement): cross-chunk hallucinated-reference FPs are
# 55% of chunked-review false positives — a reviewer flags a symbol/test as
# "undefined" because it lives in a *different* chunk it cannot see. Single-pass
# review has zero cross-chunk blindness. #3' therefore raises the GATE that
# decides *whether to chunk at all* (independently of the FAN-OUT thresholds
# that decide how finely an already-chunked diff is partitioned per cluster),
# so most medium-large PRs review single-pass.
#
# Sizing: the sizing note above computes a real Sonnet 4.6 ceiling of
# 30,000-38,000 diff-content LOC before context pressure. The OLD shared
# default (3000) sat at only ~7-10% of budget and chunked routine medium PRs
# for no context reason. The gate default (20000) is a conservative ~55-65% of
# the ceiling — well clear of context pressure but leaving headroom for system
# prompt + finding schema + PR metadata + prior-defense growth. The fan-out
# fan-out threshold (_LOC_THRESHOLD_DEFAULT) is left UNCHANGED: once a diff is
# large enough to chunk, the per-cluster partition granularity is a separate
# concern.
#
# Config keys:
#   review.region_split.gate_loc         (default 20000) — primary GATE LOC.
#   review.region_split.gate_file_count  (default 120)   — GATE file-count OR-guard.
_GATE_LOC_THRESHOLD_DEFAULT = 20000
_GATE_FILE_COUNT_THRESHOLD_DEFAULT = 120

# Floor coupling the gate to the size-tier upgrade. review.size_upgrade_lines
# force-upgrades any diff at/above its value to the deep tier, which uses
# single-pass deep-arch synthesis. The region-split GATE must never fire on a
# diff that has NOT already been size-upgraded to deep — otherwise a
# region-split-eligible diff could be reviewed by a non-deep single-pass path,
# losing the deep synthesis. So gate_loc MUST be strictly greater than the
# active size_upgrade_lines value; _gate_loc_threshold() clamps any smaller
# configured value up.
#
# IMPORTANT — SYNCHRONIZED CONSTANT: 300 MUST stay in lockstep with the DEFAULT
# of `review.size_upgrade_lines`. It is the SAFE floor used when that config key
# is absent or LOWERED below 300. The clamp also reads the *configured*
# size_upgrade_lines at call time (see _gate_loc_threshold) so a RAISED value is
# respected dynamically: the effective floor is max(300, configured) + 1. If the
# size_upgrade_lines default ever changes, update this constant to match.
_SIZE_UPGRADE_LINES_FLOOR = 300


def _loc_threshold() -> int:
    """Resolved LOC threshold for region-split (default 3000).

    Values ≤ 0 from config (invalid — would disable LOC gating entirely or
    invert the comparison) fall back to the default.
    """
    value = read_config_int(
        "review.region_split.loc_threshold", _LOC_THRESHOLD_DEFAULT
    )
    return value if value > 0 else _LOC_THRESHOLD_DEFAULT


def _gate_loc_threshold() -> int:
    """Resolved LOC threshold for the region-split GATE (default 20000).

    Component #3': this is the threshold that decides *whether to chunk at all*
    — distinct from ``_loc_threshold()`` which governs the per-cluster
    Strategy-F fan-out. See the _GATE_LOC_THRESHOLD_DEFAULT block for the
    decoupling rationale.

    Two correctness rules are enforced here:

    1. Values <= 0 from config (which would disable LOC gating entirely or
       invert the comparison) fall back to the default.
    2. The invariant ``gate_loc > review.size_upgrade_lines`` (the
       force-upgrade-to-deep floor) is enforced by clamping any smaller
       configured value UP to ``effective_floor + 1``. The effective floor is
       computed DYNAMICALLY as ``max(_SIZE_UPGRADE_LINES_FLOOR, configured
       review.size_upgrade_lines)``:
         - A RAISED size_upgrade_lines (e.g. 500) raises the floor so the
           invariant still holds (clamp to 501, not the stale 301).
         - A LOWERED size_upgrade_lines (e.g. 100) cannot drag the floor below
           the safe synchronized default (_SIZE_UPGRADE_LINES_FLOOR=300).
       This keeps a region-split-eligible diff always already deep-tier,
       preserving single-pass deep synthesis. A clamp emits a warning to stderr.
    """
    value = read_config_int(
        "review.region_split.gate_loc", _GATE_LOC_THRESHOLD_DEFAULT
    )
    if value <= 0:
        return _GATE_LOC_THRESHOLD_DEFAULT
    # Effective floor: never below the safe synchronized default, but track a
    # raised size_upgrade_lines so the gate_loc > size_upgrade_lines invariant
    # holds dynamically.
    configured_size_upgrade = read_config_int(
        "review.size_upgrade_lines", _SIZE_UPGRADE_LINES_FLOOR
    )
    effective_floor = max(_SIZE_UPGRADE_LINES_FLOOR, configured_size_upgrade)
    if value <= effective_floor:
        clamped = effective_floor + 1
        print(
            f"WARNING: review.region_split.gate_loc={value} is <= the "
            f"size_upgrade_lines floor ({effective_floor}); clamping up to "
            f"{clamped} so region-split-eligible diffs stay deep-tier "
            "(single-pass synthesis).",
            file=sys.stderr,
        )
        return clamped
    return value


def _gate_file_count_threshold() -> int:
    """Resolved file-count threshold for the region-split GATE (default 120).

    Component #3' secondary OR-guard: a diff trips the gate when it exceeds
    EITHER gate_loc OR this file count. There is no file-count-based per-cluster
    fan-out counterpart — the fan-out keys off LOC only (``_loc_threshold()``).
    Values <= 0 from config fall back to the default.
    """
    value = read_config_int(
        "review.region_split.gate_file_count", _GATE_FILE_COUNT_THRESHOLD_DEFAULT
    )
    return value if value > 0 else _GATE_FILE_COUNT_THRESHOLD_DEFAULT


def _max_clusters() -> int:
    """Resolved cluster fan-out cap (default 5).

    Values < 1 from config (which would prevent any cluster being kept) fall
    back to the default.
    """
    value = read_config_int(
        "review.region_split.max_clusters", _MAX_CLUSTERS_DEFAULT
    )
    return value if value >= 1 else _MAX_CLUSTERS_DEFAULT


def _cluster_concurrency() -> int:
    """Resolved per-cycle max concurrent cluster dispatches (default 2).

    Capped at min(max_clusters(), 3) to keep in-flight LLM calls within the
    Anthropic concurrent-connection ceiling (anthropic-sdk-python #496:
    ~10+ concurrent AsyncAnthropic calls 429 even under quota). With ~3
    specialists per cluster, concurrency=2 → 6 in-flight calls. The hard cap
    of 3 keeps deep-tier (4 specialists) safely under the wall at 3 × 4 = 12.

    Values < 1 from config fall back to the default.
    """
    value = read_config_int(
        "review.region_split.cluster_concurrency", _CLUSTER_CONCURRENCY_DEFAULT
    )
    if value < 1:
        value = _CLUSTER_CONCURRENCY_DEFAULT
    return min(value, _max_clusters(), _CLUSTER_CONCURRENCY_HARD_CAP)


def _extract_filenames(diff_text: str) -> list[str]:
    """Extract the set of filenames touched by ``diff_text``, deduplicated and
    ordered by first appearance.

    Reads both ``diff --git a/X b/X`` and ``+++ b/X`` headers — the union
    catches pure-deletion diffs (whose ``+++`` is ``/dev/null``) and
    binary-only diffs (which may carry ``diff --git`` but no ``+++ b/...``
    text marker).

    PR #169 review f-gate-vs-clustering-divergence: previously the gate
    (``_should_region_split``) used the union but the clustering path
    (``_async_run_region_split``) used only ``+++ b/...``. A multi-file diff
    that included a deletion was counted by the gate but the deleted file
    was dropped before clustering — silently bypassing review. Unifying file
    extraction here ensures the gate and the clustering operate on the same
    file set, so the post-cluster atomicity check has a faithful baseline.
    """
    seen: set[str] = set()
    ordered: list[str] = []

    for line in diff_text.splitlines():
        m = re.match(r"^diff --git a/(\S+) b/\S+", line)
        if m:
            path = m.group(1)
            if path not in seen:
                seen.add(path)
                ordered.append(path)
            continue
        m = re.match(r"^\+\+\+ b/(\S+)", line)
        if m:
            path = m.group(1)
            if path not in seen:
                seen.add(path)
                ordered.append(path)

    return ordered


def _should_region_split(diff_text: str) -> bool:
    """Return True when diff exceeds the region-split GATE thresholds.

    Component #3': this GATE decides *whether to chunk at all*. It uses the
    dedicated ``_gate_loc_threshold()`` (default 20000) and
    ``_gate_file_count_threshold()`` (default 120) — NOT the per-cluster
    Strategy-F fan-out threshold (``_loc_threshold``, default 3000) which only
    partitions an already-chunked diff. The raised gate keeps medium-large PRs
    single-pass, eliminating cross-chunk hallucinated-reference false positives
    (55% of chunked-review FPs per M-1).

    LOC gate: count lines starting with + or - but NOT +++ or --- (diff headers).
    File gate: count distinct filenames using ``_extract_filenames`` — the
    same helper used by the clustering path (PR #169 fix for gate-vs-
    clustering divergence).

    Single-file atomicity short-circuit (bug 532e-6ab7): if the diff touches
    exactly one file, return False regardless of LOC count. A single source
    file is the atomic unit of code review and MUST NEVER be region-split — the
    review of a 2000-line change in one file must always reach a single
    specialist with full context, never be partitioned by hunk.
    """
    loc_count = 0
    for line in diff_text.splitlines():
        # Count added/removed lines (exclude +++ and --- header lines)
        if line.startswith("+") and not line.startswith("+++"):
            loc_count += 1
        elif line.startswith("-") and not line.startswith("---"):
            loc_count += 1

    file_set = set(_extract_filenames(diff_text))

    # File-atomicity floor: never region-split a single-file diff (bug 532e-6ab7).
    # This MUST be checked before the LOC threshold so that a large change in
    # one file is reviewed atomically rather than triggering a no-op single-
    # cluster region-split.
    if len(file_set) <= 1:
        return False

    # Component #3': the GATE (whether to chunk at all) uses the dedicated,
    # raised gate thresholds — NOT the per-cluster fan-out threshold
    # (_loc_threshold). Decoupling these is the core
    # of #3': it keeps medium-large PRs single-pass (zero cross-chunk
    # hallucinated-reference FPs) while leaving the fan-out granularity of an
    # already-chunked diff unchanged. Resolve into locals so each comparison
    # doesn't re-invoke the reader.
    loc_t = _gate_loc_threshold()
    file_t = _gate_file_count_threshold()

    if loc_count > loc_t:
        return True
    if len(file_set) > file_t:
        return True
    return False


def _cluster_files(filenames: list[str]) -> dict[str, list[str]]:
    """Group filenames by their immediate parent directory.

    - Files with a directory component land in ``"<dir>"`` cluster.
    - Top-level files (no directory) land in ``"."`` cluster.
    - If more than ``_max_clusters()`` distinct directories exist, the smallest
      clusters beyond the top (_max_clusters() - 1) are merged into the
      ``_OVERFLOW_LABEL`` (``"__overflow__"``) cluster.

    Returns a dict mapping cluster label → list of filenames. Non-overflow
    clusters store BASENAMES (per the original API contract); the
    ``_OVERFLOW_LABEL`` cluster, when present, stores FULL PATHS so the
    downstream extractor can re-locate hunks (PR #169 fix: previously
    overflow lost the parent directory, producing nonexistent
    ``overflow/<basename>`` lookups and a silent fall-through to whole-diff
    dispatch).

    File-atomicity invariant (bug 532e-6ab7): every input file appears in
    exactly one cluster. A single source file is the atomic unit of code
    review and must never be partitioned across reviewer specialists.
    Enforced by ``_assert_file_atomicity`` — an identity-based Counter
    comparison (not just count preservation) so a drop+duplicate cannot
    pass silently.
    """
    dir_map: dict[str, list[str]] = {}

    for path in filenames:
        parts = path.rsplit("/", 1)
        if len(parts) == 1:
            # No directory component
            directory = "."
            basename = parts[0]
        else:
            directory = parts[0]
            basename = parts[1]

        dir_map.setdefault(directory, []).append(basename)

    # Resolve cluster cap ONCE (PR #169 perf: avoid re-reading config on each
    # comparison / slice; the function previously invoked _max_clusters() 4×).
    max_c = _max_clusters()

    if len(dir_map) <= max_c:
        result = dir_map
    else:
        # Merge smallest clusters beyond top (max_c - 1) into the overflow
        # sentinel. Sort by cluster size descending, keep the largest
        # (max_c - 1).
        sorted_dirs = sorted(dir_map.items(), key=lambda kv: len(kv[1]), reverse=True)
        kept = sorted_dirs[: max_c - 1]
        overflow_dirs = sorted_dirs[max_c - 1 :]

        result = {d: files for d, files in kept}
        # Overflow stores FULL PATHS (parent dir + basename) so _extract_cluster_diff
        # can match the diff hunks. Top-level files (directory == ".") stay as
        # basenames since their "full path" is identical to their basename.
        overflow_files: list[str] = []
        for overflow_dir, files in overflow_dirs:
            if overflow_dir == ".":
                overflow_files.extend(files)
            else:
                overflow_files.extend(f"{overflow_dir}/{f}" for f in files)
        if overflow_files:
            result[_OVERFLOW_LABEL] = overflow_files

    _assert_file_atomicity(filenames, result)
    return result


def _assert_file_atomicity(
    input_filenames: list[str], clusters: dict[str, list[str]]
) -> None:
    """Enforce: every input file appears across all clusters with the same
    multiplicity (bug 532e-6ab7).

    Identity-based check (PR #169 review f-counter-not-count): reconstruct
    the full set of file identities by combining each cluster's label with
    its entries (for non-overflow / non-top-level clusters), or treating the
    entries as full paths verbatim (for ``.`` and ``_OVERFLOW_LABEL``).
    Compare the reconstructed multiset against the input via
    ``collections.Counter`` so a drop + duplicate (which preserves count
    but corrupts identity) is caught.

    A single source file is the atomic unit of code review and must NEVER be
    partitioned across reviewer specialists. Region-split clusters by
    directory; within one cluster, a file's hunks are forwarded together by
    ``_extract_cluster_diff``'s in_target toggling. The atomicity invariant
    documented here protects both properties.

    Raises ``RegionSplitInvariantError`` (not AssertionError — PR #169
    review f-assertion-error-style) so callers can catch a domain-specific
    failure and so the message survives ``python -O``.
    """
    reconstructed: list[str] = []
    for cluster_dir, cluster_entries in clusters.items():
        if cluster_dir in {".", _OVERFLOW_LABEL}:
            reconstructed.extend(cluster_entries)
        else:
            reconstructed.extend(f"{cluster_dir}/{name}" for name in cluster_entries)

    in_counter = Counter(input_filenames)
    out_counter = Counter(reconstructed)
    if out_counter != in_counter:
        missing = dict(in_counter - out_counter)
        extra = dict(out_counter - in_counter)
        raise RegionSplitInvariantError(
            "File-atomicity invariant violated (bug 532e-6ab7): clustered "
            "file identities do not match input identities. "
            f"missing={missing}, extra={extra}. A single source file must "
            "land in exactly one cluster entry."
        )


def _extract_cluster_diff(diff_text: str, cluster_dir: str, cluster_files: list[str]) -> str:
    """Extract diff hunks relevant to the given cluster.

    Builds the set of full paths by combining cluster_dir with each basename
    for ordinary clusters. For the ``.`` (top-level) and ``_OVERFLOW_LABEL``
    pseudo-clusters, ``cluster_files`` is already a list of full paths and
    is used verbatim (PR #169: overflow now stores full paths so the lookup
    actually matches the diff hunks).

    Returns a substring of diff_text containing only those file sections.
    """
    if cluster_dir in {".", _OVERFLOW_LABEL}:
        full_paths = set(cluster_files)
    else:
        full_paths = {f"{cluster_dir}/{f}" for f in cluster_files}

    lines = diff_text.splitlines()
    result_lines: list[str] = []
    in_target = False

    for line in lines:
        # `diff --git a/PATH b/PATH` is the canonical file-section delimiter.
        # PR #169: previously only +++/--- toggled in_target, so a `diff --git`
        # line for a NON-target file could leak through when it immediately
        # followed a target file's last hunk (in_target was still True until
        # the next +++/--- arrived). Check this first.
        m0 = re.match(r"^diff --git a/(\S+) b/\S+", line)
        if m0:
            path = m0.group(1)
            in_target = path in full_paths

        # +++ b/... — start of new-file marker
        m = re.match(r"^\+\+\+ b/(\S+)", line)
        if m:
            path = m.group(1)
            in_target = path in full_paths

        # --- a/... — start of old-file marker
        m2 = re.match(r"^--- a/(\S+)", line)
        if m2:
            path = m2.group(1)
            in_target = path in full_paths

        if in_target:
            result_lines.append(line)

    return "\n".join(result_lines) if result_lines else diff_text


async def _async_run_region_split(
    diff_text: str,
    tier_agents: list[dict[str, Any]],
    provider_chain: list[str],
    config_path: str | None,
    prior_defenses: list[dict] | None = None,
) -> dict[str, Any]:
    """Async implementation of region-split dispatch."""
    # 1. Extract filenames from diff and cluster them. Use the shared helper
    # so this path sees the SAME file set as the gate (_should_region_split)
    # — including pure-deletion / binary-only entries that the prior +++-only
    # extraction silently dropped (PR #169 review f-gate-vs-clustering-
    # divergence).
    filenames = _extract_filenames(diff_text)

    clusters = _cluster_files(filenames)
    print(
        f"INFO: region-split clusters: {{{', '.join(f'{d}: {len(files)} files' for d, files in clusters.items())}}}",
        file=sys.stderr,
    )

    # 2 & 3. For each cluster, extract its diff hunk and dispatch specialists in parallel
    async def _dispatch_cluster(cluster_dir: str, cluster_file_list: list[str]) -> list[dict]:
        cluster_diff = _extract_cluster_diff(diff_text, cluster_dir, cluster_file_list)
        print(
            f"INFO: dispatching specialists for cluster {cluster_dir} ({len(cluster_file_list)} files)",
            file=sys.stderr,
        )
        # Build agents with the cluster diff substituted in
        cluster_agents = []
        for agent in tier_agents:
            cluster_agent = dict(agent)
            cluster_agent["diff_text"] = cluster_diff
            cluster_agents.append(cluster_agent)
        return await async_dispatch_specialists(cluster_agents)

    cluster_tasks = [
        _dispatch_cluster(cluster_dir, cluster_file_list)
        for cluster_dir, cluster_file_list in clusters.items()
    ]
    cluster_results = await asyncio.gather(*cluster_tasks)

    # 4. Collect all findings from all clusters
    all_findings: list[dict] = []
    for specialist_results in cluster_results:
        for result in specialist_results:
            if isinstance(result, dict):
                all_findings.extend(result.get("findings", []))

    # 5. Call dispatch_arch_synthesis with merged findings + full diff
    merged_findings_json = json.dumps(all_findings, indent=2)
    # On cycle N≥2 with prior defenses, append them so the arch synthesizer can avoid
    # re-emitting defended findings. Mirrors the non-region-split deep-tier path.
    if prior_defenses:
        merged_findings_json += (
            "\n\n## Prior round defenses (do NOT re-emit findings that have been defended)\n\n"
            + json.dumps(prior_defenses, indent=2)
        )
    # Use the model from the first agent if available, else a sensible default
    arch_model = "claude-opus-4-7"
    if tier_agents:
        arch_model = tier_agents[0].get("model", arch_model)

    arch_result = dispatch_arch_synthesis(
        merged_findings_json=merged_findings_json,
        diff_text=diff_text,
        model=arch_model,
        provider_chain=provider_chain,
    )

    # 6. Return merged findings including arch synthesis results
    arch_findings = arch_result.get("findings", []) if isinstance(arch_result, dict) else []
    all_findings.extend(arch_findings)

    return {"findings": all_findings}


def run_region_split(
    diff_text: str,
    tier_agents: list[dict[str, Any]],
    provider_chain: list[str],
    config_path: str | None,
    prior_defenses: list[dict] | None = None,
) -> dict[str, Any]:
    """Synchronous entry point for region-split dispatch.

    Clusters the diff by directory, dispatches specialists per cluster in parallel,
    then runs arch synthesis over merged findings.

    Returns a dict with a "findings" key containing all findings from all clusters
    plus the arch synthesis result.
    """
    return asyncio.run(
        _async_run_region_split(
            diff_text, tier_agents, provider_chain, config_path, prior_defenses
        )
    )


def _count_cluster_loc(cluster_dir: str, cluster_files: list[str], diff_text: str) -> int:
    """Count the number of added/removed lines in the given cluster.

    Used by Strategy F to determine whether a cluster exceeds the per-cluster
    LOC threshold and requires per-file fan-out.
    """
    cluster_diff = _extract_cluster_diff(diff_text, cluster_dir, cluster_files)
    loc = 0
    for line in cluster_diff.splitlines():
        if line.startswith("+") and not line.startswith("+++"):
            loc += 1
        elif line.startswith("-") and not line.startswith("---"):
            loc += 1
    return loc


def split_cluster_by_file(
    cluster_dir: str,
    cluster_files: list[str],
    diff_text: str,
) -> list[dict[str, Any]]:
    """Strategy F: split an oversized cluster into per-file sub-clusters.

    Each output cluster contains exactly ONE file from the input cluster — the
    file-atomicity invariant is preserved. A single file is NEVER split by hunk
    across multiple clusters.

    For a cluster with a single oversized file (LOC > _loc_threshold()), the
    file is passed through as-is with oversized_single_file=True so downstream
    callers (aggregator + reviewer) can apply graceful truncation / visibility
    trailers. This is a pass-through, NOT a split — the file-atomicity invariant
    is NOT violated.

    Args:
        cluster_dir: The directory label for the cluster (from Strategy E).
        cluster_files: List of filenames in this cluster (basenames for ordinary
            clusters; full paths for "." and "__overflow__" pseudo-clusters).
        diff_text: Full diff text for hunk extraction.

    Returns:
        A list of single-file dispatch specs, each with keys:
            "cluster_dir": str — the directory this file belongs to
            "files": list[str] — list with exactly one filename (basename or full path)
            "diff": str — the diff hunk for this file
            "oversized_single_file": bool — True when the file's LOC exceeds the
                threshold and it is the only file in the cluster (pass-through flag
                for downstream handling; see AC amendment in ticket ef84-f980-d798-479e).
    """
    threshold = _loc_threshold()
    result: list[dict[str, Any]] = []

    for filename in cluster_files:
        # Extract the diff for just this single file
        file_diff = _extract_cluster_diff(diff_text, cluster_dir, [filename])

        # Count LOC for this file to detect single-oversized-file case
        file_loc = 0
        for line in file_diff.splitlines():
            if line.startswith("+") and not line.startswith("+++"):
                file_loc += 1
            elif line.startswith("-") and not line.startswith("---"):
                file_loc += 1

        # Single-oversized-file pass-through (AC amendment, ticket ef84-f980-d798-479e):
        # When a cluster has exactly ONE file and that file exceeds the LOC threshold,
        # dispatch it as-is with oversized_single_file=True. Downstream (aggregator +
        # reviewer) handles graceful truncation. The file is NOT split by hunk — that
        # would violate the file-atomicity invariant.
        is_oversized_single_file = (len(cluster_files) == 1 and file_loc > threshold)

        # Build the full path for the "files" field so callers can filter and
        # reconstruct paths unambiguously. For "." and "__overflow__" pseudo-clusters
        # the input filenames are already full paths; for ordinary directory clusters
        # we prefix with cluster_dir to produce the canonical full path.
        if cluster_dir in {".", _OVERFLOW_LABEL}:
            full_path = filename
        else:
            full_path = f"{cluster_dir}/{filename}"

        result.append({
            "cluster_dir": cluster_dir,
            "files": [full_path],
            "diff": file_diff,
            "oversized_single_file": is_oversized_single_file,
        })

    return result


def run_region_split_strategy_f(
    diff_text: str,
    threshold: int | None = None,
) -> list[dict[str, Any]]:
    """Strategy F orchestrator: per-file fan-out for oversized clusters.

    Strategy F extends Strategy E: after Strategy E clusters the diff by directory,
    any cluster whose total LOC count >= threshold is fanned out to one dispatch
    per file (split_cluster_by_file). Clusters below the threshold remain at
    Strategy E granularity (one dispatch per directory cluster).

    File-atomicity invariant: a single file is NEVER split across reviewers.
    RegionSplitInvariantError is NOT raised by Strategy F output (each per-file
    cluster contains exactly one file from the input cluster).

    Args:
        diff_text: Full diff text to cluster and optionally fan out.
        threshold: LOC threshold for per-cluster fan-out. Defaults to
            _loc_threshold() (config key review.region_split.loc_threshold,
            default 3000).

    Returns:
        A flat list of dispatch specs (each spec is one cluster to review):
        - For oversized clusters: N per-file specs (one per file in the cluster)
        - For under-threshold clusters: 1 directory-level spec (Strategy E, unchanged)

        Each spec has:
            "cluster_dir": str
            "files": list[str]
            "diff": str
            "oversized_single_file": bool (True only for single-file oversized pass-through)
    """
    if threshold is None:
        threshold = _loc_threshold()

    filenames = _extract_filenames(diff_text)
    clusters = _cluster_files(filenames)

    dispatch_specs: list[dict[str, Any]] = []

    for cluster_dir, cluster_file_list in clusters.items():
        cluster_loc = _count_cluster_loc(cluster_dir, cluster_file_list, diff_text)

        if cluster_loc >= threshold:
            # Strategy F: fan out to per-file dispatches
            per_file_specs = split_cluster_by_file(
                cluster_dir=cluster_dir,
                cluster_files=cluster_file_list,
                diff_text=diff_text,
            )
            dispatch_specs.extend(per_file_specs)
        else:
            # Strategy E: keep as directory-level dispatch (unchanged)
            cluster_diff = _extract_cluster_diff(diff_text, cluster_dir, cluster_file_list)
            # Build full paths for the "files" field so callers can filter by path
            if cluster_dir in {".", _OVERFLOW_LABEL}:
                full_paths = list(cluster_file_list)
            else:
                full_paths = [f"{cluster_dir}/{f}" for f in cluster_file_list]
            dispatch_specs.append({
                "cluster_dir": cluster_dir,
                "files": full_paths,
                "diff": cluster_diff,
                "oversized_single_file": False,
            })

    return dispatch_specs
