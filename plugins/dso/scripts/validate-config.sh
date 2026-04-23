#!/usr/bin/env bash
set -uo pipefail
# scripts/validate-config.sh
# Validates a dso-config.conf file against KNOWN_KEYS.
#
# Usage: validate-config.sh [config-file]
#   config-file defaults to resolution order from read-config.sh
#
# Exit codes:
#   0 — all keys recognized, no errors
#   1 — unknown keys, duplicate scalar keys, or blank key names found

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$SCRIPT_DIR/..}"
[[ ! -f "${CLAUDE_PLUGIN_ROOT}/plugin.json" ]] && CLAUDE_PLUGIN_ROOT="$SCRIPT_DIR/.."

# ── KNOWN_KEYS — all valid dot-notation keys ────────────────────────────────
KNOWN_KEYS=(
    # Top-level
    version
    stack

    # Paths
    paths.app_dir
    paths.src_dir
    paths.test_dir
    paths.test_unit_dir

    # Interpreter
    interpreter.python_venv

    # Format
    format.extensions
    format.source_dirs

    # Staging
    staging.url
    staging.deploy_check
    staging.test
    staging.routes
    staging.health_path

    # CI
    ci.fast_gate_job
    ci.fast_fail_job
    ci.test_ceil_job
    ci.integration_workflow
    ci.workflow_name

    # Commands
    commands.test
    commands.lint
    commands.format
    commands.format_check
    commands.validate
    commands.test_unit
    commands.test_changed
    commands.lint_fix
    commands.env_check_cmd
    commands.env_check_app
    commands.test_e2e
    commands.test_visual
    commands.syntax_check
    commands.lint_ruff
    commands.lint_mypy
    commands.build
    # Database
    database.base_port
    database.ensure_cmd
    database.status_cmd
    database.port_cmd

    # Infrastructure
    infrastructure.app_base_port
    infrastructure.container_prefix
    infrastructure.compose_project
    infrastructure.compose_db_file
    infrastructure.compose_files

    # Session
    session.usage_check_cmd
    session.artifact_prefix

    # Jira
    jira.project

    # Issue tracker
    issue_tracker.search_cmd

    # Design
    design.system_name
    design.component_library
    design.template_engine
    design.design_notes_path
    design.manifest_patterns
    design.figma_pat

    # Merge
    merge.visual_baseline_path
    merge.ci_workflow_name
    merge.message_exclusion_pattern

    # Visual
    visual.baseline_directory

    # Worktree
    worktree.python_version
    worktree.post_create_cmd
    worktree.branch_pattern
    worktree.max_age_hours
    worktree.service_start_cmd

    # Skills
    skills.playwright_debug_reference

    # Preplanning
    preplanning.interactive

    # Planning
    planning.external_dependency_block_enabled

    # Persistence — source patterns
    persistence.source_patterns
    persistence.test_patterns

    # Checks
    checks.script_write_scan_dir
    checks.assertion_density_cmd

    # Checkpoint
    checkpoint.marker_file
    checkpoint.commit_label

    # DSO plugin self-reference (plugin repo only)
    dso.plugin_root

    # Version
    version.file_path

    # Tickets
    tickets.prefix
    tickets.directory
    tickets.sync.jira_project_key
    tickets.sync.bidirectional_comments
)

# ── KNOWN_LIST_KEYS — keys that allow repetition ────────────────────────────
KNOWN_LIST_KEYS=(
    format.extensions
    format.source_dirs
    staging.routes
    infrastructure.compose_files
    design.manifest_patterns
    persistence.source_patterns
    persistence.test_patterns
)

# ── Resolve config file ─────────────────────────────────────────────────────
config_file="${1:-}"
if [[ -z "$config_file" ]]; then
    root="${CLAUDE_PLUGIN_ROOT}"
    if [[ -f "$root/.claude/dso-config.conf" ]]; then
        config_file="$root/.claude/dso-config.conf"
    else
        # No config file found — nothing to validate
        exit 0
    fi
fi

if [[ ! -f "$config_file" ]]; then
    echo "ERROR: config file not found: $config_file" >&2
    exit 1
fi

# ── Helper: check if key is in KNOWN_KEYS ───────────────────────────────────
_is_known_key() {
    local needle="$1"
    for k in "${KNOWN_KEYS[@]}"; do
        [[ "$k" == "$needle" ]] && return 0
    done
    return 1
}

# ── Helper: check if key is a list key ───────────────────────────────────────
_is_list_key() {
    local needle="$1"
    for k in "${KNOWN_LIST_KEYS[@]}"; do
        [[ "$k" == "$needle" ]] && return 0
    done
    return 1
}

# ── Parse and validate ──────────────────────────────────────────────────────
errors=0
declare -A seen_keys

while IFS= read -r line; do
    # Skip blank lines and comments
    [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue

    # Extract key (everything before first =)
    key="${line%%=*}"

    # Check for blank key
    if [[ -z "$key" || "$key" == "$line" ]]; then
        if [[ "$key" == "$line" ]]; then
            # No = sign found — skip non-KV lines
            continue
        fi
        echo "ERROR: blank key name on line: $line" >&2
        (( errors++ ))
        continue
    fi

    # Trim leading/trailing whitespace from key
    key="$(echo "$key" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"

    # Check for blank key after trimming
    if [[ -z "$key" ]]; then
        echo "ERROR: blank key name on line: $line" >&2
        (( errors++ ))
        continue
    fi

    # Check if key is known
    if ! _is_known_key "$key"; then
        echo "ERROR: unknown key: $key" >&2
        (( errors++ ))
        continue
    fi

    # Check for duplicate scalar keys
    if [[ -n "${seen_keys[$key]:-}" ]]; then
        if ! _is_list_key "$key"; then
            echo "ERROR: duplicate scalar key: $key" >&2
            (( errors++ ))
            continue
        fi
    fi
    seen_keys[$key]=1

done < "$config_file"

if [[ "$errors" -gt 0 ]]; then
    exit 1
fi
exit 0
