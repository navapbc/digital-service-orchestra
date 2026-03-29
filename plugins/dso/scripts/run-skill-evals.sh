#!/usr/bin/env bash
# plugins/dso/scripts/run-skill-evals.sh
# Orchestrator for running promptfoo evals across DSO skills.
#
# Usage:
#   run-skill-evals.sh <path1> [path2 ...]   # Tier 1: map changed paths to skill evals
#   run-skill-evals.sh --all                  # Tier 2: discover and run all skill evals
#   run-skill-evals.sh --help                 # Show usage information
#
# Exit codes:
#   0 — All evals passed (or no evals to run)
#   1 — One or more evals failed
#   2 — npx/promptfoo not available
#
# Output format:
#   Passes through promptfoo's native JSON output to stdout.
#   Progress and error messages go to stderr.
#
# Grader convention:
#   Each skill's evals/promptfooconfig.yaml defines its own grader model via
#   defaultTest.options.provider (Haiku by default). This script does NOT inject
#   --grader or --provider flags — config is passed through as-is.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
DSO_SKILLS_ROOT="${DSO_SKILLS_ROOT:-$PLUGIN_ROOT/plugins/dso/skills}"

# ── Usage ────────────────────────────────────────────────────────────────────
_usage() {
    cat <<EOF
Usage:
  run-skill-evals.sh <path1> [path2 ...]   Tier 1: map changed file paths to skill evals
  run-skill-evals.sh --all                  Tier 2: discover and run all skill evals
  run-skill-evals.sh --help                 Show this help message

Exit codes:
  0  All evals passed (or nothing to run)
  1  One or more evals failed
  2  npx not available

Environment:
  DSO_SKILLS_ROOT   Override the default skills root directory
EOF
}

# ── Validate promptfooconfig.yaml schema ─────────────────────────────────────
# Checks that required fields (providers, tests) exist in the config.
# Returns 0 if valid, 1 if invalid.
_validate_config() {
    local config_path="$1"
    local has_providers=false
    local has_tests=false

    while IFS= read -r line; do
        # Match top-level keys (no leading whitespace)
        if [[ "$line" =~ ^providers: ]] || [[ "$line" =~ ^providers$ ]]; then
            has_providers=true
        fi
        if [[ "$line" =~ ^tests: ]] || [[ "$line" =~ ^tests$ ]]; then
            has_tests=true
        fi
    done < "$config_path"

    if [[ "$has_providers" != "true" ]] || [[ "$has_tests" != "true" ]]; then
        echo "ERROR: Invalid config $config_path — missing required fields (providers and/or tests)" >&2
        return 1
    fi
    return 0
}

# ── Extract skill directory from a file path ─────────────────────────────────
# Given a path like /tmp/skills/fix-bug/SKILL.md, extracts /tmp/skills/fix-bug
_extract_skill_dir() {
    local path="$1"
    local skills_root="$DSO_SKILLS_ROOT"

    # Strip the skills root prefix to get the relative path
    local rel="${path#"$skills_root"/}"
    # The skill name is the first path component
    local skill_name="${rel%%/*}"
    if [[ -n "$skill_name" ]]; then
        echo "$skills_root/$skill_name"
    fi
}

# ── Main ─────────────────────────────────────────────────────────────────────

if [[ "${1:-}" == "--help" ]]; then
    _usage
    exit 0
fi

# Check npx availability
if ! command -v npx >/dev/null 2>&1; then
    echo "ERROR: npx is not available on PATH. Install Node.js/npm to run promptfoo evals." >&2
    exit 2
fi

# Collect config paths to run
declare -a configs=()

if [[ "${1:-}" == "--all" ]]; then
    # Tier 2: discover all eval configs
    while IFS= read -r config; do
        configs+=("$config")
    done < <(find "$DSO_SKILLS_ROOT" -path '*/evals/promptfooconfig.yaml' -type f 2>/dev/null | sort)
else
    # Tier 1: map changed paths to skill eval configs (deduplicated)
    seen_skills=""
    for path in "$@"; do
        skill_dir="$(_extract_skill_dir "$path")"
        if [[ -z "$skill_dir" ]]; then
            continue
        fi
        # Deduplicate by skill directory (bash 3 compatible)
        case "$seen_skills" in
            *"|${skill_dir}|"*) continue ;;
        esac
        seen_skills="${seen_skills}|${skill_dir}|"

        local_config="$skill_dir/evals/promptfooconfig.yaml"
        if [[ -f "$local_config" ]]; then
            configs+=("$local_config")
        fi
        # If no evals/ dir, silently skip
    done
fi

# Nothing to run = success
if [[ ${#configs[@]} -eq 0 ]]; then
    exit 0
fi

# Validate all configs before running any
for config in "${configs[@]}"; do
    if ! _validate_config "$config"; then
        exit 1
    fi
done

# Run evals
overall_exit=0
for config in "${configs[@]}"; do
    echo "Running eval: $config" >&2
    npx promptfoo eval --config "$config"
    eval_exit=$?
    if [[ $eval_exit -ne 0 ]]; then
        overall_exit=1
    fi
done

exit $overall_exit
