#!/usr/bin/env bash
# apply-bucket-recipes.sh
# Apply per-bucket pointer-update recipes to consumer files identified by
# audit-closure-checks-source-consumers.sh (T2).
#
# Consumes the JSON envelope contract defined at:
#   ${CLAUDE_PLUGIN_ROOT}/docs/contracts/closure-checks-source-audit-output.md
#
# Implements the V1 recipe set for SC4 + SC5 of epic a03c-d55e-1393-4f27 /
# story 7e2c-2f4c-cd95-4e60 (DD7). V1 recipes are conservative: every bucket
# defaults to manual_review_required except for unambiguous no_op cases
# (dynamic loads, migration scripts, extant file-path references). Future
# versions can add programmatic rewrites once specific recipe patterns are
# validated.
#
# Usage:
#   apply-bucket-recipes.sh --audit-output <path> [--apply] [--bucket <bucket-name>]
#
# Flags:
#   --audit-output <path>   (required) JSON envelope from audit script.
#   --apply                 (optional) Actually mutate files. DEFAULT is dry-run.
#   --bucket <name>         (optional) Process only one bucket. Default: all six.
#
# SAFETY INVARIANT — DRY-RUN BY DEFAULT
#   `--dry-run` is the DEFAULT mode. `--apply` must be passed explicitly to
#   mutate files. This prevents an early sprint-active recipe sweep from
#   mass-rewriting consumer files before the audit JSON is human-reviewed.
#
#   validate.sh ONLY invokes the audit script (T2). It does NOT invoke this
#   recipe applier. The safety boundary is:
#     * validate.sh never mutates files.
#     * apply-bucket-recipes.sh is only invoked manually with explicit --apply.
#   This script MUST NEVER be wired into validate.sh, pre-commit hooks, or
#   any automated CI path.
#
# Output:
#   * Stdout — APPLY_BUCKET_RECIPES_SUMMARY block plus per-match action log
#     (apply mode only).
#   * JSON artifact at <target>/<plugin-git-path>/.audit-output/
#       recipe-application-<UTC-timestamp>-<nano-or-pid>.json
#     containing applied_at, audit_source, mode, actions[], summary.
#
# Exit codes:
#   0 — Success (dry-run or apply).
#   1 — Audit JSON input not found or invalid.
#   2 — Error during processing.

set -euo pipefail

# ── Self-location ────────────────────────────────────────────────────────────
_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Derive the repo-relative plugin path so we do not embed the literal
# plugin self-reference string in source (see check-plugin-self-ref.sh).
_PLUGIN_ROOT="${_SCRIPT_DIR%/scripts*}"
if _PLUGIN_REPO_ROOT="$(git -C "$_PLUGIN_ROOT" rev-parse --show-toplevel 2>/dev/null)"; then
    _PLUGIN_GIT_PATH="${_PLUGIN_ROOT#"$_PLUGIN_REPO_ROOT"/}"
else
    _PLUGIN_GIT_PATH="$(basename "$(dirname "$_PLUGIN_ROOT")")/$(basename "$_PLUGIN_ROOT")"
fi

# ── Parse arguments ──────────────────────────────────────────────────────────
_AUDIT_OUTPUT=""
_APPLY=0
_BUCKET=""

while [ $# -gt 0 ]; do
    case "$1" in
        --audit-output)
            if [ $# -lt 2 ]; then echo "Error: --audit-output requires a value" >&2; exit 2; fi
            _AUDIT_OUTPUT="$2"
            shift 2
            ;;
        --audit-output=*)
            _AUDIT_OUTPUT="${1#--audit-output=}"
            shift
            ;;
        --apply)
            _APPLY=1
            shift
            ;;
        --bucket)
            if [ $# -lt 2 ]; then echo "Error: --bucket requires a value" >&2; exit 2; fi
            _BUCKET="$2"
            shift 2
            ;;
        --bucket=*)
            _BUCKET="${1#--bucket=}"
            shift
            ;;
        *)
            echo "Error: unknown argument '$1'" >&2
            exit 2
            ;;
    esac
done

if [ -z "$_AUDIT_OUTPUT" ]; then
    echo "Error: --audit-output <path> is required" >&2
    exit 1
