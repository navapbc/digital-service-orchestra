#!/usr/bin/env python3
"""ref-query.py — BM25 search across the UI reference corpus.

CLI usage:
    python3 ref-query.py <query> \\
        [--corpus PATH] [--top-n N] [--tier TIER] [--session-hash HASH]
        [--namespace DOMAIN] [--format {text,json}]

Importable API:
    from ref_query import query

    results = query(corpus_dir, query_str, top_n=5, tier="summary", session_hash="",
                    namespace="")

Output format (default, --format=text): newline-separated YAML documents (separated by '---').
Output format (--format=json): JSON array of result objects per the ref-query-json-output
contract (${CLAUDE_PLUGIN_ROOT}/docs/contracts/ref-query-json-output.md).
Each document contains the corpus entry fields plus a 'score' field.

Exit codes:
    0 — query completed (zero results also exits 0; check stderr for sentinel)
    1 — usage error or fatal failure

Zero-result sentinel (emitted to stderr):
    [ref-query: no results for query: "<query>"]
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path
from typing import Any

import yaml

# ---------------------------------------------------------------------------
# Optional bm25s accelerator
# ---------------------------------------------------------------------------

try:
    import bm25s

    _BM25S_AVAILABLE = True
except ImportError:
    _BM25S_AVAILABLE = False

# One-shot latch: emit the fallback notice at most once per process.
_NOTICE_EMITTED = False

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

SKIP_NAMES = frozenset(
    {"_index.yaml", "_schema.yaml", "_schema-anti-patterns.yaml", "_overview.yaml"}
)
MAX_OUTPUT_LINES = 500
_DEFAULT_CORPUS = Path(__file__).parent.parent / "data" / "ui-reference"


# ---------------------------------------------------------------------------
# Corpus loading
# ---------------------------------------------------------------------------


def load_entries_from_dir(directory: Path) -> list[dict[str, Any]]:
    """Recursively load all YAML corpus entries from a directory."""
    entries: list[dict[str, Any]] = []
    for yaml_path in sorted(directory.rglob("*.yaml")):
        if yaml_path.name in SKIP_NAMES:
            continue
        try:
            content = yaml_path.read_text(encoding="utf-8")
            for doc in yaml.safe_load_all(content):
                if doc is None:
                    continue
                if isinstance(doc, list):
                    for item in doc:
                        if isinstance(item, dict):
                            item.setdefault("_source_path", str(yaml_path))
                            entries.append(item)
                elif isinstance(doc, dict):
                    doc.setdefault("_source_path", str(yaml_path))
                    entries.append(doc)
        except Exception:  # noqa: BLE001
            pass
    return entries


# ---------------------------------------------------------------------------
# BM25 scoring
# ---------------------------------------------------------------------------


def tokenize(text: str) -> list[str]:
    """Lowercase and split text into word tokens.

    Splits on whitespace, punctuation, and hyphens.  Underscores are treated
    as word-constituent characters so that compound identifiers such as
    'xyzzy_no_match' are kept as single opaque tokens.  This prevents a query
    like 'xyzzy_no_such_component_ever' from accidentally matching on the
    sub-word 'component'.
    """
    return re.findall(r"[a-z0-9_]+", text.lower())


def entry_to_text(entry: dict[str, Any]) -> str:
    """Combine all searchable text fields from a corpus entry."""
    parts: list[str] = []

    # High-signal metadata fields
    for field in ("id", "title", "source"):
        val = entry.get(field)
        if val:
            parts.append(str(val))

    # Keyword/tag fields — boost by repeating
    keywords = entry.get("keywords") or entry.get("tags") or []
    if isinstance(keywords, list):
        # Repeat keyword tokens to increase their weight
        for kw in keywords:
            parts.append(str(kw))
            parts.append(str(kw))
    elif keywords:
        parts.append(str(keywords))

    # Categorical metadata (tier excluded — filtered via --tier flag, not text search)
    for field in ("domain", "component", "action", "compliance", "story_type"):
        val = entry.get(field)
        if isinstance(val, list):
            parts.extend(str(v) for v in val)
        elif val:
            parts.append(str(val))

    # Free-text content fields
    _non_text = frozenset(
        {
            "id",
            "title",
            "source",
            "domain",
            "component",
            "action",
            "compliance",
            "story_type",
            "coverage",
            "license",
            "severity",
            "tier",
            "tags",
            "keywords",
            "_source_path",
        }
    )
    for key, val in entry.items():
        if key.startswith("_") or key in _non_text:
            continue
        if isinstance(val, str):
            parts.append(val)
        elif isinstance(val, list):
            parts.extend(str(v) for v in val if isinstance(v, (str, int, float)))

    return " ".join(parts)


def compute_idf(term: str, doc_token_lists: list[list[str]], n_docs: int) -> float:
    """Compute IDF (Okapi BM25 variant) for a term across all documents.

    IDF = log((N - df + 0.5) / (df + 0.5) + 1)
    where df is the number of documents containing the term.
    Returns 0.0 for terms not in any document.
    """
    import math

    df = sum(1 for tokens in doc_token_lists if term in tokens)
    if df == 0:
        return 0.0
    return math.log((n_docs - df + 0.5) / (df + 0.5) + 1.0)


def bm25_score(
    query_tokens: list[str],
    doc_tokens: list[str],
    avg_doc_len: float,
    idf_map: dict[str, float],
    k1: float = 1.5,
    b: float = 0.75,
) -> float:
    """Compute BM25 score for a single document.

    Args:
        query_tokens: Tokenized query terms.
        doc_tokens: Tokenized document text.
        avg_doc_len: Average document length across the corpus.
        idf_map: Pre-computed IDF values keyed by term.
        k1: BM25 saturation parameter.
        b: BM25 length normalization parameter.
    """
    doc_len = len(doc_tokens)
    if doc_len == 0:
        return 0.0

    freq: dict[str, int] = {}
    for t in doc_tokens:
        freq[t] = freq.get(t, 0) + 1

    score = 0.0
    for qt in query_tokens:
        idf = idf_map.get(qt, 0.0)
        if idf <= 0.0:
            continue
        f = freq.get(qt, 0)
        if f == 0:
            continue
        numerator = f * (k1 + 1)
        denominator = f + k1 * (1.0 - b + b * doc_len / avg_doc_len)
        score += idf * numerator / denominator
    return score


# ---------------------------------------------------------------------------
# Ranking helpers (stdlib path and optional bm25s path)
# ---------------------------------------------------------------------------


def _rank_with_stdlib(
    entries: list[dict[str, Any]],
    query_tokens: list[str],
    doc_token_lists: list[list[str]],
) -> list[tuple[float, dict[str, Any]]]:
    """Rank entries using the pure-stdlib BM25 implementation.

    Emits a one-shot stderr notice the first time it is called in this process
    to inform callers that the optional bm25s accelerator is absent.
    """
    global _NOTICE_EMITTED  # noqa: PLW0603
    if not _NOTICE_EMITTED:
        print(
            "[ref-query] bm25s not available; using stdlib BM25 fallback",
            file=sys.stderr,
        )
        _NOTICE_EMITTED = True

    avg_doc_len = sum(len(t) for t in doc_token_lists) / max(len(doc_token_lists), 1)
    n_docs = len(entries)
    idf_map = {qt: compute_idf(qt, doc_token_lists, n_docs) for qt in set(query_tokens)}
    scored: list[tuple[float, dict[str, Any]]] = []
    for entry, doc_toks in zip(entries, doc_token_lists):
        score = bm25_score(query_tokens, doc_toks, avg_doc_len, idf_map)
        scored.append((score, entry))
    return scored


def _rank_with_bm25s(
    entries: list[dict[str, Any]],
    query_tokens: list[str],
    doc_token_lists: list[list[str]],
) -> list[tuple[float, dict[str, Any]]]:
    """Rank entries using the bm25s library accelerator.

    Falls back gracefully to _rank_with_stdlib if the bm25s API is
    unavailable at runtime (e.g., version mismatch or partial install).
    """
    try:
        retriever = bm25s.BM25()  # type: ignore[attr-defined]
        retriever.index(bm25s.tokenize([" ".join(toks) for toks in doc_token_lists]))  # type: ignore[attr-defined]
        query_str = " ".join(query_tokens)
        _results, scores = retriever.retrieve(
            bm25s.tokenize([query_str]),  # type: ignore[attr-defined]
            corpus=list(range(len(entries))),
            k=len(entries),
        )
        # scores shape: (1, k); results shape: (1, k) — corpus indices
        scored: list[tuple[float, dict[str, Any]]] = []
        for idx, score in zip(_results[0], scores[0]):
            scored.append((float(score), entries[idx]))
        return scored
    except Exception:  # noqa: BLE001
        # bm25s present but unusable — degrade to stdlib path transparently.
        return _rank_with_stdlib(entries, query_tokens, doc_token_lists)


# ---------------------------------------------------------------------------
# Session cache (deduplication)
# ---------------------------------------------------------------------------


def _cache_path(corpus_dir: Path) -> Path:
    """Return the session-cache file path for a given corpus directory."""
    return corpus_dir / ".ref-query-seen.json"


def _load_seen_ids(corpus_dir: Path) -> set[str]:
    """Load previously-seen entry IDs from the session cache."""
    path = _cache_path(corpus_dir)
    if not path.exists():
        return set()
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
        if isinstance(data, list):
            return set(str(x) for x in data)
    except Exception:  # noqa: BLE001
        pass
    return set()


def _write_seen_ids(corpus_dir: Path, seen_ids: set[str]) -> None:
    """Persist seen entry IDs to the session cache."""
    try:
        _cache_path(corpus_dir).write_text(
            json.dumps(sorted(seen_ids)), encoding="utf-8"
        )
    except Exception:  # noqa: BLE001
        pass


# ---------------------------------------------------------------------------
# Result rendering
# ---------------------------------------------------------------------------


def render_entry_yaml(entry: dict[str, Any]) -> str:
    """Render a corpus entry as a YAML document string."""
    out: dict[str, Any] = {}

    # Always include these fields if present
    for field in ("id", "title", "tier", "source", "license"):
        val = entry.get(field)
        if val is not None:
            out[field] = val

    # List fields
    for field in ("domain", "component", "compliance", "tags", "keywords"):
        val = entry.get(field)
        if val is not None:
            out[field] = val

    # Content fields
    for field in ("description", "summary", "detail", "example"):
        val = entry.get(field)
        if val is not None:
            out[field] = val

    # Score (for debugging / callers)
    if "_score" in entry:
        out["score"] = round(entry["_score"], 4)

    # Fallback: include any remaining non-private fields
    _shown = frozenset(out.keys())
    for key, val in entry.items():
        if key.startswith("_") or key in _shown:
            continue
        out[key] = val

    return yaml.dump(out, default_flow_style=False, allow_unicode=True).rstrip()


# ---------------------------------------------------------------------------
# Core query function (importable API)
# ---------------------------------------------------------------------------


def _entry_domains(entry: dict[str, Any]) -> list[str]:
    """Return the list of domain values for a corpus entry (normalised to list[str])."""
    domain = entry.get("domain", [])
    if isinstance(domain, list):
        return [str(d) for d in domain]
    if domain:
        return [str(domain)]
    return []


def render_entry_json(entry: dict[str, Any]) -> dict[str, Any]:
    """Render a corpus entry as a JSON-serialisable dict per the ref-query-json-output schema.

    Schema fields (ref: ${CLAUDE_PLUGIN_ROOT}/docs/contracts/ref-query-json-output.md):
      rule_id     — entry 'id' field (string)
      tags        — dict carrying at minimum 'domain' key
      score       — BM25 score (float, rounded to 4 decimal places)
      body        — primary human-readable text (summary > description > title)
      source_file — '_source_path' internal field (relative path when possible)
    """
    rule_id = entry.get("id", "")
    score = round(entry.get("_score", 0.0), 4)

    # Build tags dict from tag-like fields
    tags: dict[str, Any] = {}
    domain = entry.get("domain", [])
    if domain:
        tags["domain"] = domain
    for field in ("component", "compliance", "action", "keywords", "tags"):
        val = entry.get(field)
        if val is not None:
            tags[field] = val

    # Primary body text: prefer summary/description, fall back to title
    body = (
        entry.get("summary")
        or entry.get("description")
        or entry.get("detail")
        or entry.get("title")
        or ""
    )

    # source_file: use relative path when possible
    source_file = entry.get("_source_path", "")

    return {
        "rule_id": rule_id,
        "tags": tags,
        "score": score,
        "body": str(body),
        "source_file": source_file,
    }


def query(
    corpus_dir: str | Path,
    query_str: str,
    top_n: int = 5,
    tier: str = "",
    session_hash: str = "",
    namespace: str = "",
) -> list[dict[str, Any]]:
    """Run a BM25 search over the corpus and return a list of result dicts.

    Args:
        corpus_dir: Path to the corpus directory containing YAML files.
        query_str: The search query string.
        top_n: Maximum number of results to return.
        tier: If non-empty, filter results to entries matching this tier value.
        session_hash: If non-empty, deduplicate results against the session cache.
        namespace: If non-empty, filter results to entries whose domain matches
            this value (exact match; case-sensitive).

    Returns:
        List of result dicts (with BM25 score in '_score' key).
    """
    corpus_dir = Path(corpus_dir)
    entries = load_entries_from_dir(corpus_dir)
    if not entries:
        return []

    # Tier filtering
    if tier:
        entries = [e for e in entries if e.get("tier") == tier]
        if not entries:
            return []

    # Namespace (domain) filtering
    if namespace:
        entries = [e for e in entries if namespace in _entry_domains(e)]
        if not entries:
            return []

    # BM25 scoring
    query_tokens = tokenize(query_str)
    if not query_tokens:
        return []

    doc_texts = [entry_to_text(e) for e in entries]
    doc_token_lists = [tokenize(t) for t in doc_texts]

    if _BM25S_AVAILABLE:
        scored = _rank_with_bm25s(entries, query_tokens, doc_token_lists)
    else:
        scored = _rank_with_stdlib(entries, query_tokens, doc_token_lists)

    scored.sort(key=lambda x: x[0], reverse=True)

    # Only return results when at least one entry has a positive BM25 score.
    # If the best score is zero, the query matched nothing — return empty.
    if not scored or scored[0][0] <= 0:
        return []

    top_results = [{**entry, "_score": score} for score, entry in scored[:top_n]]

    # Session deduplication: always write seen IDs; filter when session_hash provided
    seen_ids = set()
    if session_hash:
        seen_ids = _load_seen_ids(corpus_dir)
        top_results = [r for r in top_results if r.get("id", "") not in seen_ids]

    returned_ids = {r.get("id", "") for r in top_results if r.get("id")}
    _write_seen_ids(corpus_dir, seen_ids | returned_ids)

    return top_results


# ---------------------------------------------------------------------------
# CLI entry point
# ---------------------------------------------------------------------------


def main() -> None:
    """CLI entry point for ref-query.py."""
    parser = argparse.ArgumentParser(
        description="BM25 search across the UI reference corpus.",
        prog="ref-query.py",
    )
    parser.add_argument("query_str", metavar="query", help="Search query string")
    parser.add_argument(
        "--corpus",
        default=str(_DEFAULT_CORPUS),
        help="Path to corpus directory (default: plugin data/ui-reference)",
    )
    parser.add_argument(
        "--top-n",
        type=int,
        default=5,
        dest="top_n",
        help="Maximum number of results to return (default: 5)",
    )
    parser.add_argument(
        "--tier",
        default="",
        help="Filter results to entries matching this tier value",
    )
    parser.add_argument(
        "--session-hash",
        default="",
        dest="session_hash",
        help="Session hash for deduplication across calls",
    )
    parser.add_argument(
        "--namespace",
        default="",
        help=(
            "Filter results to entries whose domain matches this value "
            "(e.g. canon, components, gov-copy). "
            "Without --namespace, results span all domains."
        ),
    )
    parser.add_argument(
        "--format",
        default="text",
        choices=["text", "json"],
        dest="output_format",
        help=(
            "Output format: 'text' (default, YAML-like documents) or "
            "'json' (JSON array per ref-query-json-output schema)."
        ),
    )

    args = parser.parse_args()

    corpus_dir = Path(args.corpus)
    if not corpus_dir.is_dir():
        print(
            f'[ref-query: no results for query: "{args.query_str}"]',
            file=sys.stderr,
        )
        sys.exit(0)

    results = query(
        corpus_dir=corpus_dir,
        query_str=args.query_str,
        top_n=args.top_n,
        tier=args.tier,
        session_hash=args.session_hash,
        namespace=args.namespace,
    )

    if not results:
        print(
            f'[ref-query: no results for query: "{args.query_str}"]',
            file=sys.stderr,
        )
        sys.exit(0)

    if args.output_format == "json":
        json_rows = [render_entry_json(entry) for entry in results]
        print(json.dumps(json_rows, ensure_ascii=False, indent=2))
        sys.exit(0)

    # Render output as YAML documents separated by '---'
    output_lines: list[str] = []
    for i, entry in enumerate(results):
        if i > 0:
            output_lines.append("---")
        output_lines.append(render_entry_yaml(entry))

    # Truncate at MAX_OUTPUT_LINES
    if len(output_lines) > MAX_OUTPUT_LINES:
        output_lines = output_lines[:MAX_OUTPUT_LINES]

    print("\n".join(output_lines))
    sys.exit(0)


if __name__ == "__main__":
    main()
