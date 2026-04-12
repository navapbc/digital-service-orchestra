#!/usr/bin/env bash
# ci-generator.sh
# Generate GitHub Actions workflow YAML from discovered test suites.
#
# Usage:
#   ci-generator.sh --suites-json <json_or_file> --output-dir <dir> [--non-interactive]
#
# Arguments:
#   --suites-json <value>   JSON array of suite objects (as string or @file path)
#   --output-dir  <dir>     Directory where ci.yml / ci-slow.yml are written
#   --non-interactive       Non-interactive mode (env CI_NONINTERACTIVE=1 also triggers this)
#
# JSON input schema (from project-detect.sh --suites):
#   name        (string) — short identifier for the suite
#   command     (string) — shell command to run the suite
#   speed_class (string) — "fast", "slow", or "unknown"
#   runner      (string) — one of: make, pytest, npm, bash, config
#
# Output files:
#   ci.yml       — fast suites, triggered on: pull_request
#   ci-slow.yml  — slow/unknown suites, triggered on: push to main
#
# Exit codes:
#   0 — success
#   1 — argument error
#   2 — YAML validation failure

set -euo pipefail

# ── Argument parsing ─────────────────────────────────────────────────────────

SUITES_JSON=""
OUTPUT_DIR=""
NON_INTERACTIVE="${CI_NONINTERACTIVE:-0}"

usage() {
    echo "Usage: ci-generator.sh --suites-json <json> --output-dir <dir> [--non-interactive]" >&2
    echo "  --suites-json  JSON array of suite objects or path to JSON file" >&2
    echo "  --output-dir   Directory where ci.yml / ci-slow.yml are written" >&2
    echo "  --non-interactive  Treat unknown speed_class as slow (no prompts)" >&2
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --suites-json)
            shift
            [[ $# -lt 1 ]] && { echo "Error: --suites-json requires a value" >&2; exit 1; }
            SUITES_JSON="$1"
            ;;
        --suites-json=*)
            SUITES_JSON="${1#--suites-json=}"
            ;;
        --output-dir)
            shift
            [[ $# -lt 1 ]] && { echo "Error: --output-dir requires a value" >&2; exit 1; }
            OUTPUT_DIR="$1"
            ;;
        --output-dir=*)
            OUTPUT_DIR="${1#--output-dir=}"
            ;;
        --non-interactive)
            NON_INTERACTIVE=1
            ;;
        *)
            echo "Error: unknown argument: $1" >&2
            usage
            ;;
    esac
    shift
done

if [[ -z "$SUITES_JSON" ]]; then
    echo "Error: --suites-json is required" >&2
    usage
fi

if [[ -z "$OUTPUT_DIR" ]]; then
    echo "Error: --output-dir is required" >&2
    usage
fi

# ── Helpers ──────────────────────────────────────────────────────────────────

# sanitize_job_id: convert suite name to valid GitHub Actions job ID
# Rules: lowercase, replace non-alphanumeric with '-', prefix with 'test-'
sanitize_job_id() {
    local name="$1"
    local lower
    lower="$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-' | tr -s '-' | sed 's/^-//;s/-$//')"
    printf 'test-%s' "$lower"
}

# sanitize_command: truncate command at the first shell metacharacter, then
# strip any remaining characters outside the allowlist.
# Shell metacharacters (; | & ` $ > < ! ( ) { } \n) are dangerous injection
# vectors — truncate at the first occurrence rather than stripping in-place,
# which could silently compose a new harmful command from the fragments.
# Allowlist (post-truncation): alphanumeric, space, '-', '_', '/', '.', ':', '='
# Emits a warning to stderr if characters outside the allowlist are stripped.
sanitize_command() {
    local cmd="$1"
    # Truncate at first shell metacharacter
    local truncated
    truncated="$(printf '%s' "$cmd" | sed 's/[;|&`$><!(){}\\].*//')"
    # Strip any remaining non-allowlist characters
    local safe
    safe="$(printf '%s' "$truncated" | tr -cd 'a-zA-Z0-9 _/.:=-')"
    # Trim trailing whitespace
    safe="${safe%"${safe##*[![:space:]]}"}"
    if [[ "$safe" != "$cmd" ]]; then
        printf 'Warning: sanitize_command stripped unsafe characters from command; original: %s\n' "$cmd" >&2
    fi
    printf '%s' "$safe"
}

# validate_yaml: validate a YAML file with actionlint or python3 yaml.safe_load
# Falls back to success (return 0) when no validator is available, since the
# YAML is generated programmatically and structural issues are unlikely.
validate_yaml() {
    local file="$1"
    if command -v actionlint >/dev/null 2>&1; then
        actionlint "$file" >/dev/null 2>&1
        return $?
    fi
    if python3 -c "import yaml" 2>/dev/null; then
        python3 -c "
import sys, yaml
with open(sys.argv[1]) as f:
    yaml.safe_load(f)
" "$file" 2>/dev/null
        return $?
    fi
    # No validator available — skip validation with warning
    echo "Warning: no YAML validator available (actionlint or python3 PyYAML); skipping validation" >&2
    return 0
}

# ── Parse suites JSON ─────────────────────────────────────────────────────────

# Accept either a JSON string or a file path prefixed with @ (jq-style)
JSON_INPUT="$SUITES_JSON"
if [[ "$JSON_INPUT" == @* ]]; then
    JSON_FILE="${JSON_INPUT#@}"
    if [[ ! -f "$JSON_FILE" ]]; then
        echo "Error: JSON file not found: $JSON_FILE" >&2
        exit 1
    fi
    JSON_INPUT="$(cat "$JSON_FILE")"
elif [[ -f "$JSON_INPUT" ]]; then
    # Plain file path (no @ prefix) — read its contents
    JSON_INPUT="$(cat "$JSON_INPUT")"
fi

# Use python3 to parse the JSON array and emit tab-separated lines:
# name TAB command TAB speed_class
PARSED_SUITES="$(python3 -c "
import sys, json

data = json.loads(sys.argv[1])
for suite in data:
    name = suite.get('name', '')
    command = suite.get('command', '')
    speed_class = suite.get('speed_class', 'unknown')
    # Output tab-separated for easy bash parsing
    print(name + '\t' + command + '\t' + speed_class)
" "$JSON_INPUT" 2>/dev/null)" || {
    echo "Error: failed to parse suites JSON" >&2
    exit 1
}

# ── Classify suites into fast / slow lists ───────────────────────────────────

FAST_SUITES=()  # array of "name TAB command" pairs
SLOW_SUITES=()  # array of "name TAB command" pairs

while IFS=$'\t' read -r suite_name suite_cmd speed_class; do
    [[ -z "$suite_name" ]] && continue

    case "$speed_class" in
        fast)
            FAST_SUITES+=("${suite_name}"$'\t'"${suite_cmd}")
            ;;
        slow)
            SLOW_SUITES+=("${suite_name}"$'\t'"${suite_cmd}")
            ;;
        unknown|*)
            if [[ "$NON_INTERACTIVE" == "1" ]]; then
                # Non-interactive: default unknown to slow (conservative)
                SLOW_SUITES+=("${suite_name}"$'\t'"${suite_cmd}")
            else
                # Interactive: prompt user
                printf "Suite '%s' has unknown speed_class. Classify as [f]ast/[s]low/[k]ip (default: slow): " "$suite_name" >&2
                read -r user_choice
                case "${user_choice:-s}" in
                    f|fast)
                        FAST_SUITES+=("${suite_name}"$'\t'"${suite_cmd}")
                        ;;
                    k|skip)
                        # skip — do not include
                        ;;
                    *)
                        SLOW_SUITES+=("${suite_name}"$'\t'"${suite_cmd}")
                        ;;
                esac
            fi
            ;;
    esac