fi

if [ ! -f "$_AUDIT_OUTPUT" ]; then
    echo "Error: audit-output file '$_AUDIT_OUTPUT' not found" >&2
    exit 1
fi

# Resolve audit-output to absolute path for the actions log.
_AUDIT_OUTPUT="$(cd "$(dirname "$_AUDIT_OUTPUT")" && pwd)/$(basename "$_AUDIT_OUTPUT")"

# Resolve target (host project root containing the consumer files).
_TARGET="$(git -C "$_SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null)" || {
    echo "Error: not inside a git repository (cannot resolve target)" >&2
    exit 2
}

# ── Output artifact location ─────────────────────────────────────────────────
_OUTPUT_DIR="$_TARGET/${_PLUGIN_GIT_PATH}/.audit-output"
mkdir -p "$_OUTPUT_DIR"

# Timestamp with sub-second uniqueness so two runs within the same second do
# not collide. Mirrors the T2 audit script pattern.
_TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
_NANO=""
if date +%N >/dev/null 2>&1 && [ "$(date +%N)" != "N" ]; then
    _NANO="$(date +%N | head -c 6)"
fi
if [ -z "$_NANO" ]; then
    _NANO="$$$RANDOM"
fi
_OUTPUT_JSON="$_OUTPUT_DIR/recipe-application-${_TIMESTAMP}-${_NANO}.json"
while [ -e "$_OUTPUT_JSON" ]; do
    _NANO="${_NANO}x$RANDOM"
    _OUTPUT_JSON="$_OUTPUT_DIR/recipe-application-${_TIMESTAMP}-${_NANO}.json"
done

# ── Dispatch to embedded Python ──────────────────────────────────────────────
_python_exit=0
python3 - "$_AUDIT_OUTPUT" "$_OUTPUT_JSON" "$_TARGET" "$_APPLY" "$_BUCKET" <<'PYEOF' || _python_exit=$?
import datetime
import json
import os
import sys

AUDIT_OUTPUT = sys.argv[1]
OUTPUT_JSON = sys.argv[2]
TARGET = sys.argv[3]
APPLY = sys.argv[4] == "1"
BUCKET_FILTER = sys.argv[5]

ALL_BUCKETS = (
    "section-name-reference",
    "file-path-reference",
    "semantic-consumer",
    "test-asserting-on-structure",
    "user-facing-copy",
    "migration-in-progress",
)

# ── Load + validate envelope ─────────────────────────────────────────────────
try:
    with open(AUDIT_OUTPUT, "r", encoding="utf-8") as fh:
        envelope = json.load(fh)
except (OSError, json.JSONDecodeError) as exc:
    print(f"Error: cannot parse audit-output JSON: {exc}", file=sys.stderr)
    sys.exit(1)

schema_version = envelope.get("schema_version")
if not isinstance(schema_version, str) or not schema_version.startswith("1."):
    print(
        f"Error: unsupported schema_version {schema_version!r}; expected major version 1",
        file=sys.stderr,
    )
    sys.exit(1)

buckets = envelope.get("buckets") or {}
if not isinstance(buckets, dict):
    print("Error: envelope 'buckets' is not an object", file=sys.stderr)
    sys.exit(1)


# ── Per-bucket recipe functions ──────────────────────────────────────────────
# Each recipe returns one of:
#   {"action": "rewrite", "new_text": "..."}
#   {"action": "remove_line"}
#   {"action": "manual_review_required", "reason": "..."}
#   {"action": "no_op", "reason": "..."}
def _is_migration_script(file_path):
    """File-level heuristic: name contains 'migrate' (case-insensitive)."""
    return "migrate" in os.path.basename(file_path).lower()


def recipe_section_name_reference(match):
    """Literal `## Closure Checks` heading is already migrated. Stale
    references in copy or comments need context-sensitive rewrite.

    no_op when:
      * dynamic_load=True (variable interpolation — runtime resolution OK)
      * file is a migration script (transient by definition)
    Otherwise: manual_review_required.
    """
    if match.get("dynamic_load"):
        return {
            "action": "no_op",
            "reason": "dynamic-load reference resolves at runtime; no static rewrite needed",
        }
    if _is_migration_script(match.get("file", "")):
        return {
            "action": "no_op",
            "reason": "migration script — transient consumer, will be removed when migration completes",
        }
    return {
        "action": "manual_review_required",
        "reason": "heading already migrated; rewriting stale references is context-sensitive",
    }


