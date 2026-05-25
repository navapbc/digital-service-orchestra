#!/usr/bin/env bash
# ref-query.sh — BM25-style search across the UI reference corpus.
#
# Usage:
#   ref-query.sh <query> [--top-n <N>] [--tier=<summary|detail|implementation>]
#                        [--session-hash <H>] [--namespace=<DOMAIN>]
#                        [--format=<text|json>]
#
# Outputs the top-N matching corpus entries to stdout, including frontmatter fields
# and the requested content tier (summary by default).
#
# Options:
#   --namespace=DOMAIN   Filter results to entries whose domain matches DOMAIN
#                        (e.g. canon, components, gov-copy). Without this flag,
#                        results span all domains.
#   --format=FORMAT      Output format: 'text' (default, human-readable YAML-like
#                        documents) or 'json' (JSON array per ref-query-json-output
#                        schema at ${CLAUDE_PLUGIN_ROOT}/docs/contracts/ref-query-json-output.md).
#
# Exit codes:
#   0 — query completed (zero results also exits 0; check stderr for [ref-query: no results] sentinel)
#   1 — usage error or fatal failure
#
# Zero-result sentinel (emitted to stderr):
#   [ref-query: no results for query: "<query>"]
#
# Examples:
#   ref-query.sh "USWDS form validation" --top-n 3
#   ref-query.sh "keyboard navigation" --tier=detail --top-n 5
#   ref-query.sh "error message" --namespace=canon --format=json

set -euo pipefail

# ── Argument parsing ──────────────────────────────────────────────────────────

QUERY=""
TOP_N=8
TIER=""
SESSION_HASH=""
NAMESPACE=""
FORMAT="text"

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
            TIER="${2:-}"
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
        --namespace=*)
            NAMESPACE="${1#--namespace=}"
            shift
            ;;
        --namespace)
            NAMESPACE="${2:-}"
            shift 2
            ;;
        --format=*)
            FORMAT="${1#--format=}"
            shift
            ;;
        --format)
            FORMAT="${2:-text}"
            shift 2
            ;;
        --help|-h)
            printf 'Usage: ref-query.sh <query> [OPTIONS]\n\n'
            printf 'BM25 search across the UI reference corpus.\n\n'
            printf 'Options:\n'
            printf '  --top-n N                  Maximum number of results (default: 8)\n'
            printf '  --tier=TIER                Filter by tier (summary|detail|implementation)\n'
            printf '  --namespace=DOMAIN         Filter by domain (e.g. canon, components, gov-copy)\n'
            printf '  --format=FORMAT            Output format: text (default) or json\n'
            printf '  --session-hash HASH        Session hash for deduplication\n'
            printf '  --help                     Show this help\n\n'
            printf 'Examples:\n'
            printf '  ref-query.sh "USWDS form validation" --top-n 3\n'
            printf '  ref-query.sh "error message" --namespace=canon --format=json\n'
            exit 0
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
    printf 'ref-query.sh: usage: ref-query.sh <query> [--top-n N] [--tier=summary|detail|implementation] [--namespace=DOMAIN] [--format=text|json]\n' >&2
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

# Delegate to ref-query.py which provides the full implementation including
# --namespace and --format=json support.
REF_QUERY_PY="$SCRIPT_DIR/ref-query.py"

if [[ ! -f "$REF_QUERY_PY" ]]; then
    printf 'ref-query.sh: ref-query.py not found at: %s\n' "$REF_QUERY_PY" >&2
    exit 1
fi

# Build argument list for ref-query.py
PY_ARGS=(
    "$QUERY"
    "--corpus=$CORPUS_ROOT"
    "--top-n=$TOP_N"
    "--format=$FORMAT"
)

if [[ -n "$TIER" ]]; then
    PY_ARGS+=("--tier=$TIER")
fi

if [[ -n "$NAMESPACE" ]]; then
    PY_ARGS+=("--namespace=$NAMESPACE")
fi

if [[ -n "$SESSION_HASH" ]]; then
    PY_ARGS+=("--session-hash=$SESSION_HASH")
fi

exec python3 "$REF_QUERY_PY" "${PY_ARGS[@]}"
