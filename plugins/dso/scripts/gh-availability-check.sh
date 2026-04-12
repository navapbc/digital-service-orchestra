#!/usr/bin/env bash
# gh-availability-check.sh
#
# Check GitHub CLI (gh) availability and authentication status.
#
# Output variables (printed to stdout):
#   GH_STATUS=authenticated      — gh is installed and authenticated
#   GH_STATUS=not_authenticated  — gh is installed but not authenticated
#   GH_STATUS=not_installed      — gh is not installed
#   FALLBACK=commands            — (with not_authenticated) gh CLI commands to set vars/secrets manually
#   FALLBACK=ui_steps            — (with not_installed) GitHub UI navigation steps
#
# Usage:
#   bash gh-availability-check.sh [--vars=VAR1,VAR2] [--secrets=SECRET1,SECRET2]
#
# Flags:
#   --vars=VAR1,VAR2       Comma-separated list of variable names to include in fallback commands
#   --secrets=SEC1,SEC2    Comma-separated list of secret names to include in fallback commands

set -uo pipefail

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
VARS_LIST=""
SECRETS_LIST=""

for arg in "$@"; do
    case "$arg" in
        --vars=*)
            VARS_LIST="${arg#--vars=}"
            ;;
        --secrets=*)
            SECRETS_LIST="${arg#--secrets=}"
            ;;
    esac
done

# ---------------------------------------------------------------------------
# Check if gh is installed
# ---------------------------------------------------------------------------
if ! command -v gh &>/dev/null; then
    echo "GH_STATUS=not_installed"
    echo "FALLBACK=ui_steps"
    echo ""
    echo "GitHub CLI (gh) is not installed. To set repository variables and secrets manually:"
    echo "  1. Navigate to github.com/<owner>/<repo>"
    echo "  2. Go to Settings > Secrets and variables > Actions"
    echo "  3. Under 'Variables', click 'New repository variable' and add each variable"
    echo "  4. Under 'Secrets', click 'New repository secret' and add each secret"
    exit 0
fi

# ---------------------------------------------------------------------------
# Check if gh is authenticated
# ---------------------------------------------------------------------------
if ! gh auth status &>/dev/null; then
    echo "GH_STATUS=not_authenticated"
    echo "FALLBACK=commands"
    echo ""
    echo "GitHub CLI is installed but not authenticated. Run the following commands to"
    echo "set your repository variables and secrets manually after authenticating:"
    echo ""
    echo "  gh auth login"
    echo ""

    # Print gh variable set commands for each var
    if [[ -n "$VARS_LIST" ]]; then
        IFS=',' read -ra VARS_ARR <<< "$VARS_LIST"
        for var in "${VARS_ARR[@]}"; do
            var="$(echo "$var" | tr -d '[:space:]')"
            [[ -z "$var" ]] && continue
            echo "  gh variable set $var --body \"<value>\""
        done
    else
        echo "  gh variable set <VARIABLE_NAME> --body \"<value>\""
    fi

    echo ""

    # Print gh secret set commands for each secret
    if [[ -n "$SECRETS_LIST" ]]; then
        IFS=',' read -ra SECRETS_ARR <<< "$SECRETS_LIST"
        for secret in "${SECRETS_ARR[@]}"; do
            secret="$(echo "$secret" | tr -d '[:space:]')"
            [[ -z "$secret" ]] && continue
            echo "  gh secret set $secret"
        done
    else
        echo "  gh secret set <SECRET_NAME>"
    fi

    exit 0
fi

# ---------------------------------------------------------------------------
# gh is installed and authenticated
# ---------------------------------------------------------------------------
echo "GH_STATUS=authenticated"
exit 0
