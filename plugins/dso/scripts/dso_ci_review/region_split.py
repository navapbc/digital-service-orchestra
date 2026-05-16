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
import os
import re
import sys
from typing import Any

from dso_ci_review.dispatch import async_dispatch_specialists, dispatch_arch_synthesis

# Threshold defaults — overridable via dso-config.conf keys:
#   review.region_split.loc_threshold        (default 3000)
#   review.region_split.file_count_threshold (default 40)
#   review.region_split.max_clusters         (default 5)
# Resolution is per-call via _read_config_int(); these defaults apply when
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
_FILE_COUNT_THRESHOLD_DEFAULT = 40
_MAX_CLUSTERS_DEFAULT = 5


def _default_config_path() -> str:
    """Return the canonical dso-config.conf path for the repo containing this module.

    region_split.py lives 5 dirname levels below repo_root/.claude/dso-config.conf:
    region_split.py → dso_ci_review/ → scripts/ → dso/ → plugins/ → repo_root/

    Duplicated from runner.py's _default_config_path to avoid a circular import
    (runner imports region_split, so region_split cannot import from runner).
    Keep these two implementations in sync.
    """
    return os.path.join(
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


def _read_config_int(key: str, default: int, config_path: str | None = None) -> int:
    """Read an integer config value from dso-config.conf.

    Duplicated from runner.py to avoid a circular import. Keep in sync.

    Resolution order:
      1. key=<value> in config_path (or auto-detected repo config)
      2. default (returned when key absent or value not a valid integer)
    """
    if config_path is None:
        config_path = _default_config_path()

    if os.path.isfile(config_path):
        try:
            with open(config_path, encoding="utf-8") as fh:
                for line in fh:
                    line = line.strip()
                    if not line or line.startswith("#"):
                        continue
                    parts = line.split("=", 1)
                    if len(parts) == 2 and parts[0].strip() == key:
                        value = parts[1].strip()
                        try:
                            return int(value)
                        except ValueError:
                            return default
        except (OSError, UnicodeDecodeError):
            return default
    return default


def _loc_threshold() -> int:
    """Resolved LOC threshold for region-split (default 3000).

    Values ≤ 0 from config (invalid — would disable LOC gating entirely or
    invert the comparison) fall back to the default.
    """
    value = _read_config_int(
        "review.region_split.loc_threshold", _LOC_THRESHOLD_DEFAULT
    )
    return value if value > 0 else _LOC_THRESHOLD_DEFAULT


def _file_count_threshold() -> int:
    """Resolved file-count threshold for region-split (default 40).

    Values ≤ 0 from config fall back to the default — same rationale as
    _loc_threshold.
    """
    value = _read_config_int(
        "review.region_split.file_count_threshold", _FILE_COUNT_THRESHOLD_DEFAULT
    )
    return value if value > 0 else _FILE_COUNT_THRESHOLD_DEFAULT


def _max_clusters() -> int:
    """Resolved cluster fan-out cap (default 5).

    Values < 1 from config (which would prevent any cluster being kept) fall
    back to the default.
    """
    value = _read_config_int(
        "review.region_split.max_clusters", _MAX_CLUSTERS_DEFAULT
    )
    return value if value >= 1 else _MAX_CLUSTERS_DEFAULT


def _should_region_split(diff_text: str) -> bool:
    """Return True when diff exceeds LOC or file-count thresholds.

    LOC gate: count lines starting with + or - but NOT +++ or --- (diff headers).
    File gate: count distinct filenames from diff --git headers.

    Single-file atomicity short-circuit (bug 532e-6ab7): if the diff touches
    exactly one file, return False regardless of LOC count. A single source
    file is the atomic unit of code review and MUST NEVER be region-split — the
    review of a 2000-line change in one file must always reach a single
    specialist with full context, never be partitioned by hunk.
    """
    loc_count = 0
    file_set: set[str] = set()

    for line in diff_text.splitlines():
        # Count added/removed lines (exclude +++ and --- header lines)
        if line.startswith("+") and not line.startswith("+++"):
            loc_count += 1
        elif line.startswith("-") and not line.startswith("---"):
            loc_count += 1

        # Count distinct files from diff --git headers
        m = re.match(r"^diff --git a/(\S+) b/\S+", line)
        if m:
            file_set.add(m.group(1))

        # Also detect from --- a/... headers when no diff --git line exists
        # (already handled by the +++ / --- exclusion above)

    # Also parse file names from +++ b/... lines as fallback
    for line in diff_text.splitlines():
        m = re.match(r"^\+\+\+ b/(\S+)", line)
        if m:
            file_set.add(m.group(1))

    # File-atomicity floor: never region-split a single-file diff (bug 532e-6ab7).
    # This MUST be checked before the LOC threshold so that a large change in
    # one file is reviewed atomically rather than triggering a no-op single-
    # cluster region-split.
    if len(file_set) <= 1:
        return False

    # Resolve config-driven thresholds ONCE per call (PR #169 perf: avoid
    # re-reading dso-config.conf for each comparison).
    loc_t = _loc_threshold()
    file_t = _file_count_threshold()

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
      clusters beyond the top (_max_clusters() - 1) are merged into "overflow".

    Returns a dict mapping cluster label → list of filenames. Non-overflow
    clusters store BASENAMES (per the original API contract); the "overflow"
    cluster, when present, stores FULL PATHS so the downstream extractor can
    re-locate hunks (PR #169 fix: previously overflow lost the parent
    directory, producing nonexistent ``overflow/<basename>`` lookups and a
    silent fall-through to whole-diff dispatch).

    File-atomicity invariant (bug 532e-6ab7): every input file appears in
    exactly one cluster. A single source file is the atomic unit of code
    review and must never be partitioned across reviewer specialists.
    Enforced by a post-cluster count-preservation assertion: the sum of
    files across all clusters must equal the input filename count. Any
    future refactor that drops, duplicates, or hunk-splits a file will trip
    this assertion at runtime.
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
        # Merge smallest clusters beyond top (max_c - 1) into "overflow"
        # Sort by cluster size descending, keep the largest (max_c - 1)
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
            result["overflow"] = overflow_files

    _assert_file_atomicity(filenames, result)
    return result


def _assert_file_atomicity(
    input_filenames: list[str], clusters: dict[str, list[str]]
) -> None:
    """Enforce: every input file is represented by exactly one entry across
    all clusters (bug 532e-6ab7).

    Count-preservation check: the sum of list lengths across all cluster
    values must equal the input filename count. Any future refactor that
    drops a file (silently omitted from review), duplicates a file (the
    same file reviewed twice — fine for redundancy, broken for atomicity
    semantics), or splits one file into multiple cluster entries (e.g., by
    hunk) trips this assertion immediately.

    A single source file is the atomic unit of code review and must NEVER be
    partitioned across reviewer specialists. Region-split clusters by
    directory; within one cluster, a file's hunks are forwarded together by
    ``_extract_cluster_diff``'s in_target toggling. The atomicity invariant
    documented here protects both properties.
    """
    total_in_clusters = sum(len(v) for v in clusters.values())
    if total_in_clusters != len(input_filenames):
        raise AssertionError(
            "File-atomicity invariant violated (bug 532e-6ab7): "
            f"input had {len(input_filenames)} files but clusters total "
            f"{total_in_clusters}. A single source file must land in "
            "exactly one cluster entry; this divergence indicates a file "
            "was dropped, duplicated, or hunk-split across clusters."
        )


def _extract_cluster_diff(diff_text: str, cluster_dir: str, cluster_files: list[str]) -> str:
    """Extract diff hunks relevant to the given cluster.

    Builds the set of full paths by combining cluster_dir with each basename
    for ordinary clusters. For the "." (top-level) and "overflow" pseudo-
    clusters, ``cluster_files`` is already a list of full paths and is used
    verbatim (PR #169: overflow now stores full paths so the lookup actually
    matches the diff hunks).

    Returns a substring of diff_text containing only those file sections.
    """
    if cluster_dir in {".", "overflow"}:
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
    # 1. Extract filenames from diff and cluster them
    filenames: list[str] = []
    for line in diff_text.splitlines():
        m = re.match(r"^\+\+\+ b/(\S+)", line)
        if m:
            filenames.append(m.group(1))

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
    arch_model = "claude-opus-4-5"
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
