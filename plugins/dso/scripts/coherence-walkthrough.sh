#!/usr/bin/env bash
# coherence-walkthrough.sh
#
# Phase 4 cutover gate orchestrator — story 5362-7f18-4f37-4fa9.
#
# Builds the dispatch package for the six-chunk multi-opus coherence
# walkthrough that gates Phase 4 migration of epic a03c-d55e-1393-4f27.
#
# The actual Agent tool calls (six opus dispatches in parallel) are made by
# the SKILL that invokes this script — not by the script itself. Bash cannot
# dispatch Anthropic Agent tools; only the calling LLM context can. This
# script's job is to prepare every artifact the dispatcher needs:
#   1. Pre-flight: run closure-checks-migration-preview.sh for chunk F's input
#   2. Emit a JSON manifest of six chunk dispatches, each with:
#        - workflow_stage
#        - prompt_text (rubric + chunk-prompt concatenation; chunk F also has
#          preview output inlined)
#        - dispatch_model: opus
#        - timeout_seconds: 600
#   3. Emit an aggregation contract pointer (docs/contracts/...)
#
# The dispatcher then:
#   - Reads the manifest
#   - Issues six Agent tool calls in a single message (parallel)
#   - On any parse failure / timeout, retries that chunk once
#   - On second failure, synthesizes tech_failure: true output per contract §3
#   - Aggregates the six JSON outputs into the report shape per contract §2
#   - Attaches the aggregated report as a ticket comment on --epic-id
#
# Reuse profile: one-shot, lightly parameterized (story 5362 Brainstorm
# Decision §1). The script accepts --epic-id so a future schema-migration
# epic could in principle re-fire it without code changes. No profile
# schema, no cost ceiling, no caching.
#
# Usage:
#   coherence-walkthrough.sh --epic-id <id> [--limit N] [--manifest FILE]
#
# Flags:
#   --epic-id <id>   Required. The epic being gated. Used for the
#                    aggregated-report ticket comment target. Typically
#                    a03c-d55e-1393-4f27.
#   --limit N        Pass-through to closure-checks-migration-preview.sh
#                    --limit. Default: 10.
#   --manifest F     Write the dispatch manifest JSON to FILE. Default:
#                    stdout. The dispatcher (calling skill) reads this file.
#
# Estimated cost per run: 6 opus dispatches + 1 haiku preview batch.
# At a single Phase 4 cutover this is a bounded one-time cost.
#
# Exit codes:
#   0 — Manifest emitted successfully (the actual dispatch outcome is
#       determined by the calling skill, not by this script).
#   1 — Hard error (missing --epic-id, ticket CLI unavailable, preview
#       script not found, prompt file missing).
#   2 — Soft error (preview script returned a preview_error). Manifest is
#       still emitted; chunk F's prompt has the error inlined and will
#       emit AMBIGUOUS.

set -uo pipefail

# ── Resolve repo root and plugin paths ──────────────────────────────────────
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"
if [[ -z "$REPO_ROOT" ]]; then
    echo "Error: not in a git repository" >&2
    exit 1
fi

# Resolve plugin root from $REPO_ROOT + dso.plugin_root in dso-config.conf.
# We deliberately do NOT use the CLAUDE_PLUGIN_ROOT env var here: when this
# script runs inside a worktree, the env var may point at a different repo's
# plugin directory (set by the calling shell). Reading from the per-repo
# dso-config.conf guarantees we resolve against the current REPO_ROOT.
# Avoids hardcoded plugin path per the plugin-self-ref pre-commit rule.
_cfg_root="$(grep '^dso\.plugin_root=' "$REPO_ROOT/.claude/dso-config.conf" 2>/dev/null | cut -d= -f2-)"
if [[ -z "$_cfg_root" ]]; then
    echo "Error: cannot resolve plugin root (dso.plugin_root absent from .claude/dso-config.conf)" >&2
    exit 1
