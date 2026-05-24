#!/usr/bin/env bash
# ref-query.sh — BM25-style search across the UI reference corpus.
#
# Usage:
#   ref-query.sh <query> [--top-n <N>] [--tier=<summary|detail|implementation>] [--session-hash <H>]
#
# Outputs the top-N matching corpus entries to stdout, including frontmatter fields
# and the requested content tier (summary by default).
#
# Exit codes:
#   0 — query completed (zero results also exits 0; check stderr for [ref-query: no results] sentinel)
#   1 — usage error or fatal failure
#
# Zero-result sentinel (emitted to stderr):
#   [ref-query: no results for query: "<query>"]
#
# Example:
#   ref-query.sh "USWDS form validation" --top-n 3
#   ref-query.sh "keyboard navigation" --tier=detail --top-n 5

set -euo pipefail

# ── Argument parsing ──────────────────────────────────────────────────────────

QUERY=""
TOP_N=8
TIER="summary"
SESSION_HASH=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --top-n)
            TOP_N="${2:-5}"
            shift 2
            ;;
        --top-n=*)
            TOP_N="${1#--top-n=}"
            shift
            ;;
        --tier=*)
            TIER="${1#--tier=}"
            shift
            ;;
        --tier)
            TIER="${2:-summary}"
            shift 2
            ;;
        --session-hash)
            SESSION_HASH="${2:-}"
            shift 2
            ;;
        --session-hash=*)
            SESSION_HASH="${1#--session-hash=}"
            shift
            ;;
        -*)
            printf 'ref-query.sh: unknown option: %s\n' "$1" >&2
            exit 1
            ;;
        *)
            if [[ -z "$QUERY" ]]; then
                QUERY="$1"
            fi
            shift
            ;;
    esac
done

if [[ -z "$QUERY" ]]; then
    printf 'ref-query.sh: usage: ref-query.sh <query> [--top-n N] [--tier=summary|detail|implementation]\n' >&2
    exit 1
fi

# ── Corpus discovery ──────────────────────────────────────────────────────────

# Resolve corpus root from script location
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CORPUS_ROOT="$PLUGIN_ROOT/data/ui-reference"

if [[ ! -d "$CORPUS_ROOT" ]]; then
    printf '[ref-query: no results for query: "%s"]\n' "$QUERY" >&2
    exit 0
fi

# ── BM25-inspired search via Python ──────────────────────────────────────────

python3 - "$CORPUS_ROOT" "$QUERY" "$TOP_N" "$TIER" <<'PYTHON_EOF'
"""BM25-style corpus search for ref-query.sh."""
from __future__ import annotations

import re
import sys
from pathlib import Path
from typing import Any

import yaml

corpus_root = Path(sys.argv[1])
raw_query = sys.argv[2]
top_n = int(sys.argv[3])
tier = sys.argv[4]

SKIP_NAMES = {"_index.yaml", "_schema.yaml"}


# ---------------------------------------------------------------------------
# Load all corpus entries
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
                            item["_source_path"] = str(yaml_path)
                            entries.append(item)
                elif isinstance(doc, dict):
                    doc["_source_path"] = str(yaml_path)
                    entries.append(doc)
        except Exception:  # noqa: BLE001
            pass
    return entries


# ---------------------------------------------------------------------------
# BM25 scoring
# ---------------------------------------------------------------------------

def tokenize(text: str) -> list[str]:
    """Lowercase and split text into word tokens."""
    return re.findall(r"[a-z0-9]+", text.lower())


def entry_to_text(entry: dict[str, Any]) -> str:
    """Combine all searchable text fields from a corpus entry."""
    parts: list[str] = []
    for field in ("id", "title", "source"):
        val = entry.get(field)
        if val:
            parts.append(str(val))
    for field in ("domain", "component", "action", "compliance", "story_type"):
        val = entry.get(field)
        if isinstance(val, list):
            parts.extend(str(v) for v in val)
        elif val:
            parts.append(str(val))
    # Include all string content fields (summary, detail, description, etc.)
    NON_TEXT_FIELDS = frozenset({
        "id", "title", "source", "domain", "component", "action", "compliance",
        "story_type", "coverage", "license", "severity", "tier", "tags",
        "_source_path",
    })
    for key, val in entry.items():
        if key.startswith("_") or key in NON_TEXT_FIELDS:
            continue
        if isinstance(val, str):
            parts.append(val)
        elif isinstance(val, list):
            parts.extend(str(v) for v in val if isinstance(v, str))
    return " ".join(parts)


