#!/usr/bin/env bash
# promote-ruleset-required.sh
# Staged rollout of new required check-contexts in the GitHub branch Ruleset.
#
# Subcommands:
#   --stage-as-non-required   Add new check-contexts in non-required (informational)
#                             state. Begins the observation window.
#   --promote-to-required     Promote staged check-contexts to required status.
#                             Run after the observation window.
#   --list-status             Show current state of each staged check-context plus
#                             the timestamp of the last stage/promote operation.
#
# Common flags:
#   --repo <owner/repo>       Target repository (auto-detected from git remote when absent)
#   --checks-file <path>      Override path to required-checks.txt
#   --dry-run                 Print API commands; do not execute them
#   --non-interactive         Skip confirmation prompts
#   -h, --help                Print usage and exit
#
# Environment:
#   DSO_DRY_RUN=1             Equivalent to --dry-run
#
# Exit codes:
#   0 — success (or dry-run complete)
#   1 — error (missing tool, API failure, invalid args)

set -euo pipefail

# ── Self-location ─────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Defaults ──────────────────────────────────────────────────────────────────
SUBCOMMAND=""
REPO=""
CHECKS_FILE=""
DRY_RUN="${DSO_DRY_RUN:-0}"
NON_INTERACTIVE=0

# The check-contexts that this script manages, partitioned by target ruleset.
# Each ruleset gets only the checks that are emitted on PRs it covers:
#
#   merge-pipeline-checks → fires on session→main PRs, belongs on the
#                           main-branch ruleset.
#   review-sub-pr         → fires only on PRs targeting sub-PR branches,
#                           belongs on the sub-PR ruleset.
#
# Adding review-sub-pr to the main-branch ruleset would deadlock every PR
# to main (the check never reports on those PRs).
MAIN_STAGED_CHECKS=(
    "merge-pipeline-checks"
)
SUB_PR_STAGED_CHECKS=(
    "review-sub-pr"
)

RULESET_NAMES=(
    "DSO CI Enforcement"
    "DSO Sub-PR Review Enforcement"
)

# Emit (one per line) the staged check-contexts for a given ruleset name.
# Returns exit 1 if the ruleset name is not recognized.
_staged_checks_for_ruleset() {
    case "$1" in
        "DSO CI Enforcement")
            printf '%s\n' "${MAIN_STAGED_CHECKS[@]}"
            ;;
        "DSO Sub-PR Review Enforcement")
            printf '%s\n' "${SUB_PR_STAGED_CHECKS[@]}"
            ;;
        *)
            return 1
            ;;
    esac
}

# Resolve repo root (git root relative to script location or cwd)
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null \
  || git rev-parse --show-toplevel 2>/dev/null \
  || echo "")"

# ── Argument parsing ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --stage-as-non-required|--promote-to-required|--list-status)
            if [[ -n "$SUBCOMMAND" ]]; then
                echo "ERROR: only one subcommand may be specified (got '$SUBCOMMAND' and '$1')" >&2
                exit 1
            fi
            SUBCOMMAND="${1#--}"
            shift
            ;;
        --repo)
            REPO="$2"
            shift 2
            ;;
        --repo=*)
            REPO="${1#*=}"
            shift
            ;;
        --checks-file)
            CHECKS_FILE="$2"
            shift 2
            ;;
        --checks-file=*)
            CHECKS_FILE="${1#*=}"
            shift
            ;;
        --dry-run)
            DRY_RUN=1
            shift
            ;;
        --non-interactive)
            NON_INTERACTIVE=1
            shift
            ;;
        --help|-h)
            sed -n '2,26p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            echo "ERROR: unknown argument: $1" >&2
            exit 1
            ;;
    esac
done

# ── Validate subcommand ───────────────────────────────────────────────────────
if [[ -z "$SUBCOMMAND" ]]; then
    echo "ERROR: a subcommand is required: --stage-as-non-required | --promote-to-required | --list-status" >&2
    echo "Run with --help for usage." >&2
    exit 1
fi

# ── Pre-flight: verify gh CLI ─────────────────────────────────────────────────
if ! command -v gh >/dev/null 2>&1; then
    echo "ERROR: gh CLI is required but not found in PATH. Install from https://cli.github.com/ and authenticate." >&2
    exit 1
fi