fi
if [[ "$_cfg_root" = /* ]]; then
    PLUGIN_ROOT="$_cfg_root"
else
    PLUGIN_ROOT="$REPO_ROOT/$_cfg_root"
fi
PROMPTS_DIR="$PLUGIN_ROOT/skills/coherence-walk/prompts"
PREVIEW_SCRIPT="$PLUGIN_ROOT/scripts/closure-checks-migration-preview.sh"
CONTRACT_DOC="docs/contracts/coherence-walkthrough-chunk-output.md"

# ── Parse arguments ──────────────────────────────────────────────────────────
EPIC_ID=""
LIMIT=10
MANIFEST_FILE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --epic-id)
            EPIC_ID="$2"
            shift 2
            ;;
        --epic-id=*)
            EPIC_ID="${1#--epic-id=}"
            shift
            ;;
        --limit)
            LIMIT="$2"
            shift 2
            ;;
        --limit=*)
            LIMIT="${1#--limit=}"
            shift
            ;;
        --manifest)
            MANIFEST_FILE="$2"
            shift 2
            ;;
        --manifest=*)
            MANIFEST_FILE="${1#--manifest=}"
            shift
            ;;
        --help|-h)
            sed -n '2,55p' "$0"
            exit 0
            ;;
        *)
            echo "Error: unknown argument: $1" >&2
            exit 1
            ;;
    esac
done

if [[ -z "$EPIC_ID" ]]; then
    echo "Error: --epic-id is required" >&2
    exit 1
fi

if [[ ! -d "$PROMPTS_DIR" ]]; then
    echo "Error: prompts directory not found: $PROMPTS_DIR" >&2
    exit 1
fi

if [[ ! -x "$PREVIEW_SCRIPT" ]]; then
    echo "Error: preview script not found or not executable: $PREVIEW_SCRIPT" >&2
    exit 1
fi

# ── Verify all required prompt files exist ──────────────────────────────────
RUBRIC_FILE="$PROMPTS_DIR/verdict-rubric.md"
CHUNK_A="$PROMPTS_DIR/chunk-a-brainstorm.md"
CHUNK_B="$PROMPTS_DIR/chunk-b-preplanning.md"
CHUNK_C="$PROMPTS_DIR/chunk-c-implementation-plan.md"
CHUNK_D="$PROMPTS_DIR/chunk-d-sprint.md"
CHUNK_E="$PROMPTS_DIR/chunk-e-commit-and-review.md"
CHUNK_F="$PROMPTS_DIR/chunk-f-operational-dry-run.md"

for f in "$RUBRIC_FILE" "$CHUNK_A" "$CHUNK_B" "$CHUNK_C" "$CHUNK_D" "$CHUNK_E" "$CHUNK_F"; do
    if [[ ! -f "$f" ]]; then
        echo "Error: required prompt file missing: $f" >&2
        exit 1
    fi
done

# ── Phase 1: run preview script for chunk F input ───────────────────────────
PREVIEW_TMP="$(mktemp /tmp/coherence-preview-output.XXXXXX.json)"
WORKDIR="$(mktemp -d /tmp/coherence-walkthrough.XXXXXX)"
trap 'rm -f "$PREVIEW_TMP"; rm -rf "$WORKDIR"' EXIT

PREVIEW_EXIT=0
"$PREVIEW_SCRIPT" --limit="$LIMIT" --output="$PREVIEW_TMP" || PREVIEW_EXIT=$?

if [[ $PREVIEW_EXIT -gt 2 ]]; then
    echo "Error: preview script failed with unexpected exit code $PREVIEW_EXIT" >&2
    exit 1
fi

# Tag this run so the caller knows whether to expect AMBIGUOUS from chunk F
SCRIPT_EXIT_CODE=0
if [[ $PREVIEW_EXIT -eq 2 ]]; then
    SCRIPT_EXIT_CODE=2
fi

# ── Phase 2: assemble the six chunk prompts on disk ─────────────────────────
# For each chunk: write rubric + separator + chunk-specific content to a
# file under $WORKDIR. Chunk F additionally substitutes the
# <<<PREVIEW_OUTPUT_PLACEHOLDER>>> token with the preview JSON.

SEPARATOR=$'\n\n---\n\n'

assemble_static_chunk() {
    local out="$1"
    local chunk_src="$2"
    {
        cat "$RUBRIC_FILE"
        printf '%s' "$SEPARATOR"
        cat "$chunk_src"
    } > "$out"
}

assemble_chunk_f() {
    local out="$1"
    python3 - "$RUBRIC_FILE" "$CHUNK_F" "$PREVIEW_TMP" "$out" <<'PYEOF'
import sys
rubric_path, chunk_path, preview_path, out_path = sys.argv[1:]
with open(rubric_path) as f:
    rubric = f.read()
with open(chunk_path) as f:
    chunk = f.read()
with open(preview_path) as f:
    preview = f.read().strip()
content = rubric + "\n\n---\n\n" + chunk.replace("<<<PREVIEW_OUTPUT_PLACEHOLDER>>>", preview)
with open(out_path, "w") as f:
    f.write(content)
PYEOF
}

assemble_static_chunk "$WORKDIR/chunk-a.txt" "$CHUNK_A"
assemble_static_chunk "$WORKDIR/chunk-b.txt" "$CHUNK_B"
assemble_static_chunk "$WORKDIR/chunk-c.txt" "$CHUNK_C"
assemble_static_chunk "$WORKDIR/chunk-d.txt" "$CHUNK_D"
assemble_static_chunk "$WORKDIR/chunk-e.txt" "$CHUNK_E"
assemble_chunk_f      "$WORKDIR/chunk-f.txt"

# ── Phase 3: emit the dispatch manifest ─────────────────────────────────────
# Python builds the JSON, reading each chunk prompt from disk. This avoids
# shell-variable quoting issues with multi-thousand-character prompt bodies.

MANIFEST="$(python3 - "$EPIC_ID" "$CONTRACT_DOC" "$PREVIEW_EXIT" "$WORKDIR" <<'PYEOF'
import json, sys
epic_id, contract_doc, preview_exit, workdir = sys.argv[1:]

def read_chunk(letter):
    with open(f"{workdir}/chunk-{letter}.txt") as f:
        return f.read()

manifest = {
    "schema_version": 1,
    "contract_doc": contract_doc,
    "epic_id": epic_id,
    "preview_exit_code": int(preview_exit),
    "dispatch_model": "opus",
    "timeout_seconds": 600,
    "parallel_dispatch": True,
    "retry_policy": {
        "retries_per_chunk": 1,
        "on_persistent_failure": "synthesize_tech_failure_ambiguous",
    },
    "chunks": [
        {"workflow_stage": "brainstorm",          "prompt": read_chunk("a")},
        {"workflow_stage": "preplanning",         "prompt": read_chunk("b")},
        {"workflow_stage": "implementation-plan", "prompt": read_chunk("c")},
        {"workflow_stage": "sprint",              "prompt": read_chunk("d")},
        {"workflow_stage": "commit-and-review",   "prompt": read_chunk("e")},
        {"workflow_stage": "operational-dry-run", "prompt": read_chunk("f")},
    ],
    "aggregation_instructions": (
        "After all six chunks return (with one retry per failing chunk), "
        f"aggregate JSON outputs into the report shape per {contract_doc} §2. "
        "Compute overall_verdict: PASS iff all six are status=PASS and "
        "tech_failure=false; BLOCKED otherwise. Attach the aggregated report "
        f"as a ticket comment on epic_id {epic_id}."
    ),
}

print(json.dumps(manifest, indent=2))
PYEOF
)"

if [[ -n "$MANIFEST_FILE" ]]; then
    printf '%s\n' "$MANIFEST" > "$MANIFEST_FILE"
    echo "Manifest written to: $MANIFEST_FILE"
    echo "Chunks: 6 (brainstorm, preplanning, implementation-plan, sprint, commit-and-review, operational-dry-run)"
    echo "Preview exit code: $PREVIEW_EXIT"
    echo "Aggregation target: epic $EPIC_ID"
else
    printf '%s\n' "$MANIFEST"
fi

exit $SCRIPT_EXIT_CODE
