#!/usr/bin/env bash
# apply-two-pass-ordering.sh
#
# Two-pass ordering helper for sprint batch sequencing of migration task pairs.
#
# Reads the persisted MIGRATION_CLASS marker from a story ticket comment and
# wires depends_on edges via `dso ticket link` for each migration task pair:
#   - sweep class:  manual-verification depends_on automated-sweep
#   - db class:     rollback-verification depends_on forward-migration
#   - flag pair:    flag-cleanup depends_on flag-cutover (role presence only)
#
# NEVER recomputes migration-class detection (no detection binary invocation).
# Idempotent: checks existing links before writing; skips duplicates.
# Emits no edges and exits 0 for absent-marker or inconclusive.
#
# Contract: ${CLAUDE_PLUGIN_ROOT}/docs/contracts/migration-class-marker.md
# Key spelling: "migration-class" (hyphenated) — the persisted marker key.
# Tags convention: tasks carry migration-role:<role> tags (pair halves by tag).
#
# Usage:
#   apply-two-pass-ordering.sh --story-id <id> --tasks "<task-id>:<role> ..."
#
# --tasks format: space-separated "task-id:migration-role" pairs
#   valid roles: automated-sweep, manual-verification, forward-migration,
#                rollback-verification, flag-cutover, flag-cleanup
#
# Exit codes:
#   0  success (edges written or none needed)
#   1  usage error (missing required arguments)

set -uo pipefail

# ── Argument parsing ──────────────────────────────────────────────────────────
STORY_ID=""
TASKS_ARG=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --story-id)
            STORY_ID="${2:-}"
            shift 2
            ;;
        --tasks)
            TASKS_ARG="${2:-}"
            shift 2
            ;;
        *)
            echo "ERROR: unknown argument: $1" >&2
            echo "Usage: $0 --story-id <id> --tasks \"<task-id>:<role> ...\"" >&2
            exit 1
            ;;
    esac
done

if [[ -z "$STORY_ID" ]]; then
    echo "ERROR: --story-id is required" >&2
    exit 1
fi

# ── Locate dso CLI ────────────────────────────────────────────────────────────
# Use the dso shim on PATH (set by caller or test stub)
DSO_CMD="dso"

# ── Read the LAST MIGRATION_CLASS marker from story ticket comments ───────────
# Contract: migration-class-marker.md — read LAST matching comment, last-wins.
# Key spelling: "migration-class" (hyphenated, per contract).
# Reads persisted marker only — does NOT invoke any detection binary.
read_marker_line() {
    local story_id="$1"
    local story_json
    story_json=$("$DSO_CMD" ticket show "$story_id" 2>/dev/null) || {
        echo "WARNING: could not read ticket $story_id" >&2
        echo ""
        return 0
    }

    # Extract all comment bodies using jq, filter for MIGRATION_CLASS prefix,
    # take the LAST matching line (append-only / last-wins per contract).
    echo "$story_json" \
        | jq -r '.comments[].body' 2>/dev/null \
        | grep '^MIGRATION_CLASS:' \
        | tail -1
}

# ── Parse migration-class value from marker line ──────────────────────────────
# Input: "MIGRATION_CLASS: {\"migration-class\":\"sweep\",...}"
# Output: "sweep", "db", "inconclusive", or ""
parse_marker_value() {
    local marker_line="$1"
    if [[ -z "$marker_line" ]]; then
        echo ""
        return 0
    fi
    # Extract the JSON payload after "MIGRATION_CLASS: "
    local json_payload="${marker_line#MIGRATION_CLASS: }"
    # Use jq to extract the hyphenated "migration-class" key
    local mvalue
    mvalue=$(echo "$json_payload" | jq -r '.["migration-class"]' 2>/dev/null) || {
        echo "" ; return 0
    }
    # Guard against jq "null" output
    if [[ "$mvalue" == "null" ]]; then
        echo ""
    else
        echo "$mvalue"
    fi
}