# ── Pre-flight: verify jq ─────────────────────────────────────────────────────
if ! command -v jq >/dev/null 2>&1; then
    echo "ERROR: jq is required but not found in PATH. Install jq and retry." >&2
    exit 1
fi

# ── Resolve checks file ───────────────────────────────────────────────────────
if [[ -z "$CHECKS_FILE" ]]; then
    if [[ -n "$REPO_ROOT" ]]; then
        CHECKS_FILE="$REPO_ROOT/.github/required-checks.txt"
    else
        CHECKS_FILE=".github/required-checks.txt"
    fi
fi

if [[ "$SUBCOMMAND" != "list-status" ]] && [[ ! -f "$CHECKS_FILE" ]]; then
    echo "ERROR: checks file not found: $CHECKS_FILE" >&2
    exit 1
fi

# ── Resolve repo ──────────────────────────────────────────────────────────────
if [[ -z "$REPO" ]]; then
    REPO="$(gh repo view --json nameWithOwner -q '.nameWithOwner' 2>/dev/null || echo "")"
    if [[ -z "$REPO" ]]; then
        echo "ERROR: --repo <owner/repo> is required (or run from inside a git repo with a GitHub remote)." >&2
        exit 1
    fi
fi

# ── Helper: find a ruleset ID by name ─────────────────────────────────────────
_find_ruleset_id() {
    local repo="$1"
    local name="${2:-${RULESET_NAMES[0]}}"
    gh api "/repos/${repo}/rulesets" 2>/dev/null \
        | jq -r --arg name "$name" '.[] | select(.name == $name) | .id' \
        | head -1
}

# ── Helper: fetch the current ruleset JSON ────────────────────────────────────
_fetch_ruleset() {
    local repo="$1" ruleset_id="$2"
    gh api "/repos/${repo}/rulesets/${ruleset_id}" 2>/dev/null
}

# ── Helper: extract current required_status_checks from ruleset JSON ──────────
_extract_status_checks() {
    local ruleset_json="$1"
    echo "$ruleset_json" | jq -r '
        .rules[]? | select(.type == "required_status_checks")
        | .parameters.required_status_checks[]?.context // empty'
}

# ── Helper: print dry-run annotation ─────────────────────────────────────────
_dry_run_header() {
    echo "=== DSO_DRY_RUN=1: No API calls will be made ==="
    echo ""
}