def recipe_file_path_reference(match):
    """If referenced file exists in repo, no_op (path is current).
    If missing, manual review (path moved)."""
    match_text = match.get("match_text") or ""
    file_path = match.get("file", "")
    # The match_text is typically a known schema-consumer filename (e.g.,
    # "migrate-closure-checks.sh"). We can't always know the directory
    # without context — search a small set of canonical locations.
    candidates = [
        os.path.join(TARGET, match_text),
        os.path.join(TARGET, "plugins", "dso", "scripts", match_text),
        os.path.join(TARGET, "plugins", "dso", "docs", "contracts", match_text),
        os.path.join(TARGET, "plugins", "dso", "agents", match_text),
        os.path.join(TARGET, os.path.dirname(file_path), match_text),
    ]
    for cand in candidates:
        if os.path.isfile(cand):
            return {
                "action": "no_op",
                "reason": f"referenced file exists at {os.path.relpath(cand, TARGET)}",
            }
    return {
        "action": "manual_review_required",
        "reason": f"referenced file '{match_text}' not found at canonical locations; path may have moved",
    }


def recipe_semantic_consumer(match):
    """Consumer code requires per-site review — assertion targets, parser
    expectations, generator output shapes are all context-dependent."""
    return {
        "action": "manual_review_required",
        "reason": "consumer code requires per-site review; verify reads/writes target the new section schema",
    }


def recipe_test_asserting_on_structure(match):
    """Test assertions are intentional, but the assertion target may have
    changed (e.g., new heading, new schema). Always manual."""
    return {
        "action": "manual_review_required",
        "reason": "test assertion may target legacy schema; verify it asserts on the new `## Closure Checks` heading and one-shot-verifiable items (SC9)",
    }


def recipe_user_facing_copy(match):
    """Prose changes need human judgment — wording, tone, surrounding context."""
    return {
        "action": "manual_review_required",
        "reason": "user-facing copy requires human judgment for wording and tone",
    }


def recipe_migration_in_progress(match):
    """Migration tooling is transient by definition; will be removed when
    migration completes. Manual review confirms transient status."""
    return {
        "action": "manual_review_required",
        "reason": "migration tooling is transient; confirm whether to remove now or defer until migration completes",
    }


RECIPES = {
    "section-name-reference": recipe_section_name_reference,
    "file-path-reference": recipe_file_path_reference,
    "semantic-consumer": recipe_semantic_consumer,
    "test-asserting-on-structure": recipe_test_asserting_on_structure,
    "user-facing-copy": recipe_user_facing_copy,
    "migration-in-progress": recipe_migration_in_progress,
}


# ── Apply recipes ────────────────────────────────────────────────────────────
actions = []
summary = {
    "applied": 0,
    "manual_review_required": 0,
    "no_op": 0,
    "errors": 0,
    "rewrite": 0,
    "remove_line": 0,
}
per_bucket_summary = {
    name: {"rewrite": 0, "remove_line": 0, "manual": 0, "no_op": 0, "errors": 0}
    for name in ALL_BUCKETS
}
total_matches = 0

buckets_to_process = ALL_BUCKETS
if BUCKET_FILTER:
    if BUCKET_FILTER not in ALL_BUCKETS:
        print(
            f"Error: --bucket '{BUCKET_FILTER}' is not a recognized bucket; "
            f"valid buckets: {', '.join(ALL_BUCKETS)}",
            file=sys.stderr,
        )
        sys.exit(2)
    buckets_to_process = (BUCKET_FILTER,)