done <<< "$PARSED_SUITES"

# ── Early exit for empty suite list ──────────────────────────────────────────

if [[ ${#FAST_SUITES[@]} -eq 0 && ${#SLOW_SUITES[@]} -eq 0 ]]; then
    exit 0
fi

# ── YAML generation helpers ───────────────────────────────────────────────────

# generate_workflow_header: emit the top-level workflow YAML
# Args: $1=trigger_block (multi-line YAML indented 2 spaces), $2=workflow_name
generate_workflow_header() {
    local workflow_name="$1"
    local trigger_block="$2"
    printf 'name: %s\n' "$workflow_name"
    printf 'on:\n'
    printf '%s\n' "$trigger_block"
    printf 'jobs:\n'
}

# generate_job: emit a single job entry
# Args: $1=job_id, $2=suite_name, $3=suite_cmd
generate_job() {
    local job_id="$1"
    local suite_cmd="$2"
    local safe_cmd
    safe_cmd="$(sanitize_command "$suite_cmd")"
    # Escape any embedded single quotes inside safe_cmd for YAML single-quoted scalar
    local escaped_cmd
    escaped_cmd="${safe_cmd//\'/\'\'}"
    printf '  %s:\n' "$job_id"
    printf '    runs-on: ubuntu-latest\n'
    printf '    steps:\n'
    printf '      - uses: actions/checkout@v4\n'
    printf '      - name: Run tests\n'
    printf "        run: '%s'\n" "$escaped_cmd"
}

# ── Generate ci.yml (fast suites → pull_request trigger) ────────────────────

mkdir -p "$OUTPUT_DIR"

# Declare temp file variables up front and register a single combined trap
# so both temp files are cleaned up regardless of which branch creates them.
CI_YML_TMP=""
CI_SLOW_TMP=""
trap 'rm -f "${CI_YML_TMP:-}" "${CI_SLOW_TMP:-}"' EXIT

if [[ ${#FAST_SUITES[@]} -gt 0 ]]; then
    CI_YML_TMP="$(mktemp)"

    {
        generate_workflow_header "CI" "  pull_request:"
        for entry in "${FAST_SUITES[@]}"; do
            IFS=$'\t' read -r s_name s_cmd <<< "$entry"
            job_id="$(sanitize_job_id "$s_name")"
            generate_job "$job_id" "$s_cmd"
        done
    } > "$CI_YML_TMP"

    # Validate YAML
    if validate_yaml "$CI_YML_TMP"; then
        mv "$CI_YML_TMP" "$OUTPUT_DIR/ci.yml"
    else
        echo "Error: generated ci.yml contains invalid YAML" >&2
        rm -f "$CI_YML_TMP"
        exit 2
    fi
fi

# ── Generate ci-slow.yml (slow suites → push to main trigger) ────────────────

if [[ ${#SLOW_SUITES[@]} -gt 0 ]]; then
    CI_SLOW_TMP="$(mktemp)"

    PUSH_TRIGGER="  push:
    branches:
      - main"

    {
        generate_workflow_header "CI Slow" "$PUSH_TRIGGER"
        for entry in "${SLOW_SUITES[@]}"; do
            IFS=$'\t' read -r s_name s_cmd <<< "$entry"
            job_id="$(sanitize_job_id "$s_name")"
            generate_job "$job_id" "$s_cmd"
        done
    } > "$CI_SLOW_TMP"

    # Validate YAML
    if validate_yaml "$CI_SLOW_TMP"; then
        mv "$CI_SLOW_TMP" "$OUTPUT_DIR/ci-slow.yml"
    else
        echo "Error: generated ci-slow.yml contains invalid YAML" >&2
        rm -f "$CI_SLOW_TMP"
        exit 2
    fi
fi

exit 0
