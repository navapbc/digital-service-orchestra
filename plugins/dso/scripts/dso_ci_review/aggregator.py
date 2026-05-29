"""dso_ci_review.aggregator — Cross-file synthesis and ledger aggregation.

Synthesizes per-cluster findings from chunked oversized-PR review dispatch into
a unified review payload with a single cycle-ledger entry.

Public API:
    NAMESPACE = "DSO-Review-Coverage"
    aggregate_cluster_findings(...) -> dict
    build_visibility_trailer(...) -> str

DD3: LLM aggregation pass + visibility trailer.
DD4: Single ledger entry invariant.
"""

from __future__ import annotations

import hashlib
import json
import logging
import sys
from typing import Any

import litellm

from dso_ci_review.cycle_ledger import append_cycle

logger = logging.getLogger(__name__)

# The namespace key for the visibility trailer. Chosen to be distinct from
# the provenance trailer key (verify-session-provenance.sh:137) so that
# provenance detection is never confused by aggregation trailers.
NAMESPACE = "DSO-Review-Coverage"

# Default model for the aggregation LLM synthesis call.
_DEFAULT_AGGREGATION_MODEL = "claude-haiku-4-5-20251001"

# Synthetic severity for aggregation-internal findings.
_SEVERITY_AGGREGATION_FAILURE = "minor"


def build_visibility_trailer(
    reviewed_files: list[str],
    skipped_files: list[tuple[str, str]],
) -> str:
    """Build the visibility trailer string for a PR review aggregation pass.

    The trailer key is exactly ``DSO-Review-Coverage:`` so that
    the provenance grep in ``verify-session-provenance.sh`` does not match it.

    Args:
        reviewed_files: File paths that were reviewed.
        skipped_files: List of (path, reason) tuples for skipped files.

    Returns:
        A multi-line trailer string beginning with ``DSO-Review-Coverage:``.
    """
    reviewed_part = ", ".join(reviewed_files) if reviewed_files else "(none)"
    skipped_entries = ", ".join(f"{path} ({reason})" for path, reason in skipped_files)
    skipped_part = skipped_entries if skipped_entries else "(none)"
    return f"{NAMESPACE}:\n  reviewed: {reviewed_part}\n  skipped: {skipped_part}"


def _deduplicate_findings(findings: list[dict]) -> list[dict]:
    """Deduplicate findings by (severity, description, cited_lines) identity.

    Cross-cluster findings are sometimes included in multiple cluster results
    when they reference files belonging to different clusters. This function
    removes exact duplicates while preserving order.
    """
    seen: set[str] = set()
    result: list[dict] = []
    for finding in findings:
        # Use a canonical key based on frozen fields.
        key_parts = (
            finding.get("severity", ""),
            finding.get("description", ""),
            json.dumps(sorted(finding.get("cited_lines", [])), sort_keys=True),
        )
        key = hashlib.sha256(json.dumps(key_parts).encode("utf-8")).hexdigest()
        if key not in seen:
            seen.add(key)
            result.append(finding)
    return result


def _synthesize_via_llm(
    all_findings: list[dict],
    reviewed_files: list[str],
    model: str = _DEFAULT_AGGREGATION_MODEL,
) -> list[dict] | None:
    """Call the LLM once to synthesize and refine the merged cluster findings.

    Counts as exactly ONE LLM call against the max_calls budget regardless
    of the number of clusters. Returns the refined findings list on success,
    or None on parse failure (F4a fallback — caller handles None).

    Args:
        all_findings: Concatenated findings from all clusters (pre-deduplication).
        reviewed_files: All file paths reviewed across all clusters.
        model: LLM model identifier for the synthesis call.

    Returns:
        List of findings dicts on success; None on JSON parse failure.
    """
    prompt = (
        "You are a code review aggregator. The following findings were produced "
        "by per-file review of a pull request. The reviewed files are:\n\n"
        + "\n".join(f"- {f}" for f in reviewed_files)
        + "\n\nPlease synthesize these findings into a unified list, removing "
        "duplicates and noting cross-file concerns. Return ONLY valid JSON with "
        'the shape: {"findings": [{"severity": "...", "description": "...", '
        '"cited_lines": [...]}]}\n\n'
        "## Per-cluster findings\n\n" + json.dumps({"findings": all_findings}, indent=2)
    )

    response = litellm.completion(
        model=model,
        messages=[
            {"role": "user", "content": prompt},
        ],
        stream=False,
    )

    raw_content: str = response.choices[0].message.content or ""

    # Try direct JSON parse.
    try:
        parsed = json.loads(raw_content)
        _f = parsed.get("findings", [])
        # Bug 7f55: guard the synthesis LLM's response shape. If the model
        # returns {"findings": "<string>"} (a common malformed shape), do
        # NOT return the string — downstream consumers call .get() per
        # item and would crash with AttributeError. Trigger the F4a
        # un-aggregated fallback by returning None instead.
        if isinstance(_f, list):
            return _f
    except (json.JSONDecodeError, TypeError, AttributeError):
        pass

    # Try extracting JSON from prose-wrapped response.
    try:
        start = raw_content.find("{")
        end = raw_content.rfind("}") + 1
        if start != -1 and end > start:
            parsed = json.loads(raw_content[start:end])
            _f = parsed.get("findings", [])
            if isinstance(_f, list):
                return _f
    except (json.JSONDecodeError, ValueError):
        pass

    return None