# ── Parse task roles from --tasks argument ────────────────────────────────────
# Input: "task-a:automated-sweep task-b:manual-verification"
# Sets associative array: role_to_task[role]=task-id
# Pair halves are identified by migration-role:<role> tags on task tickets.
declare -A role_to_task

parse_task_roles() {
    local tasks_arg="$1"
    for entry in $tasks_arg; do
        local task_id="${entry%%:*}"
        local role="${entry#*:}"
        if [[ -n "$task_id" && -n "$role" && "$task_id" != "$entry" ]]; then
            role_to_task["$role"]="$task_id"
        fi
    done
}

# ── Idempotent link writer ────────────────────────────────────────────────────
# Checks if depends_on edge already exists before writing.
# Args: <dependent-task-id> <earlier-task-id>
write_depends_on_edge() {
    local dependent="$1"
    local earlier="$2"

    # Check existing links on the dependent task via list-links subcommand
    local existing_links
    existing_links=$("$DSO_CMD" ticket list-links "$dependent" 2>/dev/null) || true

    # Check if "depends_on <earlier>" already exists in the output
    if echo "$existing_links" | grep -q "^depends_on ${earlier}$"; then
        echo "INFO: edge already exists: $dependent depends_on $earlier — skipping" >&2
        return 0
    fi

    # Write the edge: dso ticket link <dependent> <earlier> depends_on
    "$DSO_CMD" ticket link "$dependent" "$earlier" depends_on
}

# ── Main logic ────────────────────────────────────────────────────────────────
main() {
    # Parse task roles from argument (tasks tagged with migration-role:<role>)
    if [[ -n "$TASKS_ARG" ]]; then
        parse_task_roles "$TASKS_ARG"
    fi

    # Read the persisted MIGRATION_CLASS marker (never recompute detection)
    local marker_line
    marker_line=$(read_marker_line "$STORY_ID")

    # Extract the "migration-class" value (hyphenated key per contract)
    local mclass
    mclass=$(parse_marker_value "$marker_line")

    # Track whether any edges were written
    local edges_written=0

    # ── sweep: manual-verification depends_on automated-sweep ────────────────
    if [[ "$mclass" == "sweep" ]]; then
        local sweep_task="${role_to_task[automated-sweep]:-}"
        local manual_task="${role_to_task[manual-verification]:-}"
        if [[ -n "$sweep_task" && -n "$manual_task" ]]; then
            write_depends_on_edge "$manual_task" "$sweep_task"
            (( ++edges_written )) || true
        fi
    fi

    # ── db: rollback-verification depends_on forward-migration ───────────────
    if [[ "$mclass" == "db" ]]; then
        local fwd_task="${role_to_task[forward-migration]:-}"
        local rollback_task="${role_to_task[rollback-verification]:-}"
        if [[ -n "$fwd_task" && -n "$rollback_task" ]]; then
            write_depends_on_edge "$rollback_task" "$fwd_task"
            (( ++edges_written )) || true
        fi
    fi

    # ── feature-flag pair: flag-cleanup depends_on flag-cutover ──────────────
    # Detected by role presence only (NOT by migration-class value).
    # Independent of MIGRATION_CLASS marker — wired whenever both roles present.
    local cutover_task="${role_to_task[flag-cutover]:-}"
    local cleanup_task="${role_to_task[flag-cleanup]:-}"
    if [[ -n "$cutover_task" && -n "$cleanup_task" ]]; then
        write_depends_on_edge "$cleanup_task" "$cutover_task"
        (( ++edges_written )) || true
    fi

    # ── Absent-marker / inconclusive: emit NO_MARKER status ──────────────────
    if [[ $edges_written -eq 0 ]]; then
        local class_display="${mclass:-none}"
        echo "INFO: NO_MARKER — no edges written for story $STORY_ID (migration-class=${class_display})" >&2
    fi

    exit 0
}

main