# ── Subcommand: list-status ───────────────────────────────────────────────────
if [[ "$SUBCOMMAND" == "list-status" ]]; then
    echo "Repository: $REPO"
    echo ""

    for _rs_name in "${RULESET_NAMES[@]}"; do
        echo "Ruleset: $_rs_name"
        _RS_ID="$(_find_ruleset_id "$REPO" "$_rs_name")"
        if [[ -z "$_RS_ID" ]]; then
            echo "  STATUS: Not found on $REPO."
            echo "          Run provision-ruleset.sh first, then re-run this script."
            echo ""
            continue
        fi

        _RS_JSON="$(_fetch_ruleset "$REPO" "$_RS_ID")"
        echo "  Ruleset ID: $_RS_ID"
        echo "  Check-context status:"

        mapfile -t _RS_STAGED < <(_staged_checks_for_ruleset "$_rs_name")
        if [[ ${#_RS_STAGED[@]} -eq 0 ]]; then
            echo "    WARNING: no staged checks configured for '$_rs_name'"
            echo ""
            continue
        fi
        for check in "${_RS_STAGED[@]}"; do
            if echo "$_RS_JSON" | jq -e --arg ctx "$check" '
                .rules[]? | select(.type == "required_status_checks")
                | .parameters.required_status_checks[]? | select(.context == $ctx)' \
                >/dev/null 2>&1; then
                echo "    [PRESENT] $check"
            else
                echo "    [ABSENT]  $check"
            fi
        done
        echo ""
    done

    echo ""
    echo "Note: GitHub Rulesets API does not distinguish 'required' vs 'non-required'"
    echo "context entries at the individual-check level — all listed contexts are"
    echo "active once added. Use --promote-to-required to verify enforcement is active."
    exit 0
fi

# ── Subcommand: stage-as-non-required ─────────────────────────────────────────
# GitHub Rulesets API: checks listed under required_status_checks are enforced
# once the ruleset enforcement is "active". To provide a non-blocking
# observation window, we add the checks to a SEPARATE ruleset named
# "DSO Observation Window" (or update it) with enforcement="evaluate".
# "evaluate" means checks are tracked and visible in the PR UI but do NOT block.
#
# The observation-window ruleset targets the default branch (main), so it stages
# only the main-branch staged checks. Sub-PR ruleset checks are promoted directly
# via --promote-to-required (no observation window).
if [[ "$SUBCOMMAND" == "stage-as-non-required" ]]; then
    OBS_RULESET_NAME="DSO Observation Window"

    # Use main-branch staged checks for the observation ruleset (which targets main).
    STAGED_CHECKS=("${MAIN_STAGED_CHECKS[@]}")
    STAGED_JSON="$(printf '%s\n' "${STAGED_CHECKS[@]}" | jq -R '{context: .}' | jq -s '.')"

    # Build observation-window ruleset payload
    OBS_PAYLOAD="$(jq -n \
        --arg name "$OBS_RULESET_NAME" \
        --argjson checks "$STAGED_JSON" \
        '{
            "name": $name,
            "target": "branch",
            "enforcement": "evaluate",
            "conditions": {
                "ref_name": {
                    "include": ["~DEFAULT_BRANCH"],
                    "exclude": []
                }
            },
            "rules": [
                {
                    "type": "required_status_checks",
                    "parameters": {
                        "strict_required_status_checks_policy": false,
                        "required_status_checks": $checks
                    }
                }
            ]
        }')"

    if [[ "$DRY_RUN" == "1" ]]; then
        _dry_run_header
        echo "Subcommand: stage-as-non-required"
        echo ""
        echo "Checks to add (observation / non-required):"
        printf '  %s\n' "${STAGED_CHECKS[@]}"
        echo ""
        echo "--- Observation-window ruleset payload ---"
        echo "$OBS_PAYLOAD"
        echo ""
        echo "--- gh api invocation (not executed) ---"
        echo "# Check if '$OBS_RULESET_NAME' exists; POST to create or PATCH to update."
        echo "gh api --method POST /repos/${REPO}/rulesets --input <(echo '\$obs_payload')"
        echo ""
        echo "Observation window starts: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
        exit 0
    fi

    if [[ "$NON_INTERACTIVE" -ne 1 ]]; then
        echo "About to add checks to '$OBS_RULESET_NAME' (enforcement=evaluate) on $REPO:"
        printf '  %s\n' "${STAGED_CHECKS[@]}"
        printf "Proceed? [y/N] "
        read -r _confirm
        case "$_confirm" in
            y|Y|yes|YES) ;;
            *)
                echo "Aborted." >&2
                exit 1
                ;;
        esac
    fi

    # Check if the observation-window ruleset already exists
    OBS_RULESET_ID="$(gh api "/repos/${REPO}/rulesets" 2>/dev/null \
        | jq -r --arg name "$OBS_RULESET_NAME" '.[] | select(.name == $name) | .id' \
        | head -1)"

    TMPFILE="$(mktemp /tmp/promote-ruleset-obs.XXXXXX)"
    trap 'rm -f "$TMPFILE"' EXIT
    echo "$OBS_PAYLOAD" > "$TMPFILE"

    if [[ -z "$OBS_RULESET_ID" ]]; then
        echo "Creating observation-window ruleset '$OBS_RULESET_NAME' ..."
        gh api --method POST "/repos/${REPO}/rulesets" --input "$TMPFILE"
        echo "Created: '$OBS_RULESET_NAME' (enforcement=evaluate)"
    else
        echo "Updating existing observation-window ruleset (ID: $OBS_RULESET_ID) ..."
        gh api --method PUT "/repos/${REPO}/rulesets/${OBS_RULESET_ID}" --input "$TMPFILE"
        echo "Updated: '$OBS_RULESET_NAME' (enforcement=evaluate)"
    fi

    echo ""
    echo "=== Stage-as-non-required complete ==="
    echo "Repository:        $REPO"
    echo "Observation start: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo "Staged checks:"
    printf '  %s\n' "${STAGED_CHECKS[@]}"
    echo ""
    echo "Next step: monitor CI results for at least one week, then run:"
    echo "  promote-ruleset-required.sh --promote-to-required"
    exit 0
fi