def bm25_score(
    query_tokens: list[str],
    doc_tokens: list[str],
    avg_doc_len: float,
    k1: float = 1.5,
    b: float = 0.75,
) -> float:
    """Compute BM25 score for a single document."""
    doc_len = len(doc_tokens)
    freq: dict[str, int] = {}
    for t in doc_tokens:
        freq[t] = freq.get(t, 0) + 1

    score = 0.0
    for qt in query_tokens:
        f = freq.get(qt, 0)
        if f == 0:
            continue
        numerator = f * (k1 + 1)
        denominator = f + k1 * (1 - b + b * doc_len / avg_doc_len)
        score += numerator / denominator
    return score


# ---------------------------------------------------------------------------
# Render a corpus entry
# ---------------------------------------------------------------------------

def render_entry(entry: dict[str, Any], tier: str) -> str:
    """Render a corpus entry for display."""
    lines: list[str] = []
    lines.append(f"id: {entry.get('id', '<no-id>')}")
    lines.append(f"title: {entry.get('title', '<no-title>')}")

    domain = entry.get("domain", [])
    if isinstance(domain, list):
        lines.append(f"domain: {domain}")
    elif domain:
        lines.append(f"domain: [{domain}]")

    component = entry.get("component", [])
    if isinstance(component, list) and component:
        lines.append(f"component: {component}")
    elif component:
        lines.append(f"component: [{component}]")

    compliance = entry.get("compliance", [])
    if isinstance(compliance, list) and compliance:
        lines.append(f"compliance: {compliance}")

    lines.append(f"license: {entry.get('license', '')}")
    lines.append(f"source: {entry.get('source', '')}")
    lines.append("")

    # Render summary and detail fields (YAML block scalar fields)
    summary_text = entry.get("summary") or entry.get("description") or ""
    detail_text = entry.get("detail") or ""

    if tier in ("summary", "detail", "implementation") and summary_text:
        lines.append("### Summary")
        lines.append(str(summary_text).strip())
        lines.append("")

    if tier in ("detail", "implementation") and detail_text:
        lines.append("### Detail")
        lines.append(str(detail_text).strip())
        lines.append("")

    return "\n".join(lines)


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

entries = load_entries_from_dir(corpus_root)

if not entries:
    print(f'[ref-query: no results for query: "{raw_query}"]', file=sys.stderr)
    sys.exit(0)

query_tokens = tokenize(raw_query)
doc_texts = [entry_to_text(e) for e in entries]
doc_token_lists = [tokenize(t) for t in doc_texts]
avg_doc_len = sum(len(t) for t in doc_token_lists) / max(len(doc_token_lists), 1)

scored: list[tuple[float, dict[str, Any]]] = []
for entry, doc_tokens in zip(entries, doc_token_lists):
    score = bm25_score(query_tokens, doc_tokens, avg_doc_len)
    scored.append((score, entry))

scored.sort(key=lambda x: x[0], reverse=True)
top_results = [entry for score, entry in scored[:top_n] if score > 0]

if not top_results:
    print(f'[ref-query: no results for query: "{raw_query}"]', file=sys.stderr)
    sys.exit(0)

MAX_OUTPUT_LINES = 500

sep = "─" * 60
output_parts: list[str] = []
for i, entry in enumerate(top_results):
    if i > 0:
        output_parts.append(sep)
    output_parts.append(render_entry(entry, tier))

output = "\n".join(output_parts)
output_lines = output.splitlines()
if len(output_lines) > MAX_OUTPUT_LINES:
    print("\n".join(output_lines[:MAX_OUTPUT_LINES]))
    print(
        f"ref-query: output truncated at {MAX_OUTPUT_LINES} lines",
        file=sys.stderr,
    )
else:
    print(output)

sys.exit(0)
PYTHON_EOF
