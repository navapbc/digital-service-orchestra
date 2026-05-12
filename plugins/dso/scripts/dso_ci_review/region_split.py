"""dso_ci_review.region_split — Region-split FALLBACK for large diffs.

Strategy E: when a diff exceeds the LOC or file-count threshold, split it into
per-directory clusters, dispatch specialists per cluster in parallel, then run
arch synthesis over the merged findings.

Story f5f9-9a3c-c7be-4d11: Strategy E region-split FALLBACK in CI llm-review pipeline.
"""

from __future__ import annotations

import asyncio
import json
import re
from typing import Any

from dso_ci_review.dispatch import async_dispatch_specialists, dispatch_arch_synthesis

# Thresholds for triggering region split
_LOC_THRESHOLD = 400
_FILE_COUNT_THRESHOLD = 15
_MAX_CLUSTERS = 5


def _should_region_split(diff_text: str) -> bool:
    """Return True when diff exceeds LOC or file-count thresholds.

    LOC gate: count lines starting with + or - but NOT +++ or --- (diff headers).
    File gate: count distinct filenames from diff --git headers.
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

    if loc_count > _LOC_THRESHOLD:
        return True
    if len(file_set) > _FILE_COUNT_THRESHOLD:
        return True
    return False


def _cluster_files(filenames: list[str]) -> dict[str, list[str]]:
    """Group filenames by their immediate parent directory.

    - Files with a directory component land in ``"<dir>"`` cluster.
    - Top-level files (no directory) land in ``"."`` cluster.
    - If more than ``_MAX_CLUSTERS`` distinct directories exist, the smallest
      clusters beyond the top (_MAX_CLUSTERS - 1) are merged into "overflow".

    Returns a dict mapping cluster label → list of bare filenames (basename only).
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

    if len(dir_map) <= _MAX_CLUSTERS:
        return dir_map

    # Merge smallest clusters beyond top (_MAX_CLUSTERS - 1) into "overflow"
    # Sort by cluster size descending, keep the largest (_MAX_CLUSTERS - 1)
    sorted_dirs = sorted(dir_map.items(), key=lambda kv: len(kv[1]), reverse=True)
    kept = sorted_dirs[: _MAX_CLUSTERS - 1]
    overflow_dirs = sorted_dirs[_MAX_CLUSTERS - 1 :]

    result: dict[str, list[str]] = {d: files for d, files in kept}
    overflow_files: list[str] = []
    for _, files in overflow_dirs:
        overflow_files.extend(files)
    if overflow_files:
        result["overflow"] = overflow_files
    return result


def _extract_cluster_diff(diff_text: str, cluster_dir: str, cluster_files: list[str]) -> str:
    """Extract diff hunks relevant to the given cluster.

    Builds the set of full paths by combining cluster_dir with each basename.
    Returns a substring of diff_text containing only those file sections.
    """
    if cluster_dir == ".":
        full_paths = set(cluster_files)
    else:
        full_paths = {f"{cluster_dir}/{f}" for f in cluster_files}

    lines = diff_text.splitlines()
    result_lines: list[str] = []
    in_target = False

    for line in lines:
        # Check for a new file section
        m = re.match(r"^\+\+\+ b/(\S+)", line)
        if m:
            path = m.group(1)
            in_target = path in full_paths

        # Also handle --- a/... as start of file section
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
) -> dict[str, Any]:
    """Async implementation of region-split dispatch."""
    # 1. Extract filenames from diff and cluster them
    filenames: list[str] = []
    for line in diff_text.splitlines():
        m = re.match(r"^\+\+\+ b/(\S+)", line)
        if m:
            filenames.append(m.group(1))

    clusters = _cluster_files(filenames)

    # 2 & 3. For each cluster, extract its diff hunk and dispatch specialists in parallel
    async def _dispatch_cluster(cluster_dir: str, cluster_file_list: list[str]) -> list[dict]:
        cluster_diff = _extract_cluster_diff(diff_text, cluster_dir, cluster_file_list)
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
) -> dict[str, Any]:
    """Synchronous entry point for region-split dispatch.

    Clusters the diff by directory, dispatches specialists per cluster in parallel,
    then runs arch synthesis over merged findings.

    Returns a dict with a "findings" key containing all findings from all clusters
    plus the arch synthesis result.
    """
    return asyncio.run(
        _async_run_region_split(diff_text, tier_agents, provider_chain, config_path)
    )