# ── Subcommand: promote-to-required ──────────────────────────────────────────
# Merges STAGED_CHECKS into each DSO ruleset (main + session-branch),
# making them blocking-required.
if [[ "$SUBCOMMAND" == "promote-to-required" ]]; then
    for _rs_name in "${RULESET_NAMES[@]}"; do
        echo "Fetching ruleset '$_rs_name' from $REPO ..."
        RULESET_ID="$(_find_ruleset_id "$REPO" "$_rs_name")"

        if [[ -z "$RULESET_ID" ]]; then
            echo "WARNING: Ruleset '$_rs_name' not found on $REPO — skipping." >&2
            continue
        fi

        echo "Ruleset ID: $RULESET_ID"
        RULESET_JSON="$(_fetch_ruleset "$REPO" "$RULESET_ID")"

        # Per-ruleset staged checks — see MAIN_STAGED_CHECKS / SUB_PR_STAGED_CHECKS above.
        mapfile -t STAGED_CHECKS < <(_staged_checks_for_ruleset "$_rs_name")
        if [[ ${#STAGED_CHECKS[@]} -eq 0 ]]; then
            echo "WARNING: no staged checks configured for ruleset '$_rs_name' — skipping." >&2
            continue
        fi
        STAGED_JSON="$(printf '%s\n' "${STAGED_CHECKS[@]}" | jq -R '{context: .}' | jq -s '.')"

        EXISTING_CHECKS_JSON="$(echo "$RULESET_JSON" | jq '
            [.rules[]? | select(.type == "required_status_checks")
             | .parameters.required_status_checks[]? | {context: .context}]')"

        MERGED_CHECKS_JSON="$(printf '%s\n%s\n' "$EXISTING_CHECKS_JSON" "$STAGED_JSON" \
            | jq -s 'add | unique_by(.context)')"

        UPDATED_RULES="$(echo "$RULESET_JSON" | jq \
            --argjson merged "$MERGED_CHECKS_JSON" '
            .rules |= map(
                if .type == "required_status_checks"
                then .parameters.required_status_checks = $merged
                else .
                end
            ) |
            if (.rules | map(select(.type == "required_status_checks")) | length) == 0
            then .rules + [{
                "type": "required_status_checks",
                "parameters": {
                    "strict_required_status_checks_policy": false,
                    "required_status_checks": $merged
                }
            }]
            else .rules
            end')"

        PATCH_PAYLOAD="$(echo "$RULESET_JSON" | jq \
            --argjson updated_rules "$UPDATED_RULES" '{
                "name": .name,
                "target": .target,
                "enforcement": .enforcement,
                "conditions": .conditions,
                "bypass_actors": (.bypass_actors // []),
                "rules": $updated_rules
            }')"

        if [[ "$DRY_RUN" == "1" ]]; then
            _dry_run_header
            echo "Subcommand: promote-to-required (ruleset: $_rs_name)"
            echo ""
            echo "--- PATCH payload for ruleset $RULESET_ID ---"
            echo "$PATCH_PAYLOAD"
            echo ""
            echo "--- gh api invocation (not executed) ---"
            echo "gh api --method PUT /repos/${REPO}/rulesets/${RULESET_ID} --input <(echo '\$patch_payload')"
            echo ""
            continue
        fi

        if [[ "$NON_INTERACTIVE" -ne 1 ]]; then
            echo "About to promote checks to REQUIRED in '$_rs_name' (ID: $RULESET_ID) on $REPO:"
            printf '  %s\n' "${STAGED_CHECKS[@]}"
            echo "WARNING: after this operation, PRs without passing these checks cannot merge."
            printf "Proceed? [y/N] "
            read -r _confirm
            case "$_confirm" in
                y|Y|yes|YES) ;;
                *)
                    echo "Aborted." >&2
                    exit 1
                    ;;
            esac
        fi

        TMPFILE="$(mktemp /tmp/promote-ruleset-patch.XXXXXX)"
        echo "$PATCH_PAYLOAD" > "$TMPFILE"

        echo "Updating ruleset '$_rs_name' (ID: $RULESET_ID) ..."
        gh api --method PUT "/repos/${REPO}/rulesets/${RULESET_ID}" --input "$TMPFILE"
        rm -f "$TMPFILE"

        echo ""
        echo "=== Promote-to-required complete for '$_rs_name' ==="
        echo "Repository:    $REPO"
        echo "Ruleset:       $_rs_name (ID: $RULESET_ID)"
        echo "Promoted at:   $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
        echo "Required checks now enforced:"
        printf '  %s\n' "${STAGED_CHECKS[@]}"
        echo ""
    done
    exit 0
fi