for bucket_name in buckets_to_process:
    items = buckets.get(bucket_name) or []
    if not isinstance(items, list):
        # Defensive: contract requires arrays, but tolerate malformed input.
        summary["errors"] += 1
        per_bucket_summary[bucket_name]["errors"] += 1
        continue
    recipe = RECIPES[bucket_name]
    for item in items:
        if not isinstance(item, dict):
            summary["errors"] += 1
            per_bucket_summary[bucket_name]["errors"] += 1
            continue
        total_matches += 1
        try:
            action = recipe(item)
        except Exception as exc:  # noqa: BLE001 - surface as error in actions log
            summary["errors"] += 1
            per_bucket_summary[bucket_name]["errors"] += 1
            actions.append({
                "file": item.get("file"),
                "line": item.get("line"),
                "bucket": bucket_name,
                "action": "error",
                "reason": f"recipe raised: {exc}",
            })
            continue

        action_kind = action.get("action", "no_op")
        action_record = {
            "file": item.get("file"),
            "line": item.get("line"),
            "bucket": bucket_name,
            "action": action_kind,
        }
        for k in ("new_text", "reason"):
            if k in action:
                action_record[k] = action[k]

        # In apply mode, mutating actions (rewrite, remove_line) would apply
        # here. V1 recipes never emit those, so this path is intentionally
        # unreached. The structure is here for V2+ extension.
        if APPLY and action_kind in ("rewrite", "remove_line"):
            # Future: apply the mutation to the file at item["line"].
            # V1 ships zero auto-rewrites; recipes only emit no_op /
            # manual_review_required. Future versions will land mutation
            # logic + before/after hash recording here.
            summary["applied"] += 1
            if action_kind == "rewrite":
                summary["rewrite"] += 1
                per_bucket_summary[bucket_name]["rewrite"] += 1
            else:
                summary["remove_line"] += 1
                per_bucket_summary[bucket_name]["remove_line"] += 1
        elif action_kind == "manual_review_required":
            summary["manual_review_required"] += 1
            per_bucket_summary[bucket_name]["manual"] += 1
        elif action_kind == "no_op":
            summary["no_op"] += 1
            per_bucket_summary[bucket_name]["no_op"] += 1
        else:
            # Unknown action kind — treat as error.
            summary["errors"] += 1
            per_bucket_summary[bucket_name]["errors"] += 1

        actions.append(action_record)

# ── Write JSON output ────────────────────────────────────────────────────────
applied_at = datetime.datetime.now(datetime.timezone.utc).isoformat()
mode = "apply" if APPLY else "dry-run"

output_envelope = {
    "applied_at": applied_at,
    "audit_source": AUDIT_OUTPUT,
    "mode": mode,
    "schema_version": "1.0",
    "actions": actions,
    "summary": summary,
}

with open(OUTPUT_JSON, "w", encoding="utf-8") as fh:
    json.dump(output_envelope, fh, indent=2, sort_keys=True)
    fh.write("\n")

# ── Emit summary report to stdout ────────────────────────────────────────────
print("APPLY_BUCKET_RECIPES_SUMMARY:")
print(f"  Mode:                  {mode}")
if not APPLY:
    print("  (dry-run — no files were modified. Pass --apply to mutate.)")
print(f"  Total matches:         {total_matches}")
print("  Per-bucket actions:")
for bucket_name in ALL_BUCKETS:
    if BUCKET_FILTER and bucket_name != BUCKET_FILTER:
        continue
    pb = per_bucket_summary[bucket_name]
    print(
        f"    {bucket_name:30s}  rewrite={pb['rewrite']}, "
        f"remove_line={pb['remove_line']}, manual={pb['manual']}, "
        f"no_op={pb['no_op']}, errors={pb['errors']}"
    )
print(f"  Applied: {summary['applied']}")
print(f"  Manual review required: {summary['manual_review_required']}")
print(f"  No-op: {summary['no_op']}")
print(f"  Errors: {summary['errors']}")
print(f"  Actions log: {OUTPUT_JSON}")

if APPLY:
    print("")
    print("Per-match action log:")
    for a in actions:
        reason = a.get("reason", "")
        print(f"  [{a['bucket']}] {a['file']}:{a['line']} -> {a['action']}"
              + (f" ({reason})" if reason else ""))

sys.exit(0)
PYEOF

# ── Propagate Python exit code ───────────────────────────────────────────────
exit "$_python_exit"