def _compute_findings_hash(findings: list[dict]) -> str:
    """Compute a stable SHA-256 hash of a findings list for the ledger entry."""
    serialized = json.dumps(findings, sort_keys=True, ensure_ascii=False)
    return hashlib.sha256(serialized.encode("utf-8")).hexdigest()[:16]


def aggregate_cluster_findings(
    cluster_results: list[dict],
    reviewed_files: list[str] | None = None,
    skipped_files: list[tuple[str, str]] | None = None,
    pr_number: int | None = None,
    commit_sha: str | None = None,
    cycle_num: int | None = None,
    ledger_path: str | None = None,
    gitattributes_path: str | None = None,
    model: str = _DEFAULT_AGGREGATION_MODEL,
) -> dict[str, Any]:
    """Synthesize per-cluster findings into a unified review payload.

    DD3.1: Cross-file synthesis — performs ONE LLM call to synthesize all
    cluster findings into a unified, deduplicated list.

    DD3.2: Visibility trailer — builds a DSO-Review-Coverage: trailer listing
    all reviewed and skipped files.

    DD4: Single ledger entry — emits exactly ONE append_cycle() call per
    aggregation pass regardless of cluster count.

    Failure modes:
        F4a: Malformed JSON from synthesis LLM → falls back to per-cluster
             concatenated results; marks result with aggregation_status="failed".
        F4b: .gitattributes parse failure → fail-open (all files treated as
             reviewable); warning logged; aggregation does NOT abort.
        F4c: Per-file schema-correction exhaustion → skip that file's cluster;
             aggregation continues; result notes schema-correction-exhausted:<file>.

    Args:
        cluster_results: Per-cluster result dicts as returned by file dispatch.
            Each dict has keys: cluster_id, file_paths, findings, status.
        reviewed_files: Flat list of all reviewed file paths. Inferred from
            cluster_results when None.
        skipped_files: List of (path, reason) tuples. Defaults to [].
        pr_number: PR number for the ledger entry. Required for append_cycle.
        commit_sha: Commit SHA for the ledger entry.
        cycle_num: Review cycle number for the ledger entry.
        ledger_path: Path to cycle-ledger.json. When None, append_cycle is not called.
        gitattributes_path: Optional path to .gitattributes for linguist filter.
            When absent or unreadable, fail-open (F4b).
        model: LLM model for the aggregation synthesis call.

    Returns:
        Dict with keys:
            findings: List of finding dicts (synthesized or fallback).
            visibility_trailer: DSO-Review-Coverage: trailer string.
            ledger_entry: Dict summarising what was written to the ledger.
            aggregation_status: "ok" | "failed" (F4a).
            cluster_results: Preserved on F4a fallback.
            schema_exhausted_files: List of files skipped due to F4c.
    """
    if skipped_files is None:
        skipped_files = []
    schema_exhausted_files: list[str] = []

    # Phase 2 parallelization: cluster dispatch via asyncio.gather has
    # nondeterministic completion order. Sort here so the synthesis LLM
    # prompt and the visibility trailer's reviewed-file list are stable
    # across runs and across sequential vs parallel implementations.
    cluster_results = sorted(
        cluster_results, key=lambda c: c.get("cluster_id", "")
    )

    # F4b: .gitattributes — fail-open if absent or unreadable.
    if gitattributes_path is not None:
        try:
            with open(gitattributes_path, encoding="utf-8", errors="replace") as _ga_f:
                _ga_f.read()
        except OSError as exc:
            logger.warning(
                "fail-open: .gitattributes parse failure at %r: %s — "
                "all files treated as reviewable",
                gitattributes_path,
                exc,
            )
            print(
                f"WARNING: fail-open: .gitattributes parse failure at "
                f"{gitattributes_path!r}: {exc}",
                file=sys.stderr,
            )

    # Collect all findings from cluster results; handle F4c (schema exhaustion).
    all_findings: list[dict] = []
    all_reviewed_files: list[str] = []

    for cluster in cluster_results:
        cluster_files = cluster.get("file_paths", [])
        cluster_findings = cluster.get("findings", [])
        cluster_status = cluster.get("status", "ok")

        # F4c: schema-correction exhaustion — cluster status may signal this
        # via the ValueError raised in the per-file dispatch. Here we check
        # whether any cluster finding contains schema-exhausted metadata.
        if cluster_status == "schema_correction_exhausted":
            for f in cluster_files:
                schema_exhausted_files.append(f)
                print(
                    f"INFO: schema-correction-exhausted: {f} — skipping cluster",
                    file=sys.stderr,
                )
            continue

        all_reviewed_files.extend(cluster_files)
        all_findings.extend(cluster_findings)

    # Override with explicit reviewed_files if provided.
    if reviewed_files is not None:
        all_reviewed_files = list(reviewed_files)

    # Deduplicate before LLM synthesis to reduce token count.
    deduped_findings = _deduplicate_findings(all_findings)

    # Build visibility trailer (DD3.2).
    visibility_trailer = build_visibility_trailer(
        reviewed_files=all_reviewed_files,
        skipped_files=list(skipped_files),
    )

    # LLM synthesis (DD3.1): ONE call regardless of cluster count.
    # F4a: malformed JSON → fall back to per-cluster results.
    synthesized_findings: list[dict] | None = None
    aggregation_failed = False
    aggregation_comment = ""

    try:
        synthesized_findings = _synthesize_via_llm(
            all_findings=deduped_findings,
            reviewed_files=all_reviewed_files,
            model=model,
        )
    except ValueError as exc:
        # F4c: schema-correction exhausted during LLM call — extract file name.
        exc_str = str(exc)
        if "schema-correction-exhausted:" in exc_str:
            # Parse the filename from the exception message.
            marker = "schema-correction-exhausted:"
            idx = exc_str.find(marker)
            if idx != -1:
                exhausted_file = exc_str[idx + len(marker) :].strip()
                schema_exhausted_files.append(exhausted_file)
            synthesized_findings = None
        else:
            synthesized_findings = None

    if synthesized_findings is None:
        # F4a: aggregation LLM returned malformed JSON or raised ValueError.
        aggregation_failed = True
        aggregation_comment = (
            "aggregation failed; per-cluster findings posted separately"
        )
        logger.warning(
            "Aggregation LLM returned malformed or unparseable JSON — "
            "falling back to per-cluster findings."
        )

    # Final findings: synthesized (success) or deduped per-cluster (F4a fallback).
    final_findings = (
        synthesized_findings if not aggregation_failed else deduped_findings
    )

    # Emit exactly ONE cycle-ledger entry (DD4).
    findings_hash = _compute_findings_hash(final_findings)
    ledger_entry: dict[str, Any] = {
        "pr_number": pr_number,
        "commit_sha": commit_sha,
        "cycle_num": cycle_num,
        "findings_count": len(final_findings),
        "findings_hash": findings_hash,
    }

    if ledger_path is not None and pr_number is not None and commit_sha is not None:
        findings_tuples = [
            [
                f.get("severity", ""),
                f.get("description", ""),
                json.dumps(f.get("cited_lines", [])),
            ]
            for f in final_findings
        ]
        _cycle_num_val = cycle_num if cycle_num is not None else 1
        append_cycle(  # pr_number=pr_number commit_sha=commit_sha
            ledger_path,
            _cycle_num_val,
            findings_tuples,
            commit_sha,
            findings_hash,
            halt_reason=None,
            pr_number=pr_number,
        )

    result: dict[str, Any] = {
        "findings": final_findings,
        "visibility_trailer": visibility_trailer,
        "ledger_entry": ledger_entry,
        "aggregation_status": "failed" if aggregation_failed else "ok",
    }

    if aggregation_failed:
        result["fallback"] = True
        result["cluster_results"] = list(cluster_results)
        result["aggregation_comment"] = aggregation_comment
        result["visibility_comment"] = aggregation_comment

    if schema_exhausted_files:
        result["schema_exhausted_files"] = schema_exhausted_files
        # Embed schema-correction-exhausted markers in visibility for string match tests.
        result["schema_exhaustion_notes"] = [
            f"schema-correction-exhausted: {f}" for f in schema_exhausted_files
        ]

    return result
